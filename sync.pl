
# This script can be used to synchronize files/directories between computers using the following
# tools:
# - ssh (1)
# - rsync (1)
# - https://metacpan.org/pod/File::ChangeNotify
# - https://metacpan.org/pod/File::Basename
# - https://metacpan.org/pod/File::Temp
# - https://metacpan.org/pod/AppConfig
# - https://metacpan.org/pod/Sereal::Encoder
# - https://metacpan.org/pod/Sereal::Decoder
#
# We used some ideas from
# - https://rakhim.org/2018/10/fast-automatic-remote-file-sync/ (for the common concept)
# - https://stackoverflow.com/questions/16654751/rsync-through-ssh-tunnel (for the proxy support)

use strict;
use warnings;

use File::ChangeNotify;
use File::Basename;
use File::Temp;
use AppConfig qw(:expand);
use Sereal::Encoder;
use Sereal::Decoder;

my $verbose = 0;
my $cfg_file = '';

######################################################################
sub main
{
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
    info("Check command line arguments ...\n");
    $cfg_file = get_check_path('config file', $cfg->config, 0, 1, 1);
}

my $src = '';
my $src_type;
my $src_base ='';
my $dst = '';
my $dst_type;
my $exclude_from = '';
my $include_from = '';
my $gitignore = '';
my $proxy = '';

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
    $cfg->define('exclude-from=s');
    $cfg->define('include-from=s');
    $cfg->define('gitignore=s');
    $cfg->define('ssh-proxy=s');
    error("Can not read config file <$cfg_file>\n") unless $cfg->file($cfg_file);
    $verbose = defined $cfg->verbose ? $cfg->verbose : 0;
    info("Check config file ...\n");

    check_source($cfg->source);
    check_destination($cfg->destination);

    check_source_destination();

    clear_batch_directory(); # we want a clean start

    $exclude_from = get_check_path('exclude-from file', $cfg->get('exclude-from'), 0, 1, 1);
    $include_from = get_check_path('include-from file', $cfg->get('include-from'), 0, 1, 1);
    if (defined $cfg->gitignore)
    {
        $gitignore = $cfg->gitignore;
        $gitignore =~ s/^local:// if $src_type eq 'local';
    }
    $gitignore = get_check_path('gitignore file', $gitignore, 0, 1, 1) if $dst_type ne 'batch';
    error "gitignore not allowed with exclude-from and/or include-from" if $gitignore && ($exclude_from || $include_from);
    $exclude_from = "--exclude-from=$exclude_from" if $exclude_from;
    $include_from = "--include-from=$include_from" if $include_from;
    $gitignore = "--exclude-from=$gitignore" if $gitignore; # TODO add correct handling instead of using it as exclude-from

    if ($dst_type eq 'remote')
    {
        $proxy = $cfg->get('ssh-proxy');
        info("Use proxy: <$proxy>\n") if defined $proxy;
        $proxy = defined $proxy ? "-e 'ssh -A $proxy ssh'" : '';
    }
}

######################################################################
sub check_source
{
    my $v = shift;
    $v = '' unless defined $v;
    error ("Invalid source specified: <$v>") unless $v =~ /^(local|batch):(.*)/;
    $src_type = $1;
    $src = $2;
    if ($src_type eq 'local')
    {
        error("Can not find local source path <$src>: $!\n") unless -r $src;
    }
    elsif ($src_type eq 'batch')
    {
        error ("Invalid source specified: <$v>") unless $src =~ /(.*?):(.*)/;
        $src = $1;
        $src_base = $2;
        error("Can not find source batch path <$src>: $!\n") unless -r $src;
        error("Source base is empty") unless $src_base;
    }
    else
    {
        error ("Invalid source specified: <$v>");
    }
}

######################################################################
sub check_destination
{
    my $v = shift;
    $v = '' unless defined $v;
    error ("Invalid destination specified: <$v>") unless $v =~ /^(local|remote|batch):(.*)/;
    $dst_type = $1;
    $dst = $2;
    if ($dst_type eq 'local')
    {
        error("Can not find local destination path <$dst>: $!\n") unless -r $dst;
    }
    elsif ($dst_type eq 'remote')
    {
        # no checks yet
    }
    elsif ($dst_type eq 'batch')
    {
        error ("Invalid destination specified: <$v>") unless $dst =~ /(.*?)(:(.*))?$/;
        $dst = $1;
        my $dst_base = $3;
        info "Ignore destination base <$dst_base>\n" if defined $dst_base;
        error("Can not find destination batch path <$dst>: $!\n") unless -r $dst;
    }
    else
    {
        error ("Invalid destination specified: <$v>");
    }
    error("Batch source and destination are not supported empty") if ($src_type eq 'batch') && ($dst_type eq 'batch');
    error("Destination path is empty") unless $dst;
}

######################################################################
sub initial_full_sync
{
    # We will not do an initial full sync if a batch spec is used!
    if ($dst_type eq 'batch')
    {
        info "Skip initial sync of <$src> to batch destination ...\n";
    }
    elsif ($src_type eq 'batch')
    {
        info "Initiate full syncing of <$src_base> to <$dst> ...\n";
        my $cmd = "rsync -avPz $proxy --delete $exclude_from $include_from $gitignore $src_base $dst";
        #info "$cmd\n";
        my $rsp = `$cmd`;
        info "Initial sync done\n";
    }
    else
    { # do initial sync via rsync
        info "Syncing <$src> to <$dst> ...\n";
        my $cmd = "rsync -avPz $proxy --delete $exclude_from $include_from $gitignore $src $dst";
        #info "$cmd\n";
        my $rsp = `$cmd`;
        info "Initial sync done\n";
    }
}

######################################################################
sub sync_on_changes
{

    my $watcher = File::ChangeNotify->instantiate_watcher
        ( directories => [ $src ],
          filter      => $src_type eq 'batch' ? qr/\.sync_batch$/ : qr/.*/,
          #exclude     => [ '', '' ],
          #follow_symlinks => true,
          sleep_interval => 1, # in seconds
        );

    info "waiting for changes in $src ...\n";
    $dst = "$dst/" . basename ($src_type eq 'batch' ? $src_base : $src) if $dst_type ne 'batch';
    while (1) {
        my @events = $watcher->wait_for_events;
        my %src_files = ();
        for my $event (@events) {
            my $fn = $event->{path};
            my $type = $event->{type};
            if ($src_type eq 'batch')
            { # handle batch job
                if ($type eq 'create')
                {
                    my $files = Sereal::Decoder->decode_from_file($fn);
                    foreach my $fn_r (keys %$files)
                    {
                        $src_files{$fn_r} = 1;
                        info "Add source <$fn_r> to sync from batch job\n";
                    }
                    unlink($fn); # delete batch file
                }
            }
            else
            { # handle native file
                my $fn_r = $fn;
                $fn_r =~ s/$src\///; # make file name relative to src
                info "$fn ($type)\n";
                if ($type eq 'delete')
                { # if file was deleted sync it's parent directory
                    $fn_r = dirname $fn_r;
                }
                $fn_r .= '/' if -d "$src/$fn_r"; # fix path for directories
                $src_files{$fn_r} = 1;
                info "Add source <$fn_r> to sync to batch job\n";
            }
        }
        # now %src_files contains all files to sync relative to $src
        # now sync all to destination
        if ($dst_type eq 'batch')
        { # create the batch file (step 1)
            create_batch(\%src_files);
        }
        else
        { # destination is a local or remote path
            foreach my $fn_r (sort keys %src_files)
            {
                my $from;
                if ($src_type eq 'batch')
                {
                    $from = "$src_base/$fn_r";
                }
                else
                {
                    next unless -e "$src/$fn_r";  # don't sync files which do not longer exist
                    $from = "$src/$fn_r";
                }
                my $to = "$dst/$fn_r";
                #info "$from -> $to\n";
                my $cmd = "rsync -avPz $proxy --delete $exclude_from $include_from $gitignore $from $to";
                info "$cmd\n";
                my $rsp = `$cmd`;
                #info "$rsp\n";
            }
        }
    }
}

sub create_batch
{ # create the batch file (step 1)
    my $files = shift;
    # filter all no longer existing files
    foreach my $fn_r (keys %$files)
    {
        delete $files->{$fn_r} unless -e "$src/$fn_r";  # skip files which do not longer exist
    }
    my $batch_fn;
    {
        my $tmp_file = File::Temp->new(TEMPLATE => 'job_XXXXXXXX', DIR => $dst, UNLINK => 0);
        $batch_fn = $tmp_file->filename;
    }
    info ("Create batch job <$batch_fn> ...\n");
    #my %src_files = %$files;
    Sereal::Encoder->encode_to_file($batch_fn, $files, 0);
    # rename the batch file from step 1 t%$o its final name (step 2)
    rename($batch_fn, "$batch_fn.sync_batch")
}

sub check_source_destination
{
    my $src_path = $src_type eq 'batch' ? $src_base : $src;
    error("Source and destination cannot both be remote\n") if ($src_path =~ /:/) && ($dst =~ /:/);
}

sub clear_batch_directory
{
    my $dir;
    $dir = $src if $src_type eq 'batch';
    error("Can not have both source and destination as batch\n") if (defined $dir && ($dst_type eq 'batch'));
    $dir = $dst if $dst_type eq 'batch';
    return unless defined $dir;
    unlink glob "$dir/job_*.sync_batch";
}

main;
