#!/usr/bin/perl

use strict;
use warnings;

=head1 NAME

ntp_stats_collector.pl - Sends local NTP stats to an esmond measurement archive

=head1 DESCRIPTION

This script runs out of cron and sends local NTP stats to an esmond measurement archive.

=cut

use FindBin qw($RealBin);
use lib "$RealBin/../shared/lib";
#use lib "$RealBin/../lib";

use Carp;
use Getopt::Long;

use Data::Dumper;
use POSIX qw(strftime);
use Config::General;
use perfSONAR_PS::Client::Esmond::ApiFilters;
use perfSONAR_PS::Client::Esmond::Metadata;

my $DEFAULT_CONFIG_FILE = "$RealBin/../etc/ntp-stats-collector.conf";
my $DEFAULT_LOGGER_CONF = "$RealBin/../etc/ntp-stats-collector-logger.conf";
my $DEBUGFLAG = 0;
my $HELP;

my $ESMOND_URL;
my $USERNAME;
my $PASSWORD;
my $CONFIG_FILE;
my $LOGGER_CONF;
my $SUBJECT_TYPE = 'network-element';
my $NTPQ_PATH;
my $DEFAULT_NTPQ_PATH = '/usr/sbin/ntpq';
my $STATE_FILE;
my $DEFAULT_STATE_FILE = '/var/run/ntp.info';
my $CHECK_STATE;
my $DEFAULT_CHECK_STATE = 1;
my $logger;

my $status = GetOptions(
    'config=s'    => \$CONFIG_FILE,
    'statefile=s'   => \$STATE_FILE,
    'logger=s'    => \$LOGGER_CONF,
    'verbose'     => \$DEBUGFLAG,
    'help'        => \$HELP
);


if (!$CONFIG_FILE) {
    $CONFIG_FILE = $DEFAULT_CONFIG_FILE;
}

unless ( $LOGGER_CONF ) {
    use Log::Log4perl qw(:easy);

    my %logger_opts = (
        level  => ($DEBUGFLAG?$DEBUG:$ERROR),
        layout => '%d (%P) %p> %F{1}:%L %M - %m%n',
    );

    Log::Log4perl->easy_init( \%logger_opts );
} else {
    use Log::Log4perl qw(get_logger :levels);

    Log::Log4perl->init( $LOGGER_CONF );
}

$logger = get_logger( "ntp_stats" );

if ( !$CONFIG_FILE ) {
    print "Error: no configuration file specified";
    exit -1;
}
my %config = Config::General->new( $CONFIG_FILE )->getall();

if (!exists($config{'measurement_archive'})) {
    $logger->error("No measurement archive settings in config file.");
    exit(-1);
} else {
    $ESMOND_URL = $config{'measurement_archive'}->{'database'};
    $USERNAME = $config{'measurement_archive'}->{'username'};
    $PASSWORD = $config{'measurement_archive'}->{'password'};
    $STATE_FILE = $config{'local'}->{'state_file'} || $DEFAULT_STATE_FILE;
    $NTPQ_PATH = $config{'local'}->{'ntpq_path'} || $DEFAULT_NTPQ_PATH;
    $CHECK_STATE = $config{'local'}->{'check_state'};

    # setting this one differently as check_state appears false 
    # if it's 0 (even though that's a valid value)
    if (!defined($CHECK_STATE)) {
        $CHECK_STATE = $DEFAULT_CHECK_STATE;
    }

    if (!$ESMOND_URL) {
        $logger->error("No measurement archive URL specified in config file.");
        exit(-1);
    }
    if (!$USERNAME) {
        $logger->error("No measurement archive username specified in config file.");
        exit(-1);
    }
    if (!$PASSWORD) {
        $logger->error("No measurement archive password specified in config file.");
        exit(-1);
    }
    if (!$STATE_FILE) {
        $logger->error("No state file configured.");
        exit(-1);
    }
    if (!$NTPQ_PATH) {
        $logger->error("No ntpq path configured.");
        exit(-1);
    }
    if (! -f -x $NTPQ_PATH) {
        $logger->error("ntpq not found at configured location: " . $NTPQ_PATH);
        exit(-1);
    }
}
$logger->debug("config: " . Dumper %config);



my $stats = get_local_ntp_stats();
if (!$stats) {
    die "No stats found.";
}
if ($CHECK_STATE) {
    if (!$stats->{'sync_time'}) {  # this should not happen, if there are $stats
        die "sync_time not found.";
    } else {
        my $last_sync_time = get_last_sync_time($STATE_FILE);
        if (!$last_sync_time || $stats->{'sync_time'} != int $last_sync_time) {
            post_results($stats);
            write_sync_time($STATE_FILE, $stats->{'sync_time'});
        } else {
            $logger->info("No updates since last write. Not updating.");
        }
    }
} else {
    post_results($stats);
}

sub get_local_ntp_stats {
    my %stats = ();
    # get basic local ntp data
    my $ntpq_local = $NTPQ_PATH . ' -c rv -p -n';
    $logger->debug("command: " . $ntpq_local);
    open(NTP, $ntpq_local . "|") or die "Error running ntpq: $!";
    while(<NTP>) {
        #print;
        if (/refid=(.+),/) {
            $stats{'source'} = $1;
        }
        if (/offset=([0-9.\-]+),/) {
            $stats{'offset'} = $1;
        }
        if (/sys_jitter=([0-9.\-]+),/) {
            $stats{'jitter'} = $1;
        }
        if (/clk_wander=([0-9.\-]+),?/) {
            $stats{'wander'} = $1;
        }
        if (/stratum=(\d+)/) {
            $stats{'stratum'} = $1;
        }
        if (/clock=([0-9a-fA-F.]+)\s+/) {
            $stats{'clock'} = ntp_timestamp_to_utc($1);
        }
        if (/reftime=([0-9a-fA-F.]+)\s+/) {
            # reftime indicates the last time the clock was synced
            $stats{'sync_time'} = ntp_timestamp_to_utc($1);
        }
        if (/peer=(\d+)/) {
            $stats{'peer'} = $1;
        }
    }    
    close NTP;

    # get data for selected peer
    my $peer = int $stats{'peer'} || 0;
    if ($peer > 0) {
        my $peer_cmd = $NTPQ_PATH . ' -c "rv ' . $peer . '"';
        open(PEER, $peer_cmd . "|") or die "Error getting peer: $!";
        while(<PEER>) {
            #print;
            if (/dstadr=([^,]+)/) {
                $stats{'destination'} = $1;
            }
            if (/\s+reach=(\d+)/) {
                $stats{'reach'} = $1;
            }
            if (/\s+delay=([0-9.]+)/) {
                $stats{'delay'} = $1;
            }
            if (/\s+dispersion=([0-9.\-]+)/) {
                $stats{'dispersion'} = $1;
            }
            if (/ppoll=(\d+)/) {      
                # peer polling is an exponent power of 2 (2^ppol) interval
                $stats{'polling_interval'} = 2 ** $1;
            }

       }
       close PEER;

    } else {
        warn "invalid primary peer: " . Dumper $peer;
    }

    $logger->debug(Dumper \%stats);
    return \%stats;

}

# Get all NTP peers (possibly useful in the future, not implemented now)
sub get_ntp_peers {
    my $ntpq_list = $NTPQ_PATH . ' -pn';
    # /usr/sbin/ntpq -c rv -p -n -c "rv &1"
}

sub post_results {
    my $stats = shift;
    my $filters = new perfSONAR_PS::Client::Esmond::ApiFilters(
        'auth_username' => $USERNAME, 
        'auth_apikey' => $PASSWORD
        #'ca_certificate_file' => $CERT_FILE
    ); 
    #Post measurement metadata
    my $metadata = new perfSONAR_PS::Client::Esmond::Metadata(
        url => $ESMOND_URL,
        filters => $filters
    ); 

    # the "local IP" is actually referred to as 'destination' by NTP
    my $local_ip = $stats->{'destination'};

    $metadata->subject_type($SUBJECT_TYPE);
    $metadata->source($local_ip);
    $metadata->input_source($local_ip);
    $metadata->measurement_agent($local_ip);
    $metadata->tool_name('ntp');
    $metadata->add_event_type('ntp-delay') if $stats->{'delay'};
    $metadata->add_event_type('ntp-dispersion') if $stats->{'dispersion'};
    $metadata->add_event_type('ntp-jitter') if $stats->{'jitter'};
    $metadata->add_event_type('ntp-offset') if $stats->{'offset'};
    $metadata->add_event_type('ntp-polling-interval') if $stats->{'polling_interval'};
    $metadata->add_event_type('ntp-reach') if $stats->{'reach'};
    $metadata->add_event_type('ntp-stratum') if $stats->{'stratum'};
    $metadata->add_event_type('ntp-wander') if $stats->{'wander'};


    $metadata->post_metadata();
    die $metadata->error() if $metadata->error();

    # all ntp event types
    my $bulk_post = $metadata->generate_event_type_bulk_post();
    my $ts = $stats->{'clock'};
    $bulk_post->add_data_point('ntp-delay', $ts, $stats->{'delay'});
    $bulk_post->add_data_point('ntp-dispersion', $ts, $stats->{'dispersion'});
    $bulk_post->add_data_point('ntp-jitter', $ts, $stats->{'jitter'});
    $bulk_post->add_data_point('ntp-offset', $ts, $stats->{'offset'});
    $bulk_post->add_data_point('ntp-polling-interval', $ts, $stats->{'polling_interval'});
    $bulk_post->add_data_point('ntp-reach', $ts, $stats->{'reach'});
    $bulk_post->add_data_point('ntp-stratum', $ts, $stats->{'stratum'});
    $bulk_post->add_data_point('ntp-wander', $ts, $stats->{'wander'});

    $bulk_post->post_data();
    die $bulk_post->error() if $bulk_post->error();

}

sub get_last_sync_time {
    my $file = shift;
    if (open(LAST, '<', $file)) {
        my $row = <LAST>;
        close LAST;
        chomp $row;
        return $row;
    } 
    return;
}

sub write_sync_time {
    my $file = shift;
    my $sync_time = shift;

    if (open(SYNCTIME, '>', $file)) {
        close SYNCTIME;
        return 1;
    } else {
        $logger->error("Could not open file for write: '$file' $!");
        exit(-1);
    }

}

sub ntp_timestamp_to_utc {
    # adapted from http://www.ntp.org/ntpfaq/NTP-s-related.htm#AEN6780

    # ntp timestamp is either decimal: [0-9]+.?[0-9]*
    # or hex: (0x)?[0-9a-fA-F]+.?(0x)?[0-9a-fA-F]*

    # Seconds between 1900-01-01 and 1970-01-01
    my $NTP2UNIX = (70 * 365 + 17) * 86400;

    my $ntp_timestamp = shift;
    if (!$ntp_timestamp or $ntp_timestamp eq "") {
        $logger->error("No timestamp to convert");
        return;
    }

    my ($i, $f) = split(/\./, $ntp_timestamp, 2);
    $f ||= 0;

    if ($i =~ /[0-9a-fA-F]+/ && $i !~ /^0x/) {
        $i = '0x' . $i;
    }
    if ($f =~ /[0-9a-fA-F]+/ && $f !~ /^0x/) {
        $f = '0x' . $f;
    }
    if ($i =~ /^0x/) {
        $i = oct($i);
        $f = ($f =~ /^0x/) ? oct($f) / 2 ** 32 : "0.$f";
    } else {
        $i = int($i);
        $f = $ntp_timestamp - $i;
    }

    my $t = $i - $NTP2UNIX;
    while ($t < 0) {
        $t += 65536.0 * 65536.0;
    }

    my $ts = $t;

    my ($year, $mon, $day, $h, $m, $s) = (gmtime($t))[5, 4, 3, 2, 1, 0];
    $s += $f;

    return $ts;

}
