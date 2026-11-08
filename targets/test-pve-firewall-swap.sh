#!/usr/bin/env bash
# pve-firewall-swap.pl on its own: fixture mode (a plain directory, with the
# test hooks) and live mode (a fake cluster root named by
# OSR_FW_SWAP_LIVE_ROOT and a fake PVE::Firewall::Helpers that records the lock).
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../tests/lib/assert.sh"
swap=$here/pve-firewall-swap.pl
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/fixture/firewall" "$tmp/live/firewall" "$tmp/lib/PVE/Firewall"
cat > "$tmp/lib/PVE/Firewall/Helpers.pm" <<'PERL'
package PVE::Firewall::Helpers;
use strict;
use warnings;
sub lock_vmfw_conf {
    my ($vmid, $timeout, $code, @param) = @_;
    open my $log, '>>', $ENV{FAKE_LOCK_LOG} or die "log: $!\n";
    print {$log} "vm-$vmid $timeout\n";
    close $log;
    die "can't lock file 'firewall-vm-$vmid' - got timeout\n" if $ENV{FAKE_LOCK_FAIL};
    return $code->(@param);
}
1;
PERL
printf 'old\n' > "$tmp/seen"; printf 'new\n' > "$tmp/new"
fw=$tmp/fixture/firewall/281.fw
run_swap() { status=0; perl "$swap" "$@" > /dev/null 2>&1 || status=$?; }
temps() { find "$tmp/fixture/firewall" "$tmp/live/firewall" -name '*.tmp.*' | wc -l | tr -d ' '; }
inode() { stat -c %i "$1"; }

describe fw_swap_fixture
cp "$tmp/seen" "$fw"; before=$(inode "$fw")
run_swap "$fw" "$tmp/seen" "$tmp/new" 281 "$tmp/fixture"
assert_eq "an unchanged file is replaced" 0 "$status"
assert_eq "with the new content" new "$(cat "$fw")"
assert_ok "by a rename, not a write in place" test "$before" != "$(inode "$fw")"
assert_eq "leaving no staged file" 0 "$(temps)"
before=$(inode "$fw")
run_swap "$fw" "$tmp/new" "$tmp/new" 281 "$tmp/fixture"
assert_eq "the same content is nothing to do" 0 "$status"
assert_eq "and nothing is written" "$before" "$(inode "$fw")"
printf 'edited\n' > "$fw"; touch "$tmp/fail"
# With the staging-failure hook set, only a refusal before staging gives 1.
OSR_FW_SWAP_TEST_FAIL_FILE=$tmp/fail run_swap "$fw" "$tmp/seen" "$tmp/new" 281 "$tmp/fixture"
assert_eq "a file changed before the call is refused before staging" 1 "$status"
assert_eq "and left as it is" edited "$(cat "$fw")"
cp "$tmp/seen" "$fw"; touch "$tmp/edit"
OSR_FW_SWAP_TEST_EDIT_FILE=$tmp/edit run_swap "$fw" "$tmp/seen" "$tmp/new" 281 "$tmp/fixture"
assert_eq "an edit made while the replacement is staged is detected" 1 "$status"
assert_eq "and kept" "$(printf 'old\n# edited meanwhile')" "$(cat "$fw")"
assert_eq "the staged file is removed" 0 "$(temps)"
cp "$tmp/seen" "$fw"
OSR_FW_SWAP_TEST_FAIL_FILE=$tmp/fail run_swap "$fw" "$tmp/seen" "$tmp/new" 281 "$tmp/fixture"
assert_eq "a staging failure" 2 "$status"
assert_eq "leaves the live file whole" old "$(cat "$fw")"
assert_eq "and no staged file" 0 "$(temps)"
run_swap "$fw" "$tmp/missing" "$tmp/new" 281 "$tmp/fixture"
assert_eq "an unreadable copy is status 2" 2 "$status"
run_swap "$fw" "$tmp/seen"
assert_eq "so are missing arguments" 2 "$status"

describe fw_swap_live
export FAKE_LOCK_LOG=$tmp/lock.log OSR_FW_SWAP_LIVE_ROOT=$tmp/live PERL5LIB=$tmp/lib
live=$tmp/live/firewall/281.fw
spellings=("$tmp/live" "$tmp/live/")
if ln -s "$tmp/live" "$tmp/live-link" && [[ -L $tmp/live-link ]]; then
  spellings+=("$tmp/live-link")
else
  skip 'symlinked live root' 'this host cannot create a real symlink'
fi
for spelling in "${spellings[@]}"; do
  cp "$tmp/seen" "$live"; : > "$FAKE_LOCK_LOG"
  OSR_FW_SWAP_TEST_FAIL_FILE=$tmp/fail run_swap "$spelling/firewall/281.fw" "$tmp/seen" "$tmp/new" 281 "$spelling"
  assert_eq "the live root spelled $spelling takes the CT's Proxmox lock" 'vm-281 10' "$(cat "$FAKE_LOCK_LOG")"
  assert_eq "and ignores the test hooks (status)" 0 "$status"
  assert_eq "replacing the file" new "$(cat "$live")"
done
cp "$tmp/seen" "$live"; : > "$FAKE_LOCK_LOG"
run_swap "$tmp/fixture/firewall/281.fw" "$tmp/seen" "$tmp/new" 281 "$tmp/live"
assert_eq "a file outside the live firewall directory is refused" 2 "$status"
run_swap "$live" "$tmp/seen" "$tmp/new" 282 "$tmp/live"
assert_eq "so is another CT's ID" 2 "$status"
assert_eq "before any lock is taken" '' "$(cat "$FAKE_LOCK_LOG")"
FAKE_LOCK_FAIL=1 run_swap "$live" "$tmp/seen" "$tmp/new" 281 "$tmp/live"
assert_eq "a lock that cannot be taken is status 2" 2 "$status"
assert_eq "and changes nothing" old "$(cat "$live")"
assert_eq "no staged file is left anywhere" 0 "$(temps)"

summary
