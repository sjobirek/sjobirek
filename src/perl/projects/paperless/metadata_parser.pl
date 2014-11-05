#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Std;
use XML::LibXML;

my $usage_message = "Usage: $0 -x xml_file -d xml_schema_file [-o output_text_file]\n";
my ($xml,$xsd, $txt);

my %options=();# command line options
getopt("x:d:o:", \%options) or die $usage_message;
if (defined $options{x}) {
	$xml = $options{x};
}

if (defined $options{d}) {
	$xsd = $options{d};
}

if (!defined $xml || !defined $xsd) {
	die $usage_message;
}

if (defined $options{o}) {
	$txt = $options{o};
} else {
	$txt = $xml;
	$txt =~ s/\.xml/\.txt/;
}

validate($xsd, $xml);
my %metadata = get_metadata($xsd, $xml);
write_as_text($xml, \%metadata, $txt);

sub validate {
	my ($xsd, $xml) = @_;
	my $parser = XML::LibXML->new;
	my $schema = XML::LibXML::Schema->new(location => $xsd);
	my $doc = $parser->parse_file($xml);

	eval {
		$schema->validate($doc);
	};
	if ($@) {
		die $@;
	}
}

sub get_metadata {
	my ($xsd, $xml) = @_;
	my $parser = XML::LibXML->new;
	my $doc = $parser->parse_file($xml);
	my @xml_elements = get_elements($xsd);
	my %metadata;

	foreach (@xml_elements) {
		my $key = $_;
		my $xpath = "/metadata/$key";
		$metadata{$key} = $doc->findnodes($xpath);
	}
	return %metadata;
}

sub get_elements {
	my $xsd = shift;
	my $parser = XML::LibXML->new;
	my $doc = $parser->parse_file($xsd);	
	my $xpath = '/xs:schema/xs:element/xs:complexType/xs:sequence/xs:element/@name';
	my @elements;

	foreach my $element ($doc->findnodes($xpath)) {
		$element =~ s/ name=//;
		$element =~ s/"//g;
		push @elements,$element
	}
	return @elements;
}

sub write_as_text {
	my ($xml, $metadata_ref, $txt) = @_;
	my %metadata = %$metadata_ref;
	eval {
		open(FILE, '>', $txt) or die "Unable to open file $txt : $!";
		print FILE "$_ => $metadata{$_}\n" for (keys %metadata);
		close(FILE);
	};
	if ($@) {
		print "Error writing file $txt : $@ \n";
	}
}
