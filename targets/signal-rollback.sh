# shellcheck shell=bash
# Canonical copy: the block between the markers below is pasted unchanged into
# each installer that uses it.
# Signal rollback helper
# A signal (Ctrl-C, a closed SSH session, kill) runs the same rollback as a
# failure: whatever the ERR trap holds at that moment, so a half-applied
# upgrade is undone; outside a rollback window it just stops the run. Further
# signals are ignored meanwhile, and after a hangup the output goes to
# OSR_INTERRUPT_LOG, so writes to the closed terminal cannot fail the rollback.
# Every copy matches targets/signal-rollback.sh (tests/test-signal-rollback.sh).
on_signal() {
    local status=$1 handler action
    local -a parts=()
    trap '' INT TERM HUP
    if [[ $status == 129 ]]; then
        exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
    fi
    printf '%s: stopped by a signal (status %s).\n' "${0##*/}" "$status" >&2
    handler=$(trap -p ERR)
    if [[ -n $handler ]]; then
        eval "parts=($handler)"
        action=${parts[2]}
        # The rollback handlers end in "exit 1": keep the signal's status.
        [[ $action != *'; exit 1' ]] || action="${action%exit 1}exit $status"
        trap - ERR
        eval "$action"
    fi
    exit "$status"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
# End signal rollback helper.
