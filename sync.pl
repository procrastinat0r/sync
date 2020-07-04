
# This script can be used to synchronize files/directories between computers using the following
# tools:
# - ssh (1)
# - rsync (1)
# - fswatch (https://github.com/emcrisostomo/fswatch)
# - https://metacpan.org/pod/File::Basename
# - https://metacpan.org/pod/File::Temp
# - https://metacpan.org/pod/AppConfig
#
# We used some ideas from
# - https://rakhim.org/2018/10/fast-automatic-remote-file-sync/ (for the common concept)
# - https://stackoverflow.com/questions/16654751/rsync-through-ssh-tunnel (for the proxy support)

use strict;
use warnings;

use File::Basename;
use File::Temp;
use AppConfig qw(:expand);

my $version = '1.3.1';
my $verbose = 0;
my $cfg_file = '';
my $os = $^O; # tested with: cygwin, freebsd

######################################################################
sub main
{
    # install signal handler so that we delete temporary files
    $SIG{INT} = sub { exit };

    check_command_line_arguments();

    unless ($cfg_file)
    { # no config file specified via comman line ...
        if (-r '.syncrc') { $cfg_file = '.syncrc' } # ... try .syncrc in current directory
        elsif (-r '~/.syncrc') { $cfg_file = '~/.syncrc' } # ... try .syncrc in HOME
        else { error("Can not find any config file\n", 1) }
    }

    check_config_file();
    initial_full_sync();
    sync_on_changes();
}

######################################################################
sub info
{
    my $info = shift;
    print $info if $verbose;
}

######################################################################
sub warning
{
    my $warning = shift;
    print "Warning! $warning";
}

######################################################################
sub error
{
    my $err = shift;
    my $with_usage = shift;
    print "Error! $err";
    print "Usage: perl sync.pl [-v] [-c <cfg_file>]\n" if $with_usage;
    exit -1;
}

sub get_check_path
{
    (my $what, my $path, my $is_mandatory, my $need_check, my $need_file) = @_;
    $path = '' unless defined $path;
    error("No $what specified\n") if $is_mandatory && !$path;
    return $path unless $path && $need_check;
    info("Use $what <$path>\n") if $path;
    error("Can not find $what <$path>: $!\n") if $need_file && !(-r $path);
    error("Can not find $what <$path>: $!\n") unless -r $path || -d $path;
    return $path;
}

# check command line arguments
sub check_command_line_arguments
{
    my $cfg = AppConfig->new( {
        PEDANTIC => 1,
    } );
    $cfg->define('verbose|v!');
    $cfg->define('config|c=s');
    error ("Invalid command line\n", 1) unless $cfg->getopt();
    $verbose = defined $cfg->verbose ? $cfg->verbose : 0;
    info("This is sync.pl version $version\n");
    info("Check command line arguments ...\n");
    $cfg_file = get_check_path('config file', $cfg->config, 0, 1, 1);
}

my $initial_sync = '';
my $delete_excludes_in_initial_sync = '';

sub check_config_file
{
    my $cfg = AppConfig->new( {
        PEDANTIC => 1,
        GLOBAL => {
            EXPAND => EXPAND_ALL,
        }
    } );
    $cfg->define('verbose|v!');
    $cfg->define('source=s');
    $cfg->define('destination=s');
    $cfg->define('ssh_proxy=s');
    $cfg->define('initial_sync=s');
    $cfg->define('delete_excludes_in_initial_sync!');
    $cfg->define('rsync_filter|filter=s@');
    $cfg->define('monitor_excude|exclude=s@');

    error("Can not read config file <$cfg_file>\n") unless $cfg->file($cfg_file);
    $verbose = defined $cfg->verbose ? $cfg->verbose : 0;
    info("Check config file ...\n");

    check_source($cfg->source);
    check_destination($cfg->destination);

    check_initial_sync($cfg->initial_sync);

    $delete_excludes_in_initial_sync = $cfg->delete_excludes_in_initial_sync if $initial_sync && $cfg->delete_excludes_in_initial_sync;
    if ($delete_excludes_in_initial_sync eq '1')
    {
        $delete_excludes_in_initial_sync = '--delete-excluded';
        info("Delete excludes on initial sync\n");
    }

    check_proxy($cfg->ssh_proxy);
    check_filter($cfg->filter);
    check_exclude($cfg->exclude);

}

######################################################################
my $src = '';

sub check_source
{
    $src = shift;
    error ("No source specified") unless defined $src;
    $src =~ s/\/$//; # remove trailing /
    # we do't check for existing source now because it may be created with initial sync only
}

######################################################################
my $dst = '';

sub check_destination
{
    $dst = shift;
    error ("No destination specified") unless defined $dst;
    $dst =~ s/\/$//; # remove trailing /
}

######################################################################
sub check_initial_sync
{
    my $v = shift;
    return unless defined $v;
    error("Invalid value for \"initial_sync\" ($v)\n") unless $v =~ /^from_source|from_destination$/;
    $initial_sync = $v;
}

######################################################################
my $proxy = '';

sub check_proxy
{
    #$proxy = $cfg->get('ssh-proxy');
    my $v = shift;
    return unless defined $v;
    info("Use proxy: <$v>\n");
    $proxy = "-e 'ssh -A $v ssh'";
}

######################################################################
my $filters = []; # ref to array with rsync filter rules
my $filter_file; # tmp file handle
my $filter_fn = ''; # name of the temporary filter file
my $use_filter = ''; # rsync option for the filter

sub check_filter
{
    my $v = shift;
    return unless defined $v;
    # no further checks on filter rules (will be done by rsync later)
    $filters = $v;
    #info("Filters:\n" . join("\n", @$filters) . "\n");
    # create temporary filter file
    $filter_file = File::Temp->new(TEMPLATE => 'sync_filter_XXXXXXXX', DIR => "/tmp", UNLINK => 1);
    $filter_fn = $filter_file->filename;
    print $filter_file join("\n", @$filters) . "\n";
    info ("Create filter file <$filter_fn>\n");
    $use_filter = "-f '. $filter_fn'";
}

######################################################################
my $excludes = []; # ref to array with exclude paths for File::ChangeNotify
my $exclude_file; # tmp file handle
my $exclude_fn = ''; # name of the temporary exclude file
my $use_exclude = ''; # fswatch option for the excudes

sub check_exclude
{
    my $v = shift;
    return unless defined $v;
    # no further checks on exclude patterns (will be done by File::ChangeNotify later)
    #info("Excludes:\n" . join("\n", @$v) . "\n");
    map { $_ = "-e $_" } @$v; # make it exclude patterns in fswatch file format
    #info("Excludes:\n" . join("\n", @$v) . "\n");
    $excludes = $v;
    # create temporary exclude file
    $exclude_file = File::Temp->new(TEMPLATE => 'sync_exclude_XXXXXXXX', DIR => "/tmp", UNLINK => 1);
    $exclude_fn = $exclude_file->filename;
    print $exclude_file join("\n", @$excludes) . "\n";
    info ("Create exclude file <$exclude_fn>\n");
    $use_exclude = "--filter-from=$exclude_fn";
}

######################################################################
sub initial_full_sync
{
    # do initial sync via rsync
    my $cmd = "rsync -v -aPz $proxy --delete $delete_excludes_in_initial_sync $use_filter ";
    if ($initial_sync eq 'from_source')
    {
        $cmd .= "$src " . dirname $dst;
        info "Initial sync from <$src> to <$dst> ...\n";
        info "Run command: $cmd\n";
        my $rsp = `$cmd`;
        info $rsp;
    }
    elsif ($initial_sync eq 'from_destination')
    {
        $cmd .= "$dst ". dirname $src;
        info "Initial sync from <$dst> to <$src> ...\n";
        info "Run command: $cmd\n";
        my $rsp = `$cmd`;
        info $rsp;
    }
    else
    {
      info "No initial sync\n";
    }
}

######################################################################
sub sync_on_changes
{
     # now source directory has to exist so check this now
     error("Can not find local source path <$src>: $!\n") unless -d $src;

     # fork fswatch to monitor $src for changes
     my $pid;
     error("Can not fork: $!\n") unless defined ($pid = open(READER, "-|"));
     if ($pid)
     {   # parent
         info "Waiting for changes in $src ...\n";
         $/ = "\0"; # line separator is \0 (see option -0 in fswatch call)
         my %src_files = ();
         while (defined(my $fn = <READER>))
         {
             chop $fn;
             my $event = '';
             if ($fn ne "NoOp")
             {
                 $event = <READER>;
                 #info "fswatch: $fn ($event)\n";
                 #TODO next if -d $fn && $event =~ /Updated/ && $os eq 'cygwin'; # on cygwin: ignore update events for directories because we also track the files
                 next if $event =~ /Overflow/; # ignore overflow events
                 #info "fswatch: $fn ($event)\n";
             }
             if ($fn ne "NoOp")
             {  # file/directory change
                my $fn_r = $fn; # relative file name
                $fn_r =~ s/$src\///; # make file name relative to src
                $fn_r = '.' if $fn_r eq $src;
                #info "Detected change for <$fn> ($fn_r)\n";
                unless (-e "$src/$fn_r")
                {   # if file was deleted sync it's parent directory
                    $fn_r = dirname $fn_r;
                }
                $fn_r .= '/' if -d "$src/$fn_r"; # fix path for directories
                $src_files{$fn_r} = 1;
                #info "Accepted change as <$fn_r>\n";
             }
             else
             {   # end of batch detected
                 info "-------- job start ---\n";
                 # now %src_files contains all files to sync relative to $src
                 # write them to a tempory file used for "rsync --files-from" then
                 # see also https://stackoverflow.com/questions/16647476/how-to-rsync-only-a-specific-list-of-files
                 # create from filter file
                 my $from_file = File::Temp->new(TEMPLATE => 'sync_from_XXXXXXXX', DIR => "/tmp", UNLINK => 1);
                 my $from_fn = $filter_file->filename;
                 my $n = 0;
                 foreach my $fn_r (sort keys %src_files)
                 {
                     next unless -e "$src/$fn_r";  # don't sync files which do not longer exist
                     unless (-d "$src/$fn_r")
                     {
                         if (exists $src_files{dirname $fn_r})
                         {   # there is already a directory entry for this file so file will be synced via directory already
                             #info "sync $fn_r via directory\n";
                             next;
                         }
                     }
                     $n++;
                     info "Need to sync $src: <$fn_r> ($n)\n";
                     print $from_file "$fn_r\n";
                 }
                 %src_files = (); # reset hash with changed files
                 next unless $n;
                 #info "Need to sync $n files/dirs\n";
                 # synchronize using the following options (no recursive directories!)
                 # -v .. verbose
                 # -l .. copy symlinks as symlinks
                 # -p .. preserver permissions
                 # -t .. preserve modification times
                 # -g .. preserve group
                 # -o .. preserve owner
                 # -z .. compress transfer
                 # -P .. --partial --progress
                 my $cmd = "rsync -vlptgozP $proxy --delete $use_filter --files-from=$from_file $src $dst"; # we don't delete excluded files at destination!
                 info "Run command: $cmd\n";
                 my $rsp = `$cmd`;
                 info "$rsp\n";
                 info "======== job finished ===\n";
             }
         }
         close(READER);
     }
     else
     {   # child
         my @options = ( '-0', # line terminator is \0
                         '--batch-marker', # indicate end of batch
                         # TODO not working on freebsd: '--directories', # only watch directories to save file descriptors
                         '--latency=1', # latency between checks
                         '--format=%p%0%f',
                         '--event-flag-separator=,',
                         '-r', # recursive watching
                         $use_exclude, # use exclude patterns via tmp file
             );
         if ($os eq 'cygwin')
         {   # Cygwin specials
             push @options, (
                         '--directories', # only watch directories to save file descriptors
                         '--allow-overflow',
                         # improve Cygwin buffer handling; see https://emcrisostomo.github.io/fswatch/doc/1.14.0/fswatch.html/Monitors.html#Buffer-Overflow
                         '--monitor-property=windows.ReadDirectoryChangesW.buffer.size=8192',
                 );

         }
         exec("fswatch", @options, $src) or error("Can not exec fswatch: $!\n");
     }
}

main;
