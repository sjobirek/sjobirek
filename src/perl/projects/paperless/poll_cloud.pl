#!/usr/bin/perl -w

use lib '/home/track/customs';

use strict;
use warnings;

use customs_commons;

use File::Copy;
use File::stat;
use Mail::Sendmail;
use MIME::QuotedPrint;
use MIME::Base64;
use Filesys::SmbClient;
use Fcntl ':flock'; # import LOCK_* constants
use au::com::cloud::scandocs::ams qw( :all );
use au::com::cloud::scandocs::documentService qw( :all );
use au::com::cloud::scandocs::pgService qw( :all );
use Log::Log4perl;
use Log::Dispatch::FileRotate;
#use XML::LibXML # to be installed
use XML::Simple; # to be replaced by XML::LibXML
use XML::Validator::Schema; # to be replaced by XML::LibXML
use XML::SAX::ParserFactory; # to be replaced by XML::LibXML

####################################################################################################
## Author: sjobirek@gmail.com
## Program to poll KOFAX archive directory and copy PDF and metadata into proc1 server.
##    Uses metadata to complete PROCARS pre/post-registration.
##    Creates document in AMS.
##    Generates event in PROCARS.
####################################################################################################

my $app=$0;
my $ams_text_file_path = "/export/track/customs/scan_docs_txt_files/";

my $dbh = getDefaultDatabaseConnection();

my $kofax_local_in_path = "/export/track/customs/in/";
my $kofax_local_processed_path = "/export/track/customs/processed/";
my $kofax_local_error_path = "/export/track/customs/error/";
my $kofax_host = "aukofaxtest.cloud.int.au";
my $kofax_user = "sqladmin";
my $kofax_pass = "cloud!";
my $kofax_wkgrp = "CCLOGAU";
my $kofax_remote_path = "smb://aukofaxtest/export_archive/";
my $kofax_remote_processed_path = "smb://aukofaxtest/export_archive/processed/";
my $kofax_remote_error_path = "smb://aukofaxtest/export_archive/error/";
my $xml_schema = "/home/track/customs/test_options/ArchiveMetadata.xsd";

my $error_to = "sjobirek\@gmail.com";
my $from = "sjobirek\@gmail.com";


# Logger Configuration in a string ...
my $conf = q(
  log4perl.category.Kofax.Archive=DEBUG, LOG1, SCREEN
  log4perl.appender.SCREEN=Log::Log4perl::Appender::Screen
  log4perl.appender.SCREEN.stderr=0
  log4perl.appender.SCREEN.layout=Log::Log4perl::Layout::PatternLayout
  log4perl.appender.SCREEN.layout.ConversionPattern=%m %n
  log4perl.appender.LOG1=Log::Dispatch::FileRotate
  log4perl.appender.LOG1.min_level=debug
  log4perl.appender.LOG1.filename=/export/logs/poll_kofax_archive_output.log
  log4perl.appender.LOG1.mode=append
  log4perl.appender.LOG1.autoflush=1
  log4perl.appender.LOG1.size=10485760
  log4perl.appender.LOG1.max=5
  log4perl.appender.LOG1.layout=Log::Log4perl::Layout::PatternLayout
  log4perl.appender.LOG1.layout.ConversionPattern=%d %p %m %n
);

## .. initialize the logger.
Log::Log4perl::init( \$conf );

my $logger = Log::Log4perl->get_logger("Kofax::Archive");
my $now_string = localtime;

eval {
    $logger->debug("---------------Starting $app at $now_string -----------------");
    my($msgCode, $msgDesc) = verify_kofax_pg_ams_availability();
    if($msgCode eq "OK") {
        $logger->debug("Verified Kofax server is available");
        # uncomment line below to copy files from kofax
        #($msgCode, $msgDesc) = kofax2proc();
        ($msgCode, $msgDesc) = (1, "OK");
        $msgCode || die "Error: $msgDesc";

        process_local_dir();
    } else {
        $logger->debug("Error conneting to kofax: $msgDesc");
    }
};
if ($@) {
    $logger->error( $@ . "\n" );
    #send_email($error_to, $from, "Error: $app", "$@");
}

# Copy files from KOFAX to PROC
sub kofax2proc {
    my($OK, $ERROR) = (1, 0);
    my($status_code, $status_description) = ($OK, "kofax2proc exited normally");
    my $smb = new Filesys::SmbClient( username => $kofax_user, password => $kofax_pass, workgroup => $kofax_wkgrp );

    eval {
        defined $smb || die "Unable to open samba-client connection to $kofax_host using supplied credentials.";
        $logger->debug("Opening samba-client connection to $kofax_host...");
        my $fdout = $smb->opendir($kofax_remote_path) || die "Unable to open remote directory $kofax_remote_path";
        $logger->debug("Opening remote directory $kofax_remote_path...");
        while (my $fd = $smb->readdir_struct($fdout)) {
            if ($fd->[0] == SMBC_FILE) {
                kofax_copy_xml_and_pdf($smb, $fd->[1]);
            }
        }
        $smb->closedir($fdout);
    };
    if ($@) {
        ($status_code, $status_description) = ($ERROR, $@);
    }

    return ($status_code, $status_description);
}

sub process_local_dir {
    $logger->debug("Reading local directory $kofax_local_in_path...");
    opendir(my $dh, $kofax_local_in_path) || die "Unable to open directory $kofax_local_in_path: $!";

    while (my $filename = readdir($dh)) {
        my $filename_with_path = $kofax_local_in_path . $filename;
        if ($filename_with_path =~ /\.xml$/i) {
            my($msgCode, $msgDesc) = validate_metadata_struct($xml_schema, $filename_with_path);
            if ($msgCode) {
                my %metadata = get_metadata($filename_with_path);
                ($msgCode, $msgDesc) = validate_metadata_rules(\%metadata);
                if ($msgCode) {
                    ($msgCode, $msgDesc) = move_to_target_dir($filename, $kofax_local_processed_path);
                    if ($msgCode) {
                        register_document(\%metadata, $filename);
                    }
                } else {
                    $logger->error($msgDesc);
                    move_to_target_dir($filename, $kofax_local_error_path);
                }
            } else {
                $logger->error($msgDesc);
                move_to_target_dir($filename, $kofax_local_error_path);
            }
        }
    }
    closedir $dh;
}

# Register shipment in PROCARS using pre- or post-registration
sub register_document {
    my ($metadata_ref, $filename_xml) = @_;
    my %metadata = %$metadata_ref;
    (my $filename_pdf = $filename_xml) =~ s/\.xml$/\.pdf/i;
    my $pdf_absolute_name = $kofax_local_processed_path . $filename_pdf;

    my ($shipno, $branch, $department, $shipSTT, $shipHBL, $mgsDesc) = findShipmentRegisteredInProcars($metadata{"stt_number"}, $metadata{"hbl_number"}, $metadata{"document_type"});
    if ($shipno eq "NOT_REGISTERED" || $shipno eq "NO_REGO_WITH_STT_HBL" || $shipno eq "") {
        pre_registration($metadata_ref, $pdf_absolute_name);
    } elsif ($shipno eq "ERROR") {
        logerr->error("Error while searching shipment using STT: $metadata{'stt_number'}, HBL: $metadata{'hbl_number'}, Document Type: $metadata{'document_type'}");
    } else {
        post_registration($metadata_ref, $pdf_absolute_name, $shipno);
    }
}

# pre-register consignment (no shipment number)
sub pre_registration {
    my ($metadata_ref, $pdf_absolute_name) = @_;
    my %metadata = %$metadata_ref;

    # check if duplicate replacing original
    my $original_kofax_id = get_original_kofaxid($metadata{'document_status'});
    if ($original_kofax_id) {
        $logger->debug("Replacing original kofaxId=$original_kofax_id with kofaxId=$metadata{'individual_document_id'}");
    }

    $logger->debug("Pre-registering consignment for HBL: $metadata{'hbl_number'}, STT: $metadata{'stt_number'}");
    #my ($msgCode, $msgDesc) = createPreRegoDocumentInScandocs(
    #    $pdf_absolute_name,
    #    $ams_text_file_path,
    #    getTodaysDate(),
    #    $metadata{"document_type"},
    #    $metadata{"department"},
    #    $metadata{"document_capture_timestamp"},
    #    $metadata{"branch"},
    #    $metadata{"stt_number"},
    #    $metadata{"house_bill_number"},
    #    $app,
    #    $metadata{"individual_document_id"},
    #    $metadata{"shipper_name"},
    #    $metadata{"consigne_name"},
    #    $metadata{"is_document_set_complete"}
    #);
    #$logger->debug("msgCode = $msgCode");
    #$logger->debug("msgDesc = $msgDesc");
}

# post-register consignment (shipment number already registered)
sub post_registration {
    my ($metadata_ref, $pdf_absolute_name, $shipno) = @_;
    my %metadata = %$metadata_ref;
    my $docid; # initialised in createDocumentInScandocs()

    my $original_kofax_id = get_original_kofaxid($metadata{'document_status'});
    if ($original_kofax_id) {
        $logger->debug("Replacing original kofaxId=$original_kofax_id with kofaxId=$metadata{'individual_document_id'}");
    }

    $logger->debug("Post-registering consignment for Shipment: $shipno, HBL: $metadata{'hbl_number'}, STT: $metadata{'stt_number'}");
    #my ($msgCode, $msgDesc) = createDocumentInScandocs(
    #    $pdf_absolute_name,
    #    $shipno,
    #    $docid,
    #    $metadata{"department"},
    #    $metadata{"branch"},
    #    $metadata{"document_type"},
    #    $kofax_local_ams_path,
    #    getTodaysDate(),
    #    $app
    #);
    #$logger->debug("msgCode = $msgCode");
    #$logger->debug("msgDesc = $msgDesc");
}

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

# Copy single metadata XML and corresponding PDF to LDW
# Upon successful copy move XML and PDF to Kofax processed directory
# If XML does not have corresponding PDF, do not copy XML to LDW, move XML to Kofax error directory.
# If PDF does not have corresponding XML, leave PDF in source directory.
sub kofax_copy_xml_and_pdf {
    my ($smb, $filename) = @_;

    if ($filename =~ /\.xml$/i) {
        my $filename_xml = $kofax_remote_path . $filename;

        $filename =~ s/\.xml$/\.pdf/i;
        my $filename_pdf = $kofax_remote_path . $filename;

        my @filestat_xml = $smb->stat($filename_xml);
        if ($#filestat_xml != 0) {
            my @filestat_pdf = $smb->stat($filename_pdf);
            if ($#filestat_pdf != 0) {
                kofax_copy_single($smb, $filename_xml, $filestat_xml[7]);
                kofax_copy_single($smb, $filename_pdf, $filestat_pdf[7]);
                kofax_move_single($smb, $kofax_remote_processed_path, $filename_xml);
                kofax_move_single($smb, $kofax_remote_processed_path, $filename_pdf);
            } else {
                $logger->error("Unable to stat file $filename_pdf $!");
                kofax_move_single($smb, $kofax_remote_error_path, $filename_xml);
            }
        } else {
            $logger->error("Unable to stat file $filename_xml $!");
        }
    }
}

# Copy metadata XML or PDF from Kofax to LDW
sub kofax_copy_single {
    my ($smb, $filename_source, $buffer_size) = @_;

    my $filename = $filename_source;
    $filename =~ s/$kofax_remote_path/$kofax_local_in_path/;
    my $filename_target = $filename;
    $logger->debug("Preparing to copy file $filename_source into $filename_target...");
    my $fh_source = $smb->open($filename_source);
    $fh_source != 0 || die "Unable to open file $filename_source $!";

    my $buffer = $smb->read($fh_source, $buffer_size);
    $smb->close($fh_source);
    open(my $fh_target, ">", $filename_target) || die "Unable to open file $filename_target for writing: $!";

    my $written_size = syswrite($fh_target, $buffer, $buffer_size);
    close($fh_target);
    if ($written_size == $buffer_size) {
        $logger->debug("Successfully written file $filename_target");
    } else {
        $logger->warn("Discrepancy in read and written size, $filename_source $buffer_size bytes, $filename_target $written_size bytes");
    }
}

# Move metadata XML or PDF from Kofax source directory to Kofax processed or error directory
sub kofax_move_single {
    my ($smb, $dir_target, $filename) = @_;
    $filename =~ s/^(.*)\///;

    my $filename_source = $kofax_remote_path . $filename;
    my $filename_target = $dir_target . $filename;

    $smb->rename($filename_source, $filename_target) || die "Unable to rename $filename_source as $filename_target: $!";
    $logger->debug("Successfully renamed $filename_source as $filename_target");
}

sub validate_metadata_struct {
	my ($xsd, $xml) = @_;

    my($OK, $ERROR) = (1, 0);
    my($status_code, $status_description) = ($OK, "metadata structure is valid");

    $logger->debug("Validating metadata $xml against schema $xsd...");
	my $validator = XML::Validator::Schema->new(file => $xsd);
	my $parser = XML::SAX::ParserFactory->parser(Handler => $validator);
    my $err = "OK";

	eval {
		$parser->parse_uri($xml);
	};

	if ($@) {
        $status_code = $ERROR;
		$status_description = "Metadata $xml failed schema validation: $!";
	}

    return ($status_code, $status_description);
}

# subroutine to validate metadata business rules
# add rule that cannot be validated in schema validator
sub validate_metadata_rules {
    my $metadata_ref = shift;
    my %metadata = %$metadata_ref;

    my($OK, $ERROR) = (1, 0);
    my($status_code, $status_description) = ($OK, "metadata rules are valid");

    if (!is_string_not_empty($metadata{"hbl_number"})) {
        return ($ERROR, "HBL number must not be empty");
    }

    $_ = $metadata{"document_status"};
    (/^READY_FOR_ARCHIVE$/) || (/^REPLACE_/) || return ($ERROR, "Unsupported document status: $_");

    return ($status_code, $status_description);
}

sub get_metadata {
    my $xml_param = shift;
    my $ref = XMLin($xml_param);

    my %metadata = ();

    $metadata{ 'email_sender' } = hash2str($ref->{ 'email_sender' });
    $metadata{ 'email_receiver' } = hash2str($ref->{ 'email_receiver' });
    $metadata{ 'email_subject' } = hash2str($ref->{ 'email_subject' });
    $metadata{ 'email_timestamp' } = hash2str($ref->{ 'email_timestamp' });
    $metadata{ 'department' } = hash2str($ref->{ 'department' });
    $metadata{ 'branch' } = hash2str($ref->{ 'branch' });
    $metadata{ 'document_type' } = hash2str($ref->{ 'document_type' });
    $metadata{ 'stt_number' } = hash2str($ref->{ 'stt_number' });
    $metadata{ 'hbl_number' } = hash2str($ref->{ 'hbl_number' });
    $metadata{ 'shipper_name' } = hash2str($ref->{ 'shipper_name' });
    $metadata{ 'consignee_name' } = hash2str($ref->{ 'consignee_name' });
    $metadata{ 'inco_term' } = hash2str($ref->{ 'inco_term' });
    $metadata{ 'origin' } = hash2str($ref->{ 'origin' });
    $metadata{ 'destination' } = hash2str($ref->{ 'destination' });
    $metadata{ 'master_bill_number' } = hash2str($ref->{ 'master_bill_number' });
    $metadata{ 'container_number' } = hash2str($ref->{ 'container_number' });
    $metadata{ 'document_location' } = hash2str($ref->{ 'document_location' });
    $metadata{ 'document_name' } = hash2str($ref->{ 'document_name' });
    $metadata{ 'document_capture_timestamp' } = hash2str($ref->{ 'document_capture_timestamp' });
    $metadata{ 'is_document_set_complete' } = hash2str($ref->{ 'is_document_set_complete' });
    $metadata{ 'duplicate_document_count' } = hash2str($ref->{ 'duplicate_document_count' });
    $metadata{ 'document_status' } = hash2str($ref->{ 'document_status' });
    $metadata{ 'kofax_batch_id' } = hash2str($ref->{ 'kofax_batch_id' });
    $metadata{ 'document_set_id' } = hash2str($ref->{ 'document_set_id' });
    $metadata{ 'individual_document_id' } = hash2str($ref->{ 'individual_document_id' });
    $metadata{ 'original_document_id' } = hash2str($ref->{ 'original_document_id' });

    return %metadata;
}

sub move_to_target_dir {
    my ($filename_xml, $target_dir) = @_;

    my($OK, $ERROR) = (1, 0);
    my($status_code, $status_description) = ($OK, "moving file successful");

    (my $filename_pdf = $filename_xml) =~ s/\.xml$/\.pdf/i;
    my $filename_source_xml = $kofax_local_in_path . $filename_xml;
    my $filename_target_xml = $target_dir . $filename_xml;
    my $filename_source_pdf = $kofax_local_in_path . $filename_pdf;
    my $filename_target_pdf = $target_dir . $filename_pdf;

    if (move($filename_source_xml, $filename_target_xml)) { 
        $status_description = "Moving $filename_source_xml to $filename_target_xml";
        $logger->debug($status_description);
    } else {
        $status_code = $ERROR;
        $status_description = "Error moving $filename_source_xml to $filename_target_xml: $!";
        $logger->error($status_description);
    }

    if (move($filename_source_pdf, $filename_target_pdf)) { 
        $status_description = "Moving $filename_source_pdf to $filename_target_pdf";
        $logger->debug($status_description);
    } else {
        $status_code = $ERROR;
        $status_description = "Error moving $filename_source_pdf to $filename_target_pdf: $!";
        $logger->error($status_description);
    }

    return ($status_code, $status_description);
}

# Tests if string is not empty
# parameter:
#   $str input string
# return value:
#   1 if string is not empty, 0 otherwise
sub is_string_not_empty {
    my $str = shift;

    return defined $str && length $str ? 1 : 0 ;
}

# Removes hash reference from string
#   "abc" -> "abc"
#   "HASH\(0xff" -> ""
# param:
#   $str input string
# return value:
#   input string or empty string ("") if input string contains hash reference
#   or is not defined
sub hash2str {
    my $str = shift;

    my $retval = "";

    if (defined $str) {
        $retval = ($str =~ /^HASH\(0x.+$/ ? "" : $str);
    }

    return $retval;
}

# returns today's date in foramt yyyymmdd
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
