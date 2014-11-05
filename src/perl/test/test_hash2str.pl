#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

my ($got, $str);

$got = hash2str($str);
is($got, "", "test 1");

$str = "HASH(0x1f";
$got = hash2str($str);
is($got, "", "test 2");

$str = "AUSYD";
$got = hash2str($str);
is($got, "AUSYD", "test 3");

$str = " HASH(0x1f";
$got = hash2str($str);
is($got, " HASH(0x1f", "test 4");

$str = "HASH(0x1f ";
$got = hash2str($str);
is($got, "", "test 5");

$str = "HASH(017";
$got = hash2str($str);
is($got, "HASH(017", "test 6");

$str = "hash(0x1f";
$got = hash2str($str);
is($got, "hash(0x1f", "test 7");

$str = "HASH(0xFF";
$got = hash2str($str);
is($got, "", "test 8");

done_testing();

# Removes hash reference from string
# 	"abc" -> "abc"
# 	"HASH\(0xff" -> ""
# param:
# 	$str input string
# return value:
# 	input string or empty string ("") if input string contains hash reference
# 	or is not defined
sub hash2str {
  my $str = shift;

	my $retval = "";
	if (defined $str) {
    	$retval = ($str =~ /^HASH\(0x.+$/ ? "" : $str);
	}

  return $retval;
}
