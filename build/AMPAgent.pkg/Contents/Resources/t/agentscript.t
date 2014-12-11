#!/usr/bin/perl -w
# Test script for kagentbootupscript and kagentlogonscript
# This is not reentrant. Only one test instance can run on a machine at a time
# These tests create a process as the current user called "AMPAgent" which
# tricks the scripts into believing that AMPAgent is running, even if it isn't.
# Some of these tests require sudo and a real AMPAgent, but these tests will be
# skipped if not available.
# Don't run these as root. If AMPAgent is running as root, and you run the
# tests as root, this will confuse the "No agent" tests.

use Test::More tests => 18;

use strict;
use Cwd;

#
# Constants
#

my $SOURCE_DIR = getcwd;
my $OUT_DIR = "/tmp/test-agentscript";
my $EVENT_FIFO = "_kagent_bootup_event";
my $STATUS_FIFO = "${EVENT_FIFO}_status";
my $LOG_PATH = "${OUT_DIR}/kagentbootupscript.log";
#
# Sanity
#
if ($< == 0)
{
    die "Don't run this as root.\n";
}

#
# Setup
#
$ENV{KACE_AGENTSCRIPT_DEBUG} = 1;
mkdir($OUT_DIR);
chdir($OUT_DIR);

system("killall AMPAgent >/dev/null 2>&1"); # Cleanup old runs

unlink("$OUT_DIR/$EVENT_FIFO");
unlink("$OUT_DIR/$STATUS_FIFO");


###############################################################################

sub run_bootup
{
    my ($prefix) = shift || "";
    
    unlink($LOG_PATH);
    my @result = qx(${prefix} "${SOURCE_DIR}/kagentbootupscript");
    return chomp(@result);
}

sub bootup_errors
{
    my @result = qx(grep ERROR: "$LOG_PATH");
    return @result;
}

sub bootup_warnings
{
    my @result = qx(grep WARNING: "$LOG_PATH");
    return @result;
}

sub start_dummy_agent
{
    if (my $pid = fork())
    {
        sleep 1;
        return $pid;
    }
    else
    {
        $0 = "AMPAgent";
        sleep 30;
        exit;
    }
}

sub create_fifo
{
    my ($fifo) = @_;
    if (! -e $fifo)
    {
        system("mkfifo $fifo");
    }    
}

sub read_event_fifo
{
    open(EVENTFIFO, "<", $EVENT_FIFO) or die "Failed to open the fifo for read";
    while(my $line = <EVENTFIFO>)
    {
        if($line =~ /BOOTUP/)
        {
            last;
        }
    }
    close(EVENTFIFO);
}

sub write_status_fifo
{
    open(STATUSFIFO, ">", $STATUS_FIFO) or die "Failed to open the event fifo for writing";
    print STATUSFIFO "BOOTUP";
    close(STATUSFIFO);
}

sub start_slow_agent
{
    if (my $pid = fork())
    {
        sleep 1;
        return $pid;
    }
    else
    {
        $0 = "AMPAgent";

        create_fifo($EVENT_FIFO);
        read_event_fifo;

        create_fifo($STATUS_FIFO);
        
        sleep 60;
        
        exit;
    }    
}

sub start_good_agent
{
    if (my $pid = fork())
    {
        sleep 1;
        return $pid;
    }
    else
    {
        $0 = "AMPAgent";
        
        create_fifo($EVENT_FIFO);
        read_event_fifo;
        
        create_fifo($STATUS_FIFO);
        write_status_fifo;

        sleep 60;
        exit;
    }
}

###############################################################################

#
# No agent running
#
eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm 1;    # This should be fast

    run_bootup;

    is($?>>8, 1, "No agent. Return 1.");

    is(bootup_errors, 0, "No agent. 0 errors.");

    like((bootup_warnings)[0], qr/AMPAgent is not running/, "No agent. Not running warning.");

    alarm 0;
};
ok(!$@, "No agent. No timeout.");


#
# Dummy agent. Doesn't create fifos. Tests $FIFO_TIMEOUT.
#
my $agent_pid = start_dummy_agent;
eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm 15;   # Greater than $FIFO_TIMEOUT, less than $TOTAL_TIMEOUT
    
    run_bootup;

    is($?>>8, 1, "Dummy agent. Return 1.");

    like((bootup_errors)[0], qr/Timed out/, "Dummy agent. Timed out error.");

    like((bootup_warnings)[0], qr/No fifo/, "Dummy agent. No fifo warning.");

    alarm 0;
};
ok(!$@, "Dummy agent. No timeout.");
kill 15, $agent_pid;

#
# Slow agent. Creates fifos, but doesn't return before $TOTAL_TIMEOUT
#
$agent_pid = start_slow_agent;
eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm 30;   # Greater than debug $TOTAL_TIMEOUT
    
    run_bootup;

    is($?>>8, 1, "Slow agent. Return 1.");

    like((bootup_errors)[0], qr/timed out/, "Slow agent. Timed out error.");

    is(bootup_warnings, 0, "Slow agent. No warnings.");

    alarm 0;
};
ok(!$@, "Slow agent. No timeout.");
kill 15, $agent_pid;

#
# Good agent.
#
$agent_pid = start_good_agent;
eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm 30;   # Greater than debug $TOTAL_TIMEOUT
    
    run_bootup;
    
    is($?>>8, 0, "Good agent. Return 0.");
    
    is(bootup_errors, 0, "Good agent. No errors.");
    
    is(bootup_warnings, 0, "Good agent. No warnings.");
    
    alarm 0;
};
ok(!$@, "Good agent. No timeout.");
kill 15, $agent_pid;

#
# Real agent. Skip if we can't sudo or the real agent isn't running.
# This does not pass the debug flag to the script.
#
SKIP: {
    skip "Can't sudo", 2 unless system("sudo -v") == 0;
    skip "No AMPAgent", 2 unless system("sudo -n killall -0 AMPAgent > /dev/null 2>&1") == 0;
    
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm 310;   # Greater than debug $TOTAL_TIMEOUT (non-debug)
        
        run_bootup "sudo";
        
        is($?>>8, 0, "Real agent. Return 0.");
        
        # Can't easily check the logs here, since we don't want to modify the real installation.
        
        alarm 0;
    };
    ok(!$@, "Real agent. No timeout.");
}
