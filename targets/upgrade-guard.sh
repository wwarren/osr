# shellcheck shell=bash
# Canonical copy: the block between the markers below is pasted unchanged into
# each installer that uses it.
# Upgrade signal guard
# upgrade_guard on|rollback|off: a signal (Ctrl-C, a closed SSH session,
# kill) during an upgrade must not stop this script before it can roll back.
# on: a signal is recorded in upgrade_interrupted; the upgrade's subshell dies
# from it, so its failure takes the rollback path. rollback: further signals
# are ignored while the previous release is restored. off: the defaults are
# back. After a hangup the output goes to OSR_INTERRUPT_LOG, so writes to the
# closed terminal cannot fail the rollback.
# Every copy matches targets/upgrade-guard.sh (tests/test-signal-rollback.sh).
upgrade_interrupted=''
upgrade_hangup() {
    upgrade_interrupted=${upgrade_interrupted:-129}
    exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
}
upgrade_guard() {
    case $1 in
        on)
            upgrade_interrupted=''
            trap 'upgrade_interrupted=${upgrade_interrupted:-130}' INT
            trap 'upgrade_interrupted=${upgrade_interrupted:-143}' TERM
            trap upgrade_hangup HUP ;;
        rollback) trap '' INT TERM HUP ;;
        off) trap - INT TERM HUP ;;
    esac
}
# End upgrade signal guard.
