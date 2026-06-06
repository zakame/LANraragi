use strict;
use warnings;
use utf8;

# Override flock() before loading RotatingLog - Test::MockModule can't redefine builtins.
# $mock_flock_behavior: coderef ($fh, $op) -> (ok, errno); undef = real flock.
our $mock_flock_behavior;

BEGIN {
    *CORE::GLOBAL::flock = sub {
        my ( $fh, $op ) = @_;
        if ( defined $mock_flock_behavior ) {
            my ( $ok, $errno ) = $mock_flock_behavior->( $fh, $op );
            $! = $errno if defined $errno;
            return $ok ? 1 : 0;
        }
        return CORE::flock( $fh, $op );
    };
}

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Errno qw(EBADF ENOLCK);
use Fcntl qw(:flock);

BEGIN { use_ok('LANraragi::Utils::RotatingLog'); }

sub with_suppressed_stdout {
    my ($code) = @_;
    local *STDOUT;
    open STDOUT, '>', '/dev/null';
    $code->();
}

sub fresh_logger {
    my $dir     = tempdir( CLEANUP => 1 );
    my $logpath = File::Spec->catfile( $dir, 'lanraragi.log' );

    local $mock_flock_behavior = undef;
    my $log = LANraragi::Utils::RotatingLog->new(
        path    => $logpath,
        level   => 'debug',
        logfile => 'lanraragi',
        lockdir => $dir,
    );
    return ( $log, $logpath, $dir );
}

sub capture_log_messages {
    my ($log) = @_;
    my @messages;
    $log->on(
        message => sub {
            my ( $self, $level, @lines ) = @_;
            push @messages, { level => $level, lines => [@lines] };
        }
    );
    return \@messages;
}

sub slurp_log {
    my ( $log, $path ) = @_;
    # flush before reading - writes may still be in PerlIO buffer
    if ( defined $log ) {
        my $h = $log->handle;
        $h->flush if $h && $h->can('flush');
    }
    return '' unless -e $path;
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# --- append survives EBADF: degrades to unlocked mode, logs kept, one warn ---
note('testing append survives flock EBADF (NFS without lockd)...');
{
    my ( $log, $logpath ) = fresh_logger();
    my $messages = capture_log_messages($log);

    # LOCK_UN stays working - production speculatively unlocks even after a failed lock.
    local $mock_flock_behavior = sub {
        my ( $fh, $op ) = @_;
        return ( 1, undef ) if ( $op & LOCK_UN );
        return ( 0, EBADF );
    };

    my $appended;
    eval {
        with_suppressed_stdout( sub {
            $log->info("hello-1");
            $log->info("hello-2");
            $log->info("hello-3");
        } );
        $appended = 1;
    };
    my $err = $@;

    ok( $appended, 'three info() calls completed without dying' )
      or diag("die was: $err");

    my $content = slurp_log( $log, $logpath );
    like( $content, qr/hello-1/, 'first line written to logfile' );
    like( $content, qr/hello-2/, 'second line written to logfile' );
    like( $content, qr/hello-3/, 'third line written to logfile' );

    my @warns = grep { $_->{level} eq 'warn' } @$messages;
    is( scalar @warns, 1, 'exactly one warn emitted across multiple appends' );
    ok( $log->flock_disabled, 'flock_disabled flipped to truthy' );
}

# --- same as above but ENOLCK (newer kernels' errno for missing lock manager) ---
note('testing append survives flock ENOLCK...');
{
    my ( $log, $logpath ) = fresh_logger();
    my $messages = capture_log_messages($log);

    local $mock_flock_behavior = sub {
        my ( $fh, $op ) = @_;
        return ( 1, undef ) if ( $op & LOCK_UN );
        return ( 0, ENOLCK );
    };

    my $appended;
    eval {
        with_suppressed_stdout( sub {
            $log->info("nolock-1");
            $log->info("nolock-2");
        } );
        $appended = 1;
    };
    my $err = $@;

    ok( $appended, 'appends completed without dying on ENOLCK' )
      or diag("die was: $err");

    my $content = slurp_log( $log, $logpath );
    like( $content, qr/nolock-1/, 'first line written' );
    like( $content, qr/nolock-2/, 'second line written' );

    my @warns = grep { $_->{level} eq 'warn' } @$messages;
    is( scalar @warns, 1, 'exactly one warn emitted on ENOLCK' );
    ok( $log->flock_disabled, 'flock_disabled flipped to truthy on ENOLCK' );
}

# --- lockpath + logpath both on NFS: 5 appends survive, one warn total ---
note('testing lockpath + logpath both on simulated NFS...');
{
    my ( $log, $logpath, $dir ) = fresh_logger();
    my $messages = capture_log_messages($log);

    is( $log->lockdir, $dir, 'lockdir matches' );
    like( $log->lockpath, qr/\Q$dir\E/, 'lockpath under lockdir' );

    local $mock_flock_behavior = sub {
        my ( $fh, $op ) = @_;
        return ( 1, undef ) if ( $op & LOCK_UN );
        return ( 0, EBADF );
    };

    my $err;
    with_suppressed_stdout( sub {
        for my $i ( 1 .. 5 ) {
            eval { $log->info("nfs-line-$i"); 1 } or do { $err //= $@; };
        }
    } );
    ok( !$err, '5 sequential appends all survived' )
      or diag("first die was: $err");

    my $content = slurp_log( $log, $logpath );
    for my $i ( 1 .. 5 ) {
        like( $content, qr/nfs-line-$i/, "line $i present in logfile" );
    }

    my @warns = grep { $_->{level} eq 'warn' } @$messages;
    is( scalar @warns, 1, 'one warn for the whole 5-append sequence' );
}

# --- lockdir attribute: lockfile lands on separate path, logfile unaffected ---
# (LRR_LOG_LOCK_DIRECTORY is read by Logging::get_logger and passed here as lockdir =>)
note('testing lockdir attribute relocates lockfile, logfile unaffected...');
{
    my $logdir  = tempdir( CLEANUP => 1 );
    my $lockdir = tempdir( CLEANUP => 1 );
    my $logpath = File::Spec->catfile( $logdir, 'lanraragi.log' );

    local $mock_flock_behavior = undef;

    my $log = LANraragi::Utils::RotatingLog->new(
        path    => $logpath,
        level   => 'debug',
        logfile => 'lanraragi',
        lockdir => $lockdir,
    );

    like( $log->lockpath, qr{^\Q$lockdir\E/}, 'lockpath under lockdir' );
    unlike( $log->lockpath, qr{^\Q$logdir\E/}, 'lockpath NOT under logdir' );
    ok( -e $log->lockpath, 'lockfile created at relocated path' );

    ok( flock( $log->lockfh, LOCK_EX | LOCK_NB ),
        'real flock LOCK_EX succeeds on relocated lockfile' )
      or diag("flock errno: $!");
    ok( flock( $log->lockfh, LOCK_UN ),
        'LOCK_UN succeeds' );

    my $survived;
    with_suppressed_stdout( sub {
        eval { $log->info("t5-line"); $survived = 1 };
    } );
    ok( $survived, 'info() succeeds with normal flock + relocated lockpath' );

    my $content = slurp_log( $log, $logpath );
    like( $content, qr/t5-line/, 'log line lands in logfile under logdir' );
}

# --- end-to-end via get_logger: skipped if full dep stack not loadable ---
note('testing get_logger end-to-end with simulated NFS + flock failure...');
SKIP: {
    my $require_err;
    {
        local $@;
        eval { require LANraragi::Utils::Logging; 1 } or $require_err = $@;
    }
    skip "LANraragi::Utils::Logging not loadable: $require_err", 3 if $require_err;

    my $tmpdir = tempdir( CLEANUP => 1 );
    local $ENV{LRR_LOG_DIRECTORY}  = $tmpdir;
    local $ENV{LRR_TEMP_DIRECTORY} = $tmpdir;
    local $ENV{LRR_FORCE_DEBUG}    = 1;
    local %LANraragi::Utils::Logging::LOGGER_CACHE;
    %LANraragi::Utils::Logging::LOGGER_CACHE = ();

    # LOCK_UN stays working - production speculatively unlocks even after a failed lock.
    local $mock_flock_behavior = sub {
        my ( $fh, $op ) = @_;
        return ( 1, undef ) if ( $op & LOCK_UN );
        return ( 0, EBADF );
    };

    my $log;
    my $get_err;
    with_suppressed_stdout( sub {
        eval {
            $log = LANraragi::Utils::Logging::get_logger( 'test-t11', 'lanraragi' );
            1;
        } or do { $get_err = $@ };
    } );
    ok( !$get_err, 'get_logger did not die under flock-EBADF' )
      or diag("get_logger die was: $get_err");
    ok( defined $log, 'get_logger returned a logger' );

    my $survived;
    my $err;
    with_suppressed_stdout( sub {
        eval {
            $log->info("hello-from-t11");
            $survived = 1;
        };
        $err = $@;
    } );
    ok( $survived, 'info() did not die under flock-EBADF' )
      or diag("info die was: $err");
}

# --- _try_flock with non-NFS errno does not set flock_disabled ---
note('testing _try_flock with non-NFS errno does not set flock_disabled...');
{
    my ( $log, $logpath ) = fresh_logger();
    use Errno qw(EAGAIN);

    local $mock_flock_behavior = sub {
        my ( $fh, $op ) = @_;
        return ( 1, undef ) if ( $op & LOCK_UN );
        return ( 0, EAGAIN );
    };

    with_suppressed_stdout( sub {
        eval { $log->info("contended") };
    } );
    ok( !$log->flock_disabled,
        'flock_disabled stays false on non-NFS errno (lock contention)' );
}

# --- ensure_lock reopens lockfh after fork (simulated PID mismatch) ---
note('testing ensure_lock reopens lockfh after simulated fork...');
{
    my ( $log, $logpath, $dir ) = fresh_logger();

    my $original_fh = $log->lockfh;

    $log->lockpid( $$ + 99999 );
    LANraragi::Utils::RotatingLog::ensure_lock($log);

    isnt( $log->lockfh, $original_fh,
        'ensure_lock opened a new filehandle after PID mismatch' );
    is( $log->lockpid, $$,
        'lockpid updated to current PID after ensure_lock' );
}

# --- ensure_lock uses +>> (lockfh is readable after re-open) ---
note('testing ensure_lock lockfh is readable after re-open (+>> mode)...');
{
    my ( $log, $logpath, $dir ) = fresh_logger();

    $log->lockpid( $$ + 1 );
    LANraragi::Utils::RotatingLog::ensure_lock($log);

    my $buf = '';
    my $read_ok = defined( read( $log->lockfh, $buf, 1 ) );
    ok( $read_ok, 'lockfh is readable after ensure_lock re-open (+>> mode)' );
}

done_testing();
