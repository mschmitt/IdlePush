#!/usr/bin/perl -w
use strict;
use diagnostics;
use IO::Socket::INET;
use POSIX qw(setsid);
use Mail::IMAPClient;
use WebService::Prowl;
use MIME::EncWords qw(:all);


# Config file syntax, see .cfg-example
my $config = read_config();
my $prowl_app = $config->{'prowl_app'};
my $prowl_key = $config->{'prowl_key'};
my $imap_host = $config->{'imap_host'};
my $imap_port = $config->{'imap_port'};
my $imap_user = $config->{'imap_user'};
my $imap_pass = $config->{'imap_pass'};
my $imap_box  = $config->{'imap_box'};

# Open IMAP connection.
my $returned = connect_imap();
my $imap   = $returned->{'imap'};
my $socket = $returned->{'socket'};
$imap->select($imap_box) or die "Could not select folder $imap_box: $@\n";;

# Fork unless told otherwise 
# set environment NOFORK=1 to run in foreground
# e.g.: NOFORK=1 ./imapidle2prowl.pl config.cfg
unless ($ENV{'NOFORK'}){
        fork && exit;
	print "Backgrounding. PID is $$.\n";
        chdir ('/');
        open STDIN,  "/dev/null"  or die "STDIN </dev/null: $!\n";
        open STDOUT, ">/dev/null" or die "STDOUT >/dev/null: $!\n";
        open STDERR, ">/dev/null" or die "STDERR >/dev/null: $!\n";
        setsid();
}

# The main loop revolves around IDLE-recycling as mandated by RFC 2177
while(1){
	$imap->noop or $imap->reconnect() or die "IMAP reconnect failed: $@\n";;
	# Peek means, don't change any message flags.
	$imap->Peek(1);
	# Do not use Uids for transactions, so we can work with the sequence 
	# ID from IDLE EXISTS
	$imap->Uid(0);
	# RFC2177 demands re-cycling the connection once in a while.
	my $interval = 25*60; # 25 minutes
	# Send session into idle state
	my $session = $imap->idle or die "Couldn't idle: $@\n";
	# Perl Cookbook 16.21: "Timing Out an Operation"
	$SIG{'ALRM'} = sub { die "__TIMEOUT__" };
	# Race condition here: The alarm for IDLE-recycling may strike after
	# reception of EXISTS and before PROWLing the notification. No harm done
	# then, only a missed notification. Could use a fix, though.
	eval {
		alarm($interval);
		while(my $in = <$socket>){
			# We only care about new EXISTS states.
			if ($in =~ /\b(\d+) EXISTS\b/){
				my $exists_id = $1;
				print "Received $1 EXISTS from IMAP.\n";
				# Bail out of the IDLE session and pick up the new message.
				# This was previously implemented using another thread,
				# but was unified into a single thread, as Threads and alarm()
				# really don't like each other.
				$imap->done($session);
				# Retrieve and mangle new message headers.
				my $header  = $imap->parse_headers($exists_id, 'Subject', 'From') or die "Could not parse_headers: $@\n";
				my $subject = decode_mimewords($header->{'Subject'}->[0], Charset => 'utf-8');
				my $from    = decode_mimewords($header->{'From'}->[0],    Charset => 'utf-8');
				print "New message from $from, Subject: $subject \n";
				my $ws = WebService::Prowl->new(apikey => $prowl_key);
				$ws->add(
					application => $prowl_app,
					event       => 'New mail',
					description => "From $from, Subject: $subject",
					priority    => -1
				);
				# Go back to IDLE state.
				$session = $imap->idle or die "Couldn't idle: $@\n";
			}
		}
	};
	# Executed when the timeout for re-cycling the IDLE session has struck.
	print "Recycling IDLE session.\n";
	$imap->done($session);
}

sub connect_imap{
	# Wee need the IMAP object for IMAP transaction
	# as well as the raw socket for listening in on IDLE state.
	# This subroutine returns them both.
	my $return;
	$return->{'socket'} = IO::Socket::INET->new(
		PeerAddr => $imap_host,
		PeerPort => $imap_port,
		Timeout  => 30
	) or die "Can't connect to $imap_host: $@";

	$return->{'imap'} = Mail::IMAPClient->new(
		Socket     => $return->{'socket'},
		User       => $imap_user,
		Password   => $imap_pass,
		Timeout    => 60
	) or die "Can't login as $imap_user: $@\n";
	return $return;
}

# Shamelessly copied from the Perl Cookbook, 8.16.
sub read_config {
	die "Please specify configuration file!\n" unless ($ARGV[0]);
	my %cfdata;
	open my $cf_in, "<$ARGV[0]" or die "Can't read $ARGV[0]: $!\n";
	while(<$cf_in>){
		chomp;                  # no newline
		s/#.*//;                # no comments
		s/^\s+//;               # no leading white
		s/\s+$//;               # no trailing white
		next unless length;     # anything left?
		my ($var, $value) = split(/\s*=\s*/, $_, 2);
		$cfdata{$var} = $value;
	}
	close $cf_in;
	return \%cfdata;
}
