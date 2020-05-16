# sync

This little Perl script can be used to synchronize files and/or directories using
- ssh (1)
- rsync (1)

You need the following Perl modules installed:
- https://metacpan.org/pod/File::ChangeNotify
- https://metacpan.org/pod/File::Basename

If source or destination path is a remote path, then you should ssh-copy-id (1) your public key to the remote host.

It was tested on FreeBSD and Windows 7 (Cygwin).
