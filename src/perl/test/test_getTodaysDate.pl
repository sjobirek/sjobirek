#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

my $todaysDate = getTodaysDate();
diag("Today\'s date is $todaysDate");

ok($todaysDate ge 20141106, "test 1");
ok($todaysDate lt 99991231, "test 2");

done_testing();

# returns current date in format yyyymmdd
sub getTodaysDate {
    my (
         $second,     $minute,    $hour,
         $dayOfMonth, $month,     $yearOffset,
         $dayOfWeek,  $dayOfYear, $daylightSavings
    ) = localtime();
    my $year = 1900 + $yearOffset;
    my $todaysDate = sprintf("%4d%02d%02d", $year, ++$month, $dayOfMonth);

    return $todaysDate;
}
