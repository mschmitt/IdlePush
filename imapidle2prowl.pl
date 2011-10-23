#!/usr/bin/perl -w
use strict;
use diagnostics;
use IO::Socket::INET;
use IO::Socket::SSL;
use POSIX qw(setsid strftime);
use Fcntl qw(:flock);
use Mail::IMAPClient 3.18;
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
my $logfile;
if ($config->{'logfile'}){
	$logfile = $config->{'logfile'};
	if ($logfile =~ /^syslog:/){
		use Sys::Syslog qw(:standard);
	}
}
my $pidfile;
if ($config->{'pidfile'}){
	$pidfile = glob($config->{'pidfile'});
}
my $ssl_verify;
if ($config->{'ssl_verify'}){
	$ssl_verify = $config->{'ssl_verify'};
}
my $ssl_CApath;
if ($config->{'ssl_CApath'}){
	$ssl_CApath = $config->{'ssl_CApath'};
}
my $fromregexStr;
if ($config->{'from_regex'}){
	$fromregexStr = read_re_file($config->{'from_regex'});
}
my $subjregexStr;
if ($config->{'subj_regex'}){
	$subjregexStr = read_re_file($config->{'subj_regex'});
}

# Command line version of prowl.pl
my $prowl = "$Bin/libexec/prowl.pl";
unless (-x $prowl){
	die "$prowl not found or not executable.\n";
}

# Open Pidfile and lock it, if requested.
my $lock_fh;
if ($pidfile){
	open $lock_fh, "+>$pidfile" or die "Could not create $pidfile: $!\n";
	if (flock($lock_fh,LOCK_EX|LOCK_NB)){
		dolog('debug', "Lockfile created: $pidfile");
	}else{
		close $lock_fh;
		die "Abort: Another instance seems to be running!\n";
	}
}

# Dump module versions. For debugging.
dolog('debug', "IO::Socket::INET has version: $IO::Socket::INET::VERSION");
dolog('debug', "IO::Socket::SSL has version: $IO::Socket::SSL::VERSION");
dolog('debug', "Mail::IMAPClient has version: $Mail::IMAPClient::VERSION");
dolog('debug', "MIME::EncWords has version: $MIME::EncWords::VERSION");

# Fork unless told otherwise 
# set environment NOFORK=1 to run in foreground
# e.g.: NOFORK=1 ./imapidle2prowl.pl config.cfg
unless ($ENV{'NOFORK'}){
        fork && exit;
	dolog('info', "Backgrounding. PID is $$.");
        chdir ('/');
        open STDIN,  "/dev/null"  or die "STDIN </dev/null: $!\n";
        open STDOUT, ">/dev/null" or die "STDOUT >/dev/null: $!\n";
        open STDERR, ">/dev/null" or die "STDERR >/dev/null: $!\n";
        setsid();
}

# Write PID to pidfile, if requested.
if ($pidfile){
	print $lock_fh "$$\n";
	select($lock_fh);
	$| = 1;
	select(STDOUT);
	dolog('debug', "PID $$ written to pidfile: $pidfile");
}

# Holds connections throughout multiple cycles of the main loop.
my $imap;
my $socket;

# Track whether the program has been killed.
my $exitasap = 0;

# Signal handlers. Beware, these are manipulated later on.
$SIG{'TERM'} = sub { $exitasap = 1; };
$SIG{'INT'}  = sub { $exitasap = 1; };

# The main loop revolves around IDLE-recycling as mandated by RFC 2177
while(0 == $exitasap){
	dolog('debug', 'Start main loop.');
	# See if we are connected.
	if ($imap and $imap->noop){
		dolog('debug', 'Connection checked: still alive');
	}else{
		dolog('debug', 'Connection checked: needs reconnect.');
		$imap->disconnect if ($imap);
		dolog('info', 'Connecting to IMAP.');
		# Open IMAP connection.
		my $returned = connect_imap();
		$imap   = $returned->{'imap'};
		$socket = $returned->{'socket'};
		unless ($imap){
			dolog('err', 'No IMAP session was established. Retry after 60 seconds.');
			sleep 60;
			next;
		}
		$imap->select($imap_box);
		unless ($imap->IsSelected()){
			dolog('err', "Failed to select folder: $imap_box - Exiting.");
			last;
		}
		# Peek means, don't change any message flags.
		$imap->Peek(1);
		# Do not use Uids for transactions, so we can work with the 
		# sequence ID from IDLE EXISTS
		$imap->Uid(0);
	}
	# Synchronize message gauge from message count
	dolog('debug', 'Requesting message count from server.');
	my $gauge = $imap->message_count;
	dolog('debug', "$gauge messages on server.");
	# RFC2177 demands re-cycling the connection once in a while.
	my $interval = 25*60; # 25 minutes
	# Send session into idle state
	dolog('debug', 'About to enter IDLE state.');
	my $session = $imap->idle;
	unless ($session){
		dolog('err', 'Could not initiate IDLE state. Non-recoverable error? Exiting!');
		last;
	}
	dolog('debug', "IDLE state entered. Session ID is: $session");
	# Track how long we've been in IDLE state.
	my $idle_start = time();
	eval {
		# Perl Cookbook 16.21: "Timing Out an Operation"
		$SIG{'ALRM'} = sub { die "__TIMEOUT__" };
		# Handle signals inside eval different than outside.
		$SIG{'TERM'} = sub { $exitasap = 1; die "__KILLED__" };
		$SIG{'INT'}  = sub { $exitasap = 1; die "__KILLED__" };
		alarm($interval);
		dolog('debug', "Start eval. Alarm set. Gauge at $gauge. Nibbling on the raw socket.");
		dolog('debug', "Socket is: " . $socket->sockhost. ':' . $socket->sockport . '->' . $socket->peerhost . ':' . $socket->peerport );

		# Compatibility magic for never versions of Mail::IMAPClient ca. 3.25-3.28 
		my $oldblocking = $socket->blocking();
		$socket->blocking(1);
		my $newblocking = $socket->blocking();
		dolog('debug', "Forcing socket to blocking mode. Status old -> new: $oldblocking -> $newblocking");

		while(my $in = <$socket>){
			dolog('debug', "read from socket: $in");
			if ($in =~ /\b(\d+) EXPUNGE\b/i){
				dolog('debug', 'Expunge event from socket.'); 
				# EXPUNGE means that one message has been deleted.
				# Lower gauge by 1. Can't count mailbox contents here,
				# as session is in IDLE state.
				$gauge--;
				dolog('debug', "Expunge $1, now at $gauge messages.");
			}elsif (($in =~ /\b(\d+) EXISTS\b/i) and ($1 > $gauge)){
				# EXISTS means that one message has been created.
				# Only act if the reported ID is higher than our gauge.
				# Cancel alarm so we don't get killed while PROWLing.
				alarm(0);
				my $exists_id = $1;
				dolog('debug', "Received $exists_id EXISTS from IMAP.");
				# Bail out of the IDLE session and pick up the new message.
				$imap->done($session);
				# Retrieve and mangle new message headers.
				my $header  = $imap->parse_headers($exists_id, 'Subject', 'From');
				unless ($header){
					dolog('warning', 'Empty message details. Skipping prowl, killing IMAP session.');
					$imap->disconnect;
					die "__PROWL_SKIP_EMPTY__";
				}
				my $subjraw = $header->{'Subject'}->[0] ? $header->{'Subject'}->[0] : '';
				my $fromraw = $header->{'From'}->[0]    ? $header->{'From'}->[0]    : '<>';
				my $subject = decode_mimewords($subjraw, Charset => 'utf-8');
				my $from    = decode_mimewords($fromraw, Charset => 'utf-8');
				dolog('info', "New message from $from, Subject: $subject");
				# Do we want to ignore this From: address?
				if ($config->{'from_regex'} and ($from =~ m/$fromregexStr/i)) {
					die "__DONT_PROWL_FROM__";
				} elsif ($config->{'subj_regex'} and ($subject =~ m/$subjregexStr/i)) {
					die "__DONT_PROWL_SUBJ__";
				} else {

					# Build the command line for and execute prowl.pl
					my @prowl_cmd;
					push @prowl_cmd, $prowl;
					push @prowl_cmd, "-apikey=$prowl_key";
					push @prowl_cmd, "-application=$prowl_app";
					push @prowl_cmd, "-event=New Mail";
					push @prowl_cmd, "-notification=From $from, Subject: $subject";
					push @prowl_cmd, "-priority=0";
					system(@prowl_cmd);
					dolog('debug', (join ' ', @prowl_cmd));
					my $rc = $?>>8;
					dolog('debug', "Call to prowl.pl returned exitcode: $rc");
					die "__PROWL_FAIL__" unless (0 == $rc);
				}
				# Exit loop and eval from here; let the main loop restart IDLE.
				die "__DONE__";
				# I don't seem to get the hang of eval. "last" doesn't work here.
				# Please, if you can, submit something else. ;-)
			}else{
				dolog('debug', "Ignoring data from socket: $in");
			}
		}
	};
	# Handle signals outside eval different than inside.
	$SIG{'TERM'} = sub { $exitasap = 1; };
	$SIG{'INT'}  = sub { $exitasap = 1; };
	# Handle different states how IDLE may have ended.
	dolog('debug', "Eval has ended. \$\@ contains: $@");
	sleep 5;
	if ($@ =~ /__TIMEOUT__/){
		my $idle_end = time();
		my $idle_duration = $idle_end - $idle_start;
		dolog('info', "Recycling IDLE session after $idle_duration seconds.");
		$imap->done($session);
	}elsif($@ =~ /__DONE__/){
		dolog('info', 'Done, notification sent.');
	}elsif($@ =~ /__PROWL_SKIP_EMPTY__/){
		dolog('warning', 'Skipped bogus message details.');
	}elsif($@ =~ /__DONT_PROWL_FROM__/){
		dolog('info', "Skipped because From matches RE.");
	}elsif($@ =~ /__DONT_PROWL_SUBJ/){
		dolog('info', "Skipped because Subject matches RE.");
	}elsif($@ =~ /__PROWL_FAIL__/){
		dolog('warning', 'Call to prowl.pl failed. Better luck next time?');
	}elsif($@ =~ /__KILLED__/){
		dolog('debug', 'Kill received while working the socket loop.');
		last;
	}else{
		dolog('warning', 'Socket read loop ended by itself. Disconnected from server?');
	}
}
if (0 == $exitasap){
	# Exiting without being killed. Notify owner.
	dolog('info', 'Notifying owner about unexpected exit.');
	# Build the command line for and execute prowl.pl
	my @prowl_cmd;
	push @prowl_cmd, $prowl;
	push @prowl_cmd, "-apikey=$prowl_key";
	push @prowl_cmd, "-application=$prowl_app";
	push @prowl_cmd, "-event=Unexpected Exit";
	push @prowl_cmd, "-notification=imapidle2prowl.pl $ARGV[0] exiting unexpectedly. Please check logs!";
	push @prowl_cmd, "-priority=0";
	system(@prowl_cmd);
	dolog('debug', (join ' ', @prowl_cmd));
	my $rc = $?>>8;
	dolog('debug', "Call to prowl.pl returned exitcode: $rc");
}
dolog('info', 'Exiting.');
exit 0;

sub connect_imap{
	# Wee need the IMAP object for IMAP transaction
	# as well as the raw socket for listening in on IDLE state.
	# This subroutine returns them both.
	my $return;
	dolog('debug', 'Control is now in connect_imap()');
	# Instantiate Socket in plain or in SSL, depending on 
	# configuration. 
	if ($imap_ssl and ($imap_ssl =~ /^(yes|true|1)$/i)){
		dolog('info', "Starting SSL connection to $imap_host:$imap_port.");
		my %ssl_verify_opts;
		if ($ssl_verify and ($ssl_verify =~ /^(yes|true|1)$/i)){
			%ssl_verify_opts = ( 
				SSL_verify_mode => 1,
				SSL_ca_path     => $ssl_CApath
			);
		}
		$return->{'socket'} = IO::Socket::SSL->new(
			PeerAddr => $imap_host,
			PeerPort => $imap_port,
			Timeout  => 30,
			%ssl_verify_opts
		);
		if ($return->{'socket'}){
			my $subject_cn = $return->{'socket'}->peer_certificate('owner');
			my $issuer_cn  = $return->{'socket'}->peer_certificate('authority');
			dolog('info', "SSL subject: $subject_cn");
			dolog('info', "SSL issuer: $issuer_cn");
		}else{
			dolog('err', "SSL connection to $imap_host failed: ".IO::Socket::SSL::errstr());
			return $return;
		}
	}else{
		dolog('info', "Starting plaintext connection to $imap_host:$imap_port.");
		$return->{'socket'} = IO::Socket::INET->new(
			PeerAddr => $imap_host,
			PeerPort => $imap_port,
			Timeout  => 30
		);
		unless ($return->{'socket'}){
			dolog('err', "Connection to $imap_host failed.");
			return $return;
		}
	}
	$return->{'imap'} = Mail::IMAPClient->new(
		Socket     => $return->{'socket'},
		User       => $imap_user,
		Password   => $imap_pass,
		Timeout    => 60
	);
	unless ($return->{'imap'}->IsAuthenticated()){
		dolog('err', "IMAP authentication on $imap_host failed.");
	}
	dolog('debug', 'About to return the IMAP client object from connect_imap()');
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

sub dolog {
	my $lvl = shift;
	my $msg = shift;
	chomp $msg;
	if ($lvl eq "debug"){
		return unless ($ENV{'DEBUG'});
	}
	print STDERR strftime("%Y-%m-%d %H:%M:%S [$lvl] $msg\n", localtime(time));
	if ($logfile){
		if ($logfile =~ /^syslog:(.+)$/){
			# Syslog here
			my $tag = "GhettoPush/$1";
			my $facility = 'mail';
			openlog($tag, 'pid', $facility);
			syslog($lvl, $msg);
			closelog();
		}else{
			$logfile = glob($logfile);
			open my $log_out, ">>$logfile" or die "Can't write to $logfile: $!\n";
			print $log_out strftime("%Y-%m-%d %H:%M:%S [$lvl] $msg\n",localtime(time));
			close $log_out;
		}
	}
}

sub read_re_file {
	my $re_file = shift;
	die "RE file missing!\n" unless ($re_file);
	my @re;
	open my $re_in, "<$re_file" or die "Can't read $re_file: $!\n";
	while(<$re_in>){
		next if /^#/;
		chomp;
		s/^\s+//; 
		s/\s+$//;
		next unless length;     # anything left?
		push @re, $_;
	}
	close $re_in;
	
	# http://www.perlmonks.org/?node_id=621975
	my $reStr = "("
		. (join "|",@re)
		. ")";
	return $reStr;
}
