#!/usr/bin/env perl
# Replace one Proxmox CT firewall file only if it still has the content read by
# the caller. The GUI/API uses the same per-CT cluster lock. Stage on pmxcfs and
# rename so a failed write cannot truncate the live firewall file.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use File::Temp qw(tempfile);

# Exit status: 0 replaced (or nothing to do), 1 FILE changed meanwhile and was
# left as it is, 2 anything else (bad arguments, lock, staging or rename).
sub fail { print STDERR @_; exit 2; }

fail("usage: pve-firewall-swap.pl FILE SEEN NEW VMID PVE_ETC\n") if @ARGV != 5;
my ($file, $seen_file, $new_file, $vmid, $pve_etc) = @ARGV;
# The live cluster filesystem however it is spelled (/etc/pve/, a symlink):
# only then the Proxmox lock is taken, and only otherwise test hooks apply.
# OSR_FW_SWAP_LIVE_ROOT can name one more live root (the tests' fake one); it
# never makes /etc/pve count as a fixture.
my $pve_real = abs_path($pve_etc);
my $live_root;
for my $candidate ('/etc/pve', $ENV{OSR_FW_SWAP_LIVE_ROOT}) {
    next if !defined($candidate) || $candidate eq '' || !defined($pve_real);
    my $root = abs_path($candidate);
    if (defined($root) && $root eq $pve_real) { $live_root = $root; last; }
}
my $live = defined($live_root);
if ($live) {
    my $dir = abs_path(dirname($file));
    fail("invalid CT firewall path: $file\n")
        if $vmid !~ /^[1-9][0-9]{2,8}$/ || !defined($dir)
        || $dir ne "$live_root/firewall" || basename($file) ne "$vmid.fw";
    $file = "$live_root/firewall/$vmid.fw";
}
# Fixture-only hooks (never on the live filesystem): a file whose existence
# simulates a staging failure, or an edit made between staging and the check.
sub hook { my ($name) = @_; return !$live && defined($ENV{$name}) && -e $ENV{$name}; }

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "read $path: $!\n";
    binmode $fh;
    local $/;
    my $data = <$fh>;
    close $fh or die "close $path: $!\n";
    return defined($data) ? $data : '';
}

my ($seen, $new);
eval { $seen = read_file($seen_file); $new = read_file($new_file); 1 } or fail($@);
my $swap = sub {
    return 1 if read_file($file) ne $seen;
    return 0 if $seen eq $new;

    my ($fh, $temporary) = tempfile("$vmid.fw.tmp.XXXXXXXX", DIR => dirname($file), UNLINK => 0);
    my $result;
    eval {
        binmode $fh;
        print {$fh} $new or die "write $temporary: $!\n";
        close $fh or die "close $temporary: $!\n";
        die "simulated firewall staging failure\n" if hook('OSR_FW_SWAP_TEST_FAIL_FILE');
        if (hook('OSR_FW_SWAP_TEST_EDIT_FILE')) {
            open my $edit, '>>', $file or die "edit $file: $!\n";
            print {$edit} "# edited meanwhile\n";
            close $edit;
        }
        # A direct writer that does not use the Proxmox lock may have edited
        # the file while we staged the replacement.
        if (read_file($file) ne $seen) {
            $result = 1;
        } else {
            rename $temporary, $file or die "replace $file: $!\n";
            $temporary = '';
            $result = read_file($file) eq $new ? 0 : 2;
        }
        1;
    } or do {
        warn $@;
        $result = 2;
    };
    unlink $temporary if $temporary ne '';
    return $result;
};

my $result;
eval {
    if ($live) {
        require PVE::Firewall::Helpers;
        $result = PVE::Firewall::Helpers::lock_vmfw_conf($vmid, 10, $swap);
        die "firewall lock returned no result\n" if !defined($result);
    } else {
        # Local fixture mode has no Proxmox Perl modules or cluster filesystem.
        $result = $swap->();
    }
    1;
} or do {
    warn $@;
    exit 2;
};
exit $result;
