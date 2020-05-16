
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

######################################################################
# configuration
my $verbose = 1;

# Source path. ATTENTION! No trailing / if this is a directory!
my $src = '/views1/psh/gc21';
my $src_exclude_file ="$src/gina/.gitignore";

# Destination path. ATTENTION! No trailing / if this is a directory!
# If this is remote path, then you should ssh-copy-id your public key to the remote host
# so you don't have to enter a password.
my $dst =  'peter@pluto:/tmp';

# TODO
# .gitignore files are not fully compliant to rsync exclude files:
#   A FILE that contains exclude patterns (one per line).  Blank
#   lines in the file and lines starting with ';' or '#' are
#   ignored.  If FILE is -, the list will be read from standard
#   input.
# So we should filter it and use -

######################################################################
# initial full sync
my $exclude = '';
$exclude = "--exclude-from=$src_exclude_file" if -e $src_exclude_file;
print "Syncing <$src> to <$dst> ...\n" if $verbose;
my $cmd = "rsync -avPz --delete $exclude $src $dst";
#print "$cmd\n" if $verbose;
my $rsp = `$cmd`;
print "Initial sync done\n" if $verbose;

######################################################################
# now sync on changes only
my $watcher = File::ChangeNotify->instantiate_watcher
    ( directories => [ $src ],
      #filter      => qr/\.(?:pm|conf|yml)$/,
      #exclude     => [ '', '' ],
      #follow_symlinks => true,
      sleep_interval => 1, # in seconds
    );

print "waiting for changes in $src ...\n" if $verbose;
$dst = "$dst/" . basename $src;
while (1) {
    my @events = $watcher->wait_for_events;
    for my $event (@events) {
        my $fn = $event->{path};
        my $type = $event->{type};
        my $fn_r = $fn;
        $fn_r =~ s/$src\///; # make file name relative to src
        print "$fn ($type)\n" if ($verbose);
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
        #print "$from -> $to\n" if ($verbose);
        $cmd = "rsync -avPz --delete $exclude $from $to";
        #print "$cmd\n" if $verbose;
        $rsp = `$cmd`;
        #print "$rsp\n" if $verbose;
    }
}
