
# This script can be used to synchronize files/directories between computers using the following
# tools:
# - ssh (1)
# - rsync (1)
# - https://metacpan.org/pod/File::ChangeNotify
# It follows an idea from https://rakhim.org/2018/10/fast-automatic-remote-file-sync/

use strict;
use warnings;

use File::ChangeNotify;
use File::Basename;
use AppConfig qw(:expand);

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
        else { error("Can not find any config file\n") }
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
my $dst = '';
my $exclude_from = '';
my $include_from = '';
my $gitignore = '';

sub check_config_file
{
    my $cfg = AppConfig->new( {
        PEDANTIC => 1,
        GLOBAL => {
            EXPAND => EXPAND_ALL,
        }
    } );
    $cfg->define('verbose|v!');
    $cfg->define('source|src=s');
    $cfg->define('destination|dst=s');
    $cfg->define('exclude-from=s');
    $cfg->define('include-from=s');
    $cfg->define('gitignore=s');
    error("Can not read config file <$cfg_file>\n") unless $cfg->file($cfg_file);
    $verbose = defined $cfg->verbose ? $cfg->verbose : 0;
    info("Check config file ...\n");
    $src = get_check_path('source path', $cfg->source, 1, 1, 0);
    $src =~ s/\/$//; # remove trailing /
    $dst = get_check_path('destination path', $cfg->destination, 0, 0, 0);
    $dst =~ s/\/$//; # remove trailing /
    error("Destination path is empty") unless $dst;
    $exclude_from = get_check_path('exclude-from file', $cfg->get('exclude-from'), 0, 1, 1);
    $include_from = get_check_path('include-from file', $cfg->get('include-from'), 0, 1, 1);
    $gitignore = get_check_path('gitignore file', $cfg->gitignore, 0, 1, 1);
    error "gitignore not allowed with exclude-from and/or include-from" if $gitignore && ($exclude_from || $include_from);
    $exclude_from = "--exclude-from=$exclude_from" if $exclude_from;
    $include_from = "--include-from=$include_from" if $include_from;
    $gitignore = "--exclude-from=$gitignore" if $gitignore; # TODO add correct handling instead of using it as exclude-from
}


######################################################################
sub initial_full_sync
{
    info "Syncing <$src> to <$dst> ...\n";
    my $cmd = "rsync -avPz --delete $exclude_from $include_from $gitignore $src $dst";
    #info "$cmd\n";
    my $rsp = `$cmd`;
    info "Initial sync done\n";
}

######################################################################
sub sync_on_changes
{

    my $watcher = File::ChangeNotify->instantiate_watcher
        ( directories => [ $src ],
          #filter      => qr/\.(?:pm|conf|yml)$/,
          #exclude     => [ '', '' ],
          #follow_symlinks => true,
          sleep_interval => 1, # in seconds
        );

    info "waiting for changes in $src ...\n";
    $dst = "$dst/" . basename $src;
    while (1) {
        my @events = $watcher->wait_for_events;
        for my $event (@events) {
            my $fn = $event->{path};
            my $type = $event->{type};
            my $fn_r = $fn;
            $fn_r =~ s/$src\///; # make file name relative to src
            info "$fn ($type)\n";
            my $from = '';
            my $to = '';
            if ($type eq 'delete')
            { # if file was deleted sync it's parent directory
                $fn_r = dirname $fn_r;
                next unless -e "$src/$fn_r";  # if a directory was deleted then we don't have to sync each of it's childs
                $from = "$src/$fn_r/";
            }
            else
            {
                $from = "$src/$fn_r";
            }
            $to = "$dst/$fn_r";
            #info "$from -> $to\n";
            my $cmd = "rsync -avPz --delete $exclude_from $include_from $gitignore $from $to";
            #info "$cmd\n";
            my $rsp = `$cmd`;
            #info "$rsp\n";
        }
    }
}

main;
