# sync

This little Perl script can be used to synchronize files and/or directories using
- ssh (1)
- rsync (1)

You need the following Perl modules installed:
- https://metacpan.org/pod/File::ChangeNotify
- https://metacpan.org/pod/File::Basename
- https://metacpan.org/pod/AppConfig

Usage: perl sync.pl [-v[erbose]] [-c[onfig] <config-file>]

Sync.pl is configured via a config file (see syncrc_sample for an example). If
no config file is specified via command line, then .syncrc in the current
directory is tried and if this does not exists ~/.syncrc

If the destination path in the config file is a remote path, then you should
ssh-copy-id (1) your public key to the remote host and also run ssh-agent (1) to
avoid entering the password for your private SSH key.

Sync.pl was tested on FreeBSD and Windows 7 (Cygwin).
