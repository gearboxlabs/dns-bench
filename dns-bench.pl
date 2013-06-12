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
    return ($s, $ms/1000000);
  }
  else {
    return (time(), 0 );
  }
}

$|=1;

my ($s,$sm,$e,$em) = (&thisTime, 0, 0);

my %s;

GetOptions( \%s,
  'threads=i',
  'progress',
  'resolver=s',
  'targets=s',
  'count=i',
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

  # Connect to resolver.
  my $res = Net::DNS::Resolver->new(
    nameservers => [ ( $s{resolver} ) ],
    recurse     => $s{recurse},
    debug       => $s{debug}
  );

  die "Failed to make resolver!\n" unless $res;

  my ($t,$tm,$ot,$otm);

  ($t,$tm) = thisTime;
  foreach my $c ( 1 .. $count ) {
    my $name = $names[ int(rand($#names+1)) ];

    $ot = $t; $otm = $tm; 
    my $pack = $res->query( $name );
    ($t,$tm) = thisTime;

    my $elapsed = ($t+$tm)-($ot+$otm);
    $min = $elapsed if( $min == 0 || $elapsed < $min );
    $max = $elapsed if( $elapsed > $max );
    

    if( ! $pack ) {
      $failures ++;
      print "No answer for [$name]\n" if $s{debug};
    }
    else {
      # $pack is a Net::DNS::Packet, and valid
      $successes ++;
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
  my @p = split /:/, $data{$k};
  $min = $p[0] if $p[0] < $min;
  $max = $p[1] if $p[1] > $max;
  $successes += $p[3];
  $failures  += $p[4];
}

printf "\nResults:\n\tSuccesses: %d (%.2f%%)\n\tFailures: %d (%.2f%%)\n", 
  $successes, 100*($successes/($successes+$failures)),
  $failures, 100*($failures/($successes+$failures))
;

($e,$em) = thisTime;

my $total = ($e+$em)-($s+$sm);

$avg = $total/$count;
printf "Total time: %.2f sec, %.2f requests/sec\n", $total, $count/$total;
printf "Min/Max/Average: %dms / %dms / %dms\n", 1000*$min, 1000*$max, 1000*$avg;


