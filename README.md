
DNS-BENCH
====

dns-bench.pl is a multi-threaded perl DNS benchmarking tool.  I wrote it so I could do performance testing against a DNS cluster at work.

Usage 
----

 dns-bench.pl --resolver=<host|ip> --targets=FILE [--count=INT] [--recurse] [--progress] [--debug] [--threads=INT]
    --resolver  The dns server to test
    --targets   A file containing names to resolve, one per line, no comments
    --count     Number of requests to run [default 10]
    --recurse   Do recursive lookups [default no]
    --threads   Number of parallel threads to run to perform the requests [default 1]
    --progress  Print progress indicator [default no]
    --debug     Print a LOT of information about what we're doing [default no]




