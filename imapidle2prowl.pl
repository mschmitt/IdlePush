#!/usr/bin/perl -w
use strict;
use diagnostics;
use IO::Socket::INET;
use IO::Socket::SSL;
use POSIX qw(setsid);
use Mail::IMAPClient;
use MIME::EncWords qw(:all);
use FindBin qw($Bin);

# Config file syntax, see .cfg-example
my $config = read_config();
my $prowl_app = $config->{'prowl_app'};
my $prowl_key = $config->{'prowl_key'};
my $imap_host = $config->{'imap_host'};
my $imap_port = $config->{'imap_port'};
my $imap_user = $config->{'imap_user'};
my $imap_pass = $config->{'imap_pass'};
my $imap_box  = $config->{'imap_box'};
my $imap_ssl  = $config->{'imap_ssl'};

# Command line version of prowl.pl
my $prowl = "$Bin/libexec/prowl.pl";
unless (-x $prowl){
	die "$prowl not found or not executable.\n";
}

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

# Holds connections throughout multiple cycles of the main loop.
my $imap;
my $socket;

# The main loop revolves around IDLE-recycling as mandated by RFC 2177
while(1){
	print "Start main loop.\n";
	# See if we are connected.
	unless ($imap and $imap->noop){
		$imap->disconnect if ($imap);
		print "Connecting to IMAP.\n";
		# Open IMAP connection.
		my $returned = connect_imap();
		$imap   = $returned->{'imap'};
		$socket = $returned->{'socket'};
		$imap->select($imap_box) or die "Could not select folder $imap_box: $@\n";
		# Peek means, don't change any message flags.
		$imap->Peek(1);
		# Do not use Uids for transactions, so we can work with the 
		# sequence ID from IDLE EXISTS
		$imap->Uid(0);
	}
	# Synchronize message gauge from message count
	my $gauge = $imap->message_count;
	# RFC2177 demands re-cycling the connection once in a while.
	my $interval = 25*60; # 25 minutes
	# Send session into idle state
	my $session = $imap->idle or die "Couldn't idle: $@\n";
	# Perl Cookbook 16.21: "Timing Out an Operation"
	$SIG{'ALRM'} = sub { die "__TIMEOUT__" };
	eval {
		alarm($interval);
		print "Start eval. Alarm set. Gauge at $gauge.\n";
		while(my $in = <$socket>){
			print "$in\n";
			if ($in =~ /\b(\d+) EXPUNGE\b/i){
				print "Expunge event.\n"; 
				# EXPUNGE means that one message has been deleted.
				# Lower gauge by 1. Can't count mailbox contents here,
				# as session is in IDLE state.
				$gauge--;
				print "Expunge $1, now at $gauge messages.\n";
			}elsif (($in =~ /\b(\d+) EXISTS\b/i) and ($1 > $gauge)){
				# EXISTS means that one message has been created.
				# Only act if the reported ID is higher than our gauge.
				# Cancel alarm so we don't get killed while PROWLing.
				alarm(0);
				my $exists_id = $1;
				print "Received $exists_id EXISTS from IMAP.\n";
				# Bail out of the IDLE session and pick up the new message.
				$imap->done($session);
				# Retrieve and mangle new message headers.
				my $header  = $imap->parse_headers($exists_id, 'Subject', 'From');
				my $subject = decode_mimewords($header->{'Subject'}->[0], Charset => 'utf-8');
				my $from    = decode_mimewords($header->{'From'}->[0],    Charset => 'utf-8');
				print "New message from $from, Subject: $subject \n";
				unless ($header and $subject and $from){
					print "Empty message details. Skipping prowl, killing IMAP session.\n";
					$imap->disconnect;
					die "__PROWL_SKIP_EMPTY__";
				}
				# Build the command line for and execute prowl.pl
				my @prowl_cmd;
				push @prowl_cmd, $prowl;
				push @prowl_cmd, "-apikey=$prowl_key";
				push @prowl_cmd, "-application=$prowl_app";
				push @prowl_cmd, "-event=New Mail";
				push @prowl_cmd, "-notification=From $from, Subject: $subject";
				push @prowl_cmd, "-priority=0";
				system(@prowl_cmd);
				# Exit loop and eval from here; let the main loop restart IDLE.
				die "__DONE__";
				# I don't seem to get the hang of eval. "last" doesn't work here.
				# Please, if you can, submit something else. ;-)
			}
		}
	};
	# Executed when the timeout for re-cycling the IDLE session has struck.
	if ($@ =~ /__TIMEOUT__/){
		print "Recycling IDLE session after $interval seconds.\n";
		$imap->done($session);
	}elsif($@ =~ /__DONE__/){
		print "Done, notification sent.\n";
	}elsif($@ =~ /__PROWL_SKIP_EMPTY__/){
		print "Skipped bogus message details.\n";
	}else{
		print "Disconnected?\n";
	}
}

sub connect_imap{
	# Wee need the IMAP object for IMAP transaction
	# as well as the raw socket for listening in on IDLE state.
	# This subroutine returns them both.
	my $return;
	# Instantiate Socket in plain or in SSL, depending on 
	# configuration. 
	if ($imap_ssl =~ /^(yes|true|1)$/i){
		print "Starting SSL connection to $imap_host:$imap_port.\n";
		$return->{'socket'} = IO::Socket::SSL->new(
			PeerAddr => $imap_host,
			PeerPort => $imap_port,
			Timeout  => 30
		) or die "Can't connect to $imap_host: $@";
	}else{
		print "Starting plaintext connection to $imap_host:$imap_port.\n";
		$return->{'socket'} = IO::Socket::INET->new(
			PeerAddr => $imap_host,
			PeerPort => $imap_port,
			Timeout  => 30
		) or die "Can't connect to $imap_host: $@";
	}
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
		s/^\s*#.*//;            # no comments
		s/^\s+//;               # no leading white
		s/\s+$//;               # no trailing white
		next unless length;     # anything left?
		my ($var, $value) = split(/\s*=\s*/, $_, 2);
		$cfdata{$var} = $value;
	}
	close $cf_in;
	return \%cfdata;
}
