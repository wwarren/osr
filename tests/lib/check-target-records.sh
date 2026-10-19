#!/usr/bin/env bash
# Shared failure tests for the three targets' settings-record writers.
set -Eeuo pipefail
target=$1
scratch=$2
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
name=$(basename -- "$(dirname -- "$target")")
prefix=${name^^}
fail() { printf 'FAIL %s records: %s\n' "$name" "$*" >&2; exit 1; }
mkdir -p "$scratch"
python3 "$here/extract-functions.py" "$target" --only acquire_install_lock,as_service,publish_record,stage_record,write_pending,save_settings,ensure_api_key > "$scratch/functions.sh"
# shellcheck disable=SC1090
source "$scratch/functions.sh"
for helper in acquire_install_lock as_service publish_record stage_record write_pending save_settings ensure_api_key; do
    declare -F "$helper" >/dev/null || fail "missing helper $helper"
done
etc=$scratch/etc
printf -v "${prefix}_ETC_DIR" '%s' "$etc"
# Read by the extracted write_pending helper.
# shellcheck disable=SC2034
dry_run=0
settings_env() { printf 'complete settings\n'; }
settings_fingerprint() { printf 'complete fingerprint\n'; }
write_pending
cp "$etc/pending-env" "$scratch/checkpoint"
[[ $(stat -c %a "$etc/pending-env") == 600 ]] || fail 'checkpoint permissions'

# The real entry point must reject an overlapping run before reading settings
# or cleaning an active staging file. Killing the holder must release its lock.
if (( EUID == 0 )); then
    mkfifo "$scratch/release"
    holder=''
    cleanup_holder() {
        if [[ -n $holder ]]; then
            kill "$holder" 2>/dev/null || true
            wait "$holder" 2>/dev/null || true
        fi
    }
    trap cleanup_holder EXIT
    bash -c '
        set -Eeuo pipefail
        source "$1"
        printf -v "$2" "%s" "$3"
        dry_run=0
        die() { printf "%s\n" "$*" >&2; exit 1; }
        acquire_install_lock
        stage_record "$3/pending-env" printf "active writer\n" > "$4/ready"
        read -r _ < "$4/release"
    ' _ "$scratch/functions.sh" "${prefix}_ETC_DIR" "$etc" "$scratch" &
    holder=$!
    for ((attempt=0; attempt<200; attempt++)); do
        [[ -s $scratch/ready ]] && break
        kill -0 "$holder" 2>/dev/null || fail 'lock holder exited before readiness'
        sleep 0.01
    done
    [[ -s $scratch/ready ]] || fail 'lock holder did not become ready'
    active=$(< "$scratch/ready")
    [[ -f $active && $(stat -c %a "$etc.lock") == 600 ]] || fail 'holder did not stage privately'
    if env "${prefix}_ETC_DIR=$etc" bash "$target" --upgrade > "$scratch/contender.out" 2>&1; then
        fail 'overlapping installer succeeded'
    fi
    grep -q 'installer is already running' "$scratch/contender.out" || fail 'installer read settings before taking its lock'
    [[ -f $active ]] || fail 'contender deleted an active staging file'
    kill -TERM "$holder"
    wait "$holder" 2>/dev/null || true
    holder=''
    die() { fail "$*"; }
    (acquire_install_lock) || fail 'terminated installer retained its lock'
    [[ -f $etc.lock ]] || fail 'lock file was unlinked'
    trap - EXIT
fi
(
    printf -v "${prefix}_ETC_DIR" '%s' "$scratch/dry-run"
    dry_run=1 acquire_install_lock
)
[[ ! -e $scratch/dry-run.lock ]] || fail 'dry run created a lock file'

# A process started as the service account that outlives the installer (git's
# detached housekeeping, an upstream helper) must not keep the lock: as_service
# closes the lock's descriptor for its command.
(
    # shellcheck disable=SC2034  # read by the extracted as_service
    SERVICE_USER=nobody
    printf -v "${prefix}_DATA_DIR" '%s' "$scratch"
    runuser() { while [[ $1 != -- ]]; do shift; done; shift; "$@"; }
    exec {install_lock_fd}>>"$scratch/inherit.lock"
    flock -n "$install_lock_fd" || fail 'could not take the test lock'
    as_service bash -c '( sleep 5 & )'
)
exec {probe_fd}>>"$scratch/inherit.lock"
flock -n "$probe_fd" || fail 'a background process started through as_service kept the installer lock'
exec {probe_fd}>&-

# A short write must leave the original checkpoint intact.
settings_env() { printf 'partial\n'; return 1; }
if write_pending; then fail 'a failed checkpoint write succeeded'; fi
cmp -s "$etc/pending-env" "$scratch/checkpoint" || fail 'failed write truncated checkpoint'

# SIGTERM in the staging process can leave a temporary file, but must never
# publish it as the checkpoint that the next installer run reads.
settings_env() { printf 'partial\n'; kill -TERM "$BASHPID"; }
if write_pending; then fail 'an interrupted checkpoint write succeeded'; fi
cmp -s "$etc/pending-env" "$scratch/checkpoint" || fail 'interruption replaced checkpoint'

# Even if the first writer succeeds, failure in the second must not publish
# an installed fingerprint that would mask the pending settings.
settings_env() { printf 'partial\n'; return 1; }
if save_settings; then fail 'a failed settings write succeeded'; fi
[[ ! -e $etc/installed-settings && ! -e $etc/installed-env ]] || fail 'failed write published installed metadata'
cmp -s "$etc/pending-env" "$scratch/checkpoint" || fail 'failed promotion removed checkpoint'

# Existing good installed records must survive either writer failing, too.
printf 'old fingerprint\n' > "$etc/installed-settings"
printf 'old settings\n' > "$etc/installed-env"
cp "$etc/installed-settings" "$scratch/old-fingerprint"
cp "$etc/installed-env" "$scratch/old-env"
if save_settings; then fail 'a failed replacement succeeded'; fi
cmp -s "$etc/installed-settings" "$scratch/old-fingerprint" || fail 'failed second writer replaced fingerprint'
cmp -s "$etc/installed-env" "$scratch/old-env" || fail 'failed second writer replaced settings'
settings_env() { printf 'complete settings\n'; }
settings_fingerprint() { printf 'partial\n'; return 1; }
if save_settings; then fail 'a failed fingerprint write succeeded'; fi
cmp -s "$etc/installed-settings" "$scratch/old-fingerprint" || fail 'failed first writer replaced fingerprint'
cmp -s "$etc/installed-env" "$scratch/old-env" || fail 'failed first writer replaced settings'

# If publication itself fails between renames, every visible record is
# complete and pending-env is retained. installed-env is published first and
# the fingerprint last, so this is also the state after an interruption
# between the two renames: on a first install the settings exist without a
# "nothing to do" marker; on an upgrade the new settings sit next to the old
# marker, and the next run re-applies the new settings instead of reverting.
settings_fingerprint() { printf 'complete fingerprint\n'; }
mv() {
    [[ ${*: -1} != "$etc/installed-settings" ]] || return 1
    command mv "$@"
}
if save_settings; then fail 'a failed rename succeeded'; fi
cmp -s "$etc/installed-settings" "$scratch/old-fingerprint" || fail 'the fingerprint was published before the settings'
[[ $(< "$etc/installed-env") == 'complete settings' ]] || fail 'upgrade: the new settings were not published first'
rm -f "$etc/installed-env" "$etc/installed-settings"
if save_settings; then fail 'a failed rename succeeded'; fi
[[ $(< "$etc/installed-env") == 'complete settings' ]] || fail 'first install: settings not published first'
[[ ! -e $etc/installed-settings ]] || fail 'failed rename published the fingerprint'
cmp -s "$etc/pending-env" "$scratch/checkpoint" || fail 'failed rename removed checkpoint'
unset -f mv
rm -f "$etc/installed-env"

# Leftovers of a killed run (mktemp names: six characters after the record
# name) are removed before the next write; other files are left alone.
printf 'leftover\n' > "$etc/pending-env.Ab12Cd"
printf 'leftover key\n' > "$etc/api-key.Zz9Yy8"
printf 'not ours\n' > "$etc/pending-env.keep"
write_pending
[[ ! -e $etc/pending-env.Ab12Cd ]] || fail 'a staging leftover was not removed'
[[ -e $etc/api-key.Zz9Yy8 && -e $etc/pending-env.keep ]] || fail 'cleanup removed files it does not own'
rm -f "$etc/api-key.Zz9Yy8" "$etc/pending-env.keep"
cp "$etc/pending-env" "$scratch/checkpoint"

# Flush file contents before renaming, then flush the directory before
# publishing the next record or removing the recovery checkpoint.
sync() { printf '%s\n' "$*" >> "$scratch/sync.log"; command sync "$@"; }
mv() { printf 'mv %s\n' "${*: -1}" >> "$scratch/sync.log"; command mv "$@"; }
trace_line() { awk -v needle="$1" '$0 == needle { print NR; exit }' "$scratch/sync.log"; }
: > "$scratch/sync.log"
write_pending
file_line=$(grep -n "^-- $etc/pending-env\.[A-Za-z0-9]\{6\}$" "$scratch/sync.log" | cut -d: -f1)
rename_line=$(trace_line "mv $etc/pending-env")
directory_line=$(trace_line "-- $etc")
[[ -n $file_line && -n $rename_line && -n $directory_line ]] || fail 'checkpoint publication missed a flush'
[[ $(trace_line "-- $etc/..") -lt $file_line && $file_line -lt $rename_line && $rename_line -lt $directory_line ]] ||
    fail "checkpoint flush order: $(cat "$scratch/sync.log")"
cp "$etc/pending-env" "$scratch/checkpoint"
sync() {
    [[ ${*: -1} != "$etc"/pending-env.?????? ]] || return 1
    command sync "$@"
}
if write_pending; then fail 'a failed file flush was published'; fi
cmp -s "$etc/pending-env" "$scratch/checkpoint" || fail 'a failed file flush replaced the checkpoint'
[[ -z $(find "$etc" -name 'pending-env.??????') ]] || fail 'a failed file flush left its staging file'

# After a rename, failure to flush the directory must stop the transaction
# before the fingerprint is published or the checkpoint is removed.
printf 'old fingerprint\n' > "$etc/installed-settings"
cp "$etc/installed-settings" "$scratch/old-fingerprint"
sync() {
    [[ $* != "-- $etc" ]] || return 1
    command sync "$@"
}
if save_settings; then fail 'a failed settings-directory flush succeeded'; fi
[[ $(< "$etc/installed-env") == 'complete settings' ]] || fail 'settings rename did not precede directory flush'
cmp -s "$etc/installed-settings" "$scratch/old-fingerprint" || fail 'fingerprint published after failed settings-directory flush'
cmp -s "$etc/pending-env" "$scratch/checkpoint" || fail 'failed settings-directory flush removed checkpoint'
directory_flushes=$scratch/directory-flushes
: > "$directory_flushes"
sync() {
    if [[ $* == "-- $etc" ]]; then
        printf 'flush\n' >> "$directory_flushes"
        [[ $(wc -l < "$directory_flushes") -ne 2 ]] || return 1
    fi
    command sync "$@"
}
if save_settings; then fail 'a failed fingerprint-directory flush succeeded'; fi
[[ -e $etc/pending-env ]] || fail 'failed fingerprint-directory flush removed checkpoint'

# Both successful renames must be followed by directory flushes, and the
# deletion of pending-env must be followed by another one.
sync() { printf '%s\n' "$*" >> "$scratch/sync.log"; command sync "$@"; }
rm() { printf 'rm %s\n' "$*" >> "$scratch/sync.log"; command rm "$@"; }
: > "$scratch/sync.log"
save_settings
awk -v dir="-- $etc" -v env="mv $etc/installed-env" -v fingerprint="mv $etc/installed-settings" '
    $0 == env { if (state != 0) exit 1; state=1; next }
    $0 == dir && state == 1 { state=2; next }
    $0 == fingerprint { if (state != 2) exit 1; state=3; next }
    $0 == dir && state == 3 { state=4; next }
    /^rm / && /pending-env$/ { if (state != 4) exit 1; state=5; next }
    $0 == dir && state == 5 { state=6 }
    END { if (state != 6) exit 1 }
' "$scratch/sync.log" || fail "installed record flush order: $(cat "$scratch/sync.log")"
unset -f sync mv rm
write_pending

# ensure_api_key keeps an existing key and drops key staging leftovers; a new
# key is generated only when none exists.
openssl() { printf 'generated-key\n'; }
generate_api_key() { printf 'generated-key\n'; }
printf 'existing-key\n' > "$etc/api-key"
printf 'stale key copy\n' > "$etc/api-key.Qq1Ww2"
api_key=''
ensure_api_key
[[ $(< "$etc/api-key") == existing-key && $api_key == existing-key ]] || fail 'an existing API key was replaced'
[[ ! -e $etc/api-key.Qq1Ww2 ]] || fail 'a stale API key staging copy was kept'
rm -f "$etc/api-key"
ensure_api_key
[[ $(< "$etc/api-key") == generated-key && $(stat -c %a "$etc/api-key") == 600 ]] || fail 'a missing API key was not generated privately'
[[ -z $(find "$etc" -name 'api-key.??????') ]] || fail 'key generation left a staging file'
unset -f openssl generate_api_key

# A successful retry publishes both complete private records and drops the
# checkpoint only after both have been installed.
save_settings
[[ $(< "$etc/installed-env") == 'complete settings' ]] || fail 'settings not published'
[[ $(stat -c %a "$etc/installed-env") == 600 && $(stat -c %a "$etc/installed-settings") == 600 ]] || fail 'installed record permissions'
[[ ! -e $etc/pending-env ]] || fail 'successful promotion retained checkpoint'
