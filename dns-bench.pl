#!/usr/bin/perl
#

use threads;
use threads::shared;
use strict;
use Net::DNS;
use Getopt::Long;
eval {
  use Time::HiRes qw/gettimeofday/;
};

use Config;
warn "No threads!\n" unless $Config{useithreads};

my %data :shared; # results will be in the hash ref $data{thread-id}

my $whichtime = 0; # =1 for HiRes
if( ! $@ ) {
  $whichtime = 1;
}

sub thisTime {
  my ($s,$ms);
  if( $whichtime ) {
    ($s,$ms) = gettimeofday;
    return sprintf "%.6f", (sprintf "%d.%d", $s, $ms);
  }
  else {
    return (sprintf "%d.%d", time(), 0 );
  }
}

$|=1;

my ($s,$e) = (&thisTime, 0);

my %s;

GetOptions( \%s,
  'threads=i',
  'progress',
  'resolver=s',
  'targets=s',
  'count=i',
  'extended',
  'recurse',
  'debug',
  'help'
);

my $count = $s{count} || 100;
my $threads = $s{threads} || 1;
die("I won't run with more than 32 threads.\n") if $threads > 32;
die("I need at least one thread!\n") if $threads < 1;


if( $s{help} || !$s{resolver} || !$s{targets} ) {
  print << "END";
Usage: $0 --resolver=1.2.3.4 --targets=FILE [--count=i] [--recurse] [--progress] [--debug] [--threads=INT]
  --resolver  The dns server to test
  --targets   A file containing names to resolve, one per line, no comments
  --count     Number of requests to run
  --threads   Number of parallel threads to run to perform the requests, default 1
  --debug     Print a LOT of information about what we're doing
  --progress  Print progress indicator.
  --extended  Print distribution of queries

END
  exit 0;
}

# Take the file, read it, and resolve entries from it.
my @names;
open(F,"<$s{targets}") or die("couldn't open $s{targets}: $!\n");
chomp(@names=<F>);
close(F);
my ($failures,$successes,$min,$max,$avg);

if( $s{debug} || $s{progress} ) {
  print "Performing $s{count} lookups ";
  print "(each . = 25 queries) " if $s{progress};
  print "against $s{resolver}\n";
  print "-" x 72 . "\n";
}

sub perform_dns_bench {
  my $count = shift;
  my %return; # keys: min, max, total, success, fail
  my @results; 
  my $min = 1000;
  my $max = 0;

  # Connect to resolver.
  my $res = Net::DNS::Resolver->new(
    nameservers => [ ( $s{resolver} ) ],
    recurse     => $s{recurse},
    debug       => $s{debug}
  );

  die "Failed to make resolver!\n" unless $res;

  my ($t,$ot);

  $t = thisTime;
  foreach my $c ( 1 .. $count ) {
    my $name = $names[ int(rand($#names+1)) ];

    $ot = $t; 
    my $pack = $res->query( $name );
    $t = thisTime;

    my $elapsed = $t - $ot;
    if( $elapsed < 0.0 && $s{debug} ) {
      print "> Negative time? [$c; $t - $ot = $elapsed]\n";
    }
    $min = $elapsed if( $min == 0 || $elapsed < $min );
    $max = $elapsed if( $elapsed > $max );

    if( ! $pack ) {
      $failures ++;
      print "No answer for [$name]\n" if $s{debug};
    }
    else {
      # $pack is a Net::DNS::Packet, and valid
      $successes ++;

      # Only record positive time -- gettimeofday bug :(
      if( $elapsed > 0.0 ) {
        push @results, $elapsed;
      }
      if( $s{debug } ) {
        my @a = $pack->answer;
        map { printf "Debug: Answer %s \n", $_->string; } @a;
      }
    }
    if( ! $s{debug} && $s{progress} ) {
      if( $c % 25 == 0 ) {
        print ".";
        if( $c % (25*72) == 0 ) {
          print "\n";
        }
      }
    }
  }
  $return{min} = $min;
  $return{max} = $max;
  $return{total} = $count;
  $return{success} = $successes;
  $return{fail} = $failures;

  my $tid = threads->tid() || "Single";
  print "Thread id = $tid\n";
  $data{"$tid"} = sprintf ("%.3f:%.3f:%d:%d:%d", $min,$max,$count,$successes,$failures);
  $data{"${tid}_res"} = join ':', @results; 
}

my $ithreads = $count / $threads;

print "I'm going to run $count requests across $threads threads, for $ithreads requests/thread.\n";

my @threads;

# Perform parallel jobs
for (1 .. $threads) {
  $threads[$_] = threads->create( \&perform_dns_bench, $count/$threads );
}

# Coalesce the data
for ( 1 .. $threads ) {
  $threads[$_]->join();
}

my ($avg,$min,$max,$successes,$failures);

# Extract the data set
foreach my $k (keys %data) {
  next if $k =~ /_res$/;
  my @p = split /:/, $data{$k};
  $min = $p[0] if $p[0] < $min;
  $max = $p[1] if $p[1] > $max;
  $successes += $p[3];
  $failures  += $p[4];
}

# An array of how long each successful query took.
my @successes;
foreach my $k (keys %data) {
  next unless $k =~/_res$/;
  map { push @successes, $_; } (split /:/, $data{$k});
}
$e = thisTime;

my $total = $e-$s;

# Remap min
$min = 100000.000; $max = 0.00000;
foreach(@successes) { 
  $min = $_ if $min > $_; 
  $max = $_ if $max < $_; 
}

$avg = $total/$count;

printf "\nResults:\n\tSuccesses: %d (%.2f%%)\n\tFailures: %d (%.2f%%)\n", 
  $successes, 100*($successes/($successes+$failures)),
  $failures, 100*($failures/($successes+$failures))
;

printf "Total time: %.2f sec, %.2f requests/sec\n", $total, $count/$total;
printf "Min/Max/Average: %.2fms / %.2fms / %.2fms\n", 1000*$min, 1000*$max, 1000*$avg;

printf "l: %d, c: [%s]\n", 1+$#successes, (join ':', @successes) if $s{debug};

if ($s{extended} ) {
  # Do extended stats.
  my $onems = 0.001;
  my ($sub1ms, $sub5ms, $sub10ms, $sub20ms, $sub40ms, $sub80ms, $sub160ms, $sub500ms, $sup500ms );
  my $s = 1+$#successes;
  foreach(@successes) {
    $sub1ms ++ && next if $_ < $onems;
    $sub5ms ++ && next if $_ < 5*$onems;
    $sub10ms ++ && next if $_ < 10*$onems;
    $sub20ms ++ && next if $_ < 20*$onems;
    $sub40ms ++ && next if $_ < 40*$onems;
    $sub80ms ++ && next if $_ < 80*$onems;
    $sub160ms ++ && next if $_ < 160*$onems;
    $sub500ms ++ && next if $_ < 500*$onems;
    $sup500ms ++ && next if $_ > 500*$onems;
  }

  print "\nDistribution: \n";
  printf "\t* %d less than 1ms (%d%%)\n", $sub1ms, 100*($sub1ms/$s);
  printf "\t* %d less than 5ms (%d%%)\n", $sub5ms, 100*($sub5ms/$s);
  printf "\t* %d less than 10ms (%d%%)\n", $sub10ms, 100*($sub10ms/$s);
  printf "\t* %d less than 20ms (%d%%)\n", $sub20ms, 100*($sub20ms/$s);
  printf "\t* %d less than 40ms (%d%%)\n", $sub40ms, 100*($sub40ms/$s);
  printf "\t* %d less than 80ms (%d%%)\n", $sub80ms, 100*($sub80ms/$s);
  printf "\t* %d less than 160ms (%d%%)\n", $sub160ms, 100*($sub160ms/$s);
  printf "\t* %d less than 500ms (%d%%)\n", $sub500ms, 100*($sub500ms/$s);
  printf "\t* %d more than 500ms (%d%%)\n", $sup500ms, 100*($sup500ms/$s);
}



