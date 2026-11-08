#!/usr/bin/env bash
# Signals during an upgrade (Ctrl-C, a closed SSH session, kill) must roll
# back like a failure. Two shared blocks do it: targets/signal-rollback.sh for
# installers that roll back from an ERR trap, targets/upgrade-guard.sh for
# those that run the upgrade in a subshell and check its status. Every copy
# must match, every such installer must have one, and both are run here with
# real signals sent to a whole process group, as a terminal sends them.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/lib/assert.sh"
targets=$here/../targets
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

block() { awk -v start="$2" -v end="$3" '$0 == start {c=1} c {print} $0 == end {c=0}' "$1"; }
v1_start='# Signal rollback helper' v1_end='# End signal rollback helper.'
v2_start='# Upgrade signal guard' v2_end='# End upgrade signal guard.'

describe signal_rollback_copies
for t in airllm comfyui hermes llamacpp ollama open-terminal openclaw; do
  assert_eq "$t carries the shared signal rollback helper" "$(block "$targets/signal-rollback.sh" "$v1_start" "$v1_end")" \
    "$(block "$targets/$t/install-target.sh" "$v1_start" "$v1_end")"
done
for f in "$targets"/*/install-target.sh; do
  if grep -q "trap .*rollback.*' ERR" "$f"; then
    assert_contains "${f#"$targets"/}: an ERR-trap rollback has the signal helper" "$v1_start" "$(cat "$f")"
  fi
done
for t in strata basalt maya xolotl avalon kindi; do
  f=$targets/$t/install-target.sh
  assert_eq "$t carries the shared upgrade guard" "$(block "$targets/upgrade-guard.sh" "$v2_start" "$v2_end")" "$(block "$f" "$v2_start" "$v2_end")"
  upgrade=$(awk '/^do_upgrade\(\)/{c=1} c{print} c && /^}/{exit}' "$f")
  order=$(grep -oE 'upgrade_guard (on|rollback|off)|systemctl stop [a-z]+\.service$|\( apply_checkout|\( restore_runtime' <<< "$upgrade" | paste -sd'|')
  assert_eq "$t guards the whole upgrade, then its rollback" \
    "upgrade_guard on|systemctl stop $t.service|( apply_checkout|upgrade_guard off|upgrade_guard rollback|( restore_runtime" "$order"
  assert_contains "$t marks a failed rollback" ': > "$'"${t^^}"'_STATE_DIR/rollback-failed" || true' "$upgrade"
  assert_contains "$t stops the next run at that marker" '[[ -e $'"${t^^}"'_STATE_DIR/rollback-failed ]]' "$(sed -n '/^saved_settings$/,/^fi$/p' "$f")"
done

# run_group SIGNAL SCRIPT: SCRIPT in its own process group with SIGINT at its
# default (a background job starts with it ignored); once it is ready, SIGNAL
# goes to the whole group, then again while it rolls back. Sets $status.
run_group() {
  local signal=$1 script=$2 pid
  rm -f -- "$tmp/ready" "$tmp/rolling"; : > "$tmp/mark"; : > "$tmp/log"
  perl -e 'use POSIX (); POSIX::setsid(); $SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' -- \
    env TMP="$tmp" OSR_INTERRUPT_LOG="$tmp/log" bash "$script" > "$tmp/out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [[ -e $tmp/ready ]] && break; sleep 0.05; done
  kill -"$signal" -- "-$pid"
  for _ in $(seq 100); do [[ -e $tmp/rolling ]] && break; sleep 0.05; done
  kill -"$signal" -- "-$pid" 2>/dev/null || true
  status=0; wait "$pid" || status=$?
}

describe signal_rollback_helper
cat > "$tmp/v1.sh" <<SCRIPT
set -Eeuo pipefail
$(block "$targets/signal-rollback.sh" "$v1_start" "$v1_end")
rollback() { echo rolling >> "\$TMP/mark"; : > "\$TMP/rolling"; sleep 0.5; echo rolled-back >> "\$TMP/mark"; }
trap '[[ \$BASHPID == "\$\$" ]] || exit 1; rollback; exit 1' ERR
: > "\$TMP/ready"
sleep 5
echo 'not reached' >> "\$TMP/mark"
SCRIPT
for pair in INT:130 TERM:143 HUP:129; do
  signal=${pair%:*} code=${pair#*:}
  run_group "$signal" "$tmp/v1.sh"
  assert_eq "SIG$signal inside a rollback window keeps the signal's status" "$code" "$status"
  assert_eq "runs the ERR trap's rollback to the end, ignoring a second signal" $'rolling\nrolled-back' "$(cat "$tmp/mark")"
  if [[ $signal == HUP ]]; then
    assert_contains "after a hangup the output goes to OSR_INTERRUPT_LOG" 'stopped by a signal (status 129)' "$(cat "$tmp/log")"
  fi
done
sed -i '/^trap .*ERR$/d' "$tmp/v1.sh"
run_group TERM "$tmp/v1.sh"
assert_eq "outside a rollback window a signal just stops the run" 143 "$status"
assert_eq "without a rollback" '' "$(cat "$tmp/mark")"

describe upgrade_guard
cat > "$tmp/v2.sh" <<SCRIPT
set -Eeuo pipefail
$(block "$targets/upgrade-guard.sh" "$v2_start" "$v2_end")
upgrade_guard on
set +e
( : > "\$TMP/ready"; sleep 5 )
rc=\$?
set -e
if (( rc == 0 )); then upgrade_guard off; echo upgraded >> "\$TMP/mark"; exit 0; fi
upgrade_guard rollback
echo rolling >> "\$TMP/mark"; : > "\$TMP/rolling"
( sleep 0.5 )
echo "rolled-back \$upgrade_interrupted" >> "\$TMP/mark"
echo 'rollback finished'
exit 1
SCRIPT
for pair in INT:130 TERM:143 HUP:129; do
  signal=${pair%:*} code=${pair#*:}
  run_group "$signal" "$tmp/v2.sh"
  assert_eq "SIG$signal during the upgrade still reaches its rollback" $'rolling\nrolled-back '"$code" "$(cat "$tmp/mark")"
  assert_eq "which finishes despite a second signal, and fails the run" 1 "$status"
  if [[ $signal == HUP ]]; then
    assert_contains "after a hangup the output goes to OSR_INTERRUPT_LOG" 'rollback finished' "$(cat "$tmp/log")"
  fi
done

summary
