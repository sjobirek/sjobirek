#!/usr/bin/perl

# Test subroutine get_original_kofaxid

use strict;
use warnings;
use Test::More;

my $status;
my $got;

$got = get_original_kofaxid($status);
is($got, 0, "test 1");

$status = "";
$got = get_original_kofaxid($status);
is($got, 0, "test 2");

$status = "REPLACE";
$got = get_original_kofaxid($status);
is($got, 0, "test 3");

$status = "REPLACE_";
$got = get_original_kofaxid($status);
is($got, 0, "test 4");

$status = "REPLACE_ ";
$got = get_original_kofaxid($status);
is($got, " ", "test 5");

$status = "REPLACE_900001001";
$got = get_original_kofaxid($status);
is($got, "900001001", "test 6");

$status = " REPLACE_900001001";
$got = get_original_kofaxid($status);
is($got, 0, "test 7");

$status = "OVERWRITE_900001001";
$got = get_original_kofaxid($status);
is($got, 0, "test 8");

$status = "REPLACE_900001001_900001002";
$got = get_original_kofaxid($status);
is($got, 0, "test 9");

$status = "REPLACE_KOFAXID_900001001";
$got = get_original_kofaxid($status);
is($got, 0, "test 10");

done_testing();

# parameter:
#   $doc_status document status retrieved from metadata
#
# return value:
#   individual document id (assigned by Kofax) of the original document to be replaced
#   or zero if replacement does not occur
sub get_original_kofaxid {
    my $doc_status = shift;

    my $retval = 0;

	if (defined $doc_status) {
    	my @strings = split('_', $doc_status);
    	my $count = @strings;
    	if ($count == 2 && $strings[0] eq "REPLACE" && $strings[1] ne "") {
        	$retval = $strings[1];
    	}
	}

    return $retval;
}

