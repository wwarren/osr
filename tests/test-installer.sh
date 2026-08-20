#!/usr/bin/env bash
# Unit tests for the functions in ollama-smart-router-install.sh
#
# Functions are extracted (heredoc-aware) and sourced in isolation, so no
# container is created and no Proxmox host is required.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-${HERE}/../ollama-smart-router-install.sh}"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"
# shellcheck source=lib/mocks.sh
source "${HERE}/lib/mocks.sh"

[[ -f "$SCRIPT" ]] || { echo "installer not found: $SCRIPT" >&2; exit 1; }

FUNCS="$(mktemp)"
python3 "${HERE}/lib/extract-functions.py" "$SCRIPT" > "$FUNCS" || exit 1
bash -n "$FUNCS" || { echo "extracted functions do not parse" >&2; exit 1; }

mocks_init
trap 'mocks_cleanup; rm -f "$FUNCS"' EXIT

# Defaults the functions expect to exist (normally set at the top of the script).
NONINTERACTIVE=false
OLLAMA_PORT=11434
MODEL_SERVER_COUNT=3
MODEL_SERVER_MIN=1
MODEL_SERVER_MAX=20
STORAGE_CFG=""
GITEA_VERIFY_TLS=false
GITEA_SERVER_URL="https://git.example.net"
GITEA_ADMIN_USER="tester"
GITEA_OWNER="tester"
GITEA_REPO_NAME="ollama-smart-router"
GITEA_REPO_OWNER=""
GITEA_REPO_PRIVATE=true
MODEL_SERVERS=()
STORAGE_QUERY_ERROR=""
GITEA_CURL_OPTS=(--location)
CT_ID=100
TEMPLATE_STORAGE="local"
TEMPLATE_NAME=""
# shellcheck source=/dev/null
source "$FUNCS"

echo "Testing $(basename "$SCRIPT") — $(python3 "${HERE}/lib/extract-functions.py" "$SCRIPT" --list | wc -l) functions extracted"

# ── validators ────────────────────────────────────────────────────────────────
describe valid_ipv4
assert_ok   "accepts 1.2.3.4"            valid_ipv4 1.2.3.4
assert_ok   "accepts 255.255.255.255"    valid_ipv4 255.255.255.255
assert_ok   "accepts 0.0.0.0"            valid_ipv4 0.0.0.0
assert_ok   "accepts leading zeros"      valid_ipv4 010.1.1.1
assert_fail "rejects octet > 255"        valid_ipv4 256.1.1.1
assert_fail "rejects 3 octets"           valid_ipv4 1.2.3
assert_fail "rejects 5 octets"           valid_ipv4 1.2.3.4.5
assert_fail "rejects empty"              valid_ipv4 ""
assert_fail "rejects hostname"           valid_ipv4 example.com

describe valid_cidr
assert_ok   "accepts 10.0.0.5/24"        valid_cidr 10.0.0.5/24
assert_ok   "accepts /32"                valid_cidr 10.0.0.5/32
assert_ok   "accepts /1"                 valid_cidr 10.0.0.5/1
assert_fail "rejects /0"                 valid_cidr 10.0.0.5/0
assert_fail "rejects /33"                valid_cidr 10.0.0.5/33
assert_fail "rejects missing prefix"     valid_cidr 10.0.0.5
assert_fail "rejects bad address"        valid_cidr 999.0.0.1/24
assert_fail "rejects non-numeric prefix" valid_cidr 10.0.0.5/ab

describe valid_hostname_or_ip
assert_ok   "accepts hostname"           valid_hostname_or_ip ollama1.lan
assert_ok   "accepts single label"       valid_hostname_or_ip ollama1
assert_ok   "accepts ip"                 valid_hostname_or_ip 10.0.0.5
assert_fail "rejects leading dash"       valid_hostname_or_ip -bad.lan
assert_fail "rejects trailing dot"       valid_hostname_or_ip bad.lan.
assert_fail "rejects spaces"             valid_hostname_or_ip "a b"
assert_fail "rejects empty"              valid_hostname_or_ip ""

describe valid_http_url
assert_ok   "accepts http"               valid_http_url http://h
assert_ok   "accepts https with port"    valid_http_url https://h:8443
assert_ok   "accepts path"               valid_http_url https://h/api/v1
assert_fail "rejects ftp"                valid_http_url ftp://h
assert_fail "rejects bare host"          valid_http_url example.com
assert_fail "rejects empty"              valid_http_url ""

describe valid_optional_url
assert_ok   "accepts blank"              valid_optional_url ""
assert_ok   "accepts valid url"          valid_optional_url https://mm/hooks/x
assert_fail "rejects junk"               valid_optional_url not-a-url

describe valid_optional_ipv4
assert_ok   "accepts blank"              valid_optional_ipv4 ""
assert_ok   "accepts ip"                 valid_optional_ipv4 10.0.0.1
assert_fail "rejects junk"               valid_optional_ipv4 nope

describe valid_nonempty
assert_ok   "accepts text"               valid_nonempty x
assert_fail "rejects empty"              valid_nonempty ""

describe valid_bool
assert_ok   "accepts true"        valid_bool true
assert_ok   "accepts false"       valid_bool false
assert_fail "rejects True"        valid_bool True
assert_fail "rejects yes"         valid_bool yes
assert_fail "rejects 1"           valid_bool 1
assert_fail "rejects empty"       valid_bool ""

describe valid_positive_int
assert_ok   "accepts 1"                  valid_positive_int 1
assert_ok   "accepts 64"                 valid_positive_int 64
assert_fail "rejects 0"                  valid_positive_int 0
assert_fail "rejects negative"           valid_positive_int -5
assert_fail "rejects text"               valid_positive_int abc
assert_fail "rejects empty"              valid_positive_int ""

describe valid_keep_alive
assert_ok   "accepts blank (server default)" valid_keep_alive ""
assert_ok   "accepts -1 (never unload)"      valid_keep_alive -1
assert_ok   "accepts 0"                      valid_keep_alive 0
assert_ok   "accepts seconds"                valid_keep_alive 600
assert_ok   "accepts 30m"                    valid_keep_alive 30m
assert_ok   "accepts 2h"                     valid_keep_alive 2h
assert_ok   "accepts compound 1h30m"         valid_keep_alive 1h30m
assert_fail "rejects text"                   valid_keep_alive abc
assert_fail "rejects bad unit"               valid_keep_alive 5x
assert_fail "rejects negative duration"      valid_keep_alive -5

describe valid_ollama_addr
assert_ok   "accepts bare ip"            valid_ollama_addr 10.0.0.5
assert_ok   "accepts ip:port"            valid_ollama_addr 10.0.0.5:11434
assert_ok   "accepts hostname"           valid_ollama_addr ollama1.lan
assert_ok   "accepts full url"           valid_ollama_addr http://h:11434
assert_fail "rejects port 0"             valid_ollama_addr 10.0.0.5:0
assert_fail "rejects port > 65535"       valid_ollama_addr 10.0.0.5:99999
assert_fail "rejects spaces"             valid_ollama_addr "a b"
assert_fail "rejects empty"              valid_ollama_addr ""

describe normalize_ollama_url
assert_eq "bare ip gets scheme and port" "http://10.0.0.5:11434" "$(normalize_ollama_url 10.0.0.5)"
assert_eq "explicit port preserved"      "http://10.0.0.5:9999"  "$(normalize_ollama_url 10.0.0.5:9999)"
assert_eq "url passes through"           "http://h:1"            "$(normalize_ollama_url http://h:1)"
assert_eq "trailing slash stripped"      "http://h:1"            "$(normalize_ollama_url http://h:1/)"
assert_eq "hostname gets default port"   "http://ollama1.lan:11434" "$(normalize_ollama_url ollama1.lan)"
assert_eq "https preserved"              "https://h:8443"        "$(normalize_ollama_url https://h:8443)"

describe valid_tier_selection
MODEL_SERVER_COUNT=3
assert_ok   "accepts single"             valid_tier_selection 1
assert_ok   "accepts list"               valid_tier_selection 1,3
assert_ok   "tolerates spaces"           valid_tier_selection "1, 3"
assert_fail "rejects above count"        valid_tier_selection 4
assert_fail "rejects zero"               valid_tier_selection 0
assert_fail "rejects empty"              valid_tier_selection ""
assert_fail "rejects text"               valid_tier_selection a

# ── tier maths ────────────────────────────────────────────────────────────────
describe tier_selection_to_indices
assert_eq "1 -> 0"           "0"     "$(tier_selection_to_indices 1)"
assert_eq "1,3 -> 0 2"       "0 2"   "$(tier_selection_to_indices 1,3)"
assert_eq "dedupes 2,2"      "1"     "$(tier_selection_to_indices 2,2)"
assert_eq "handles spaces"   "0 1"   "$(tier_selection_to_indices '1, 2')"
assert_eq "preserves order"  "2 0"   "$(tier_selection_to_indices 3,1)"

describe seq_csv
assert_eq "2..5"          "2,3,4,5" "$(seq_csv 2 5)"
assert_eq "single"        "3"       "$(seq_csv 3 3)"
assert_eq "empty range"   ""        "$(seq_csv 3 2)"

describe default_tier_selection
# Four tiers now. Every server must be used exactly once when there are enough
# of them, and every tier must still get *a* server when there are not.
for n in 1 2 3 4 5 6 8 9 12 20; do
  MODEL_SERVER_COUNT=$n
  f="$(default_tier_selection fast)";  m="$(default_tier_selection medium)"
  l="$(default_tier_selection large)"; x="$(default_tier_selection xlarge)"
  if (( n >= 4 )); then
    all="$(printf '%s,%s,%s,%s' "$f" "$m" "$l" "$x" | tr ',' '\n' | grep -c .)"
    uniq="$(printf '%s,%s,%s,%s' "$f" "$m" "$l" "$x" | tr ',' '\n' | sort -n | uniq | grep -c .)"
    if [[ "$all" == "$n" && "$uniq" == "$n" ]]; then
      _pass "N=${n} covers every server exactly once (${f} / ${m} / ${l} / ${x})"
    else
      _fail "N=${n} coverage" "${n} unique assignments" "${all} total / ${uniq} unique"
    fi
  else
    if [[ -n "$f" && -n "$m" && -n "$l" && -n "$x" ]]; then
      _pass "N=${n} every tier still gets a server (${f} / ${m} / ${l} / ${x})"
    else
      _fail "N=${n} tiers populated" "all non-empty" "${f}/${m}/${l}/${x}"
    fi
  fi
done
# Ordering: a tier never sits on a lower-numbered server than the tier below it.
MODEL_SERVER_COUNT=8
first() { printf '%s' "${1%%,*}"; }
assert_ok "tiers are assigned in ascending server order" bash -c "
  f=\$(printf '%s' '$(default_tier_selection fast)'   | cut -d, -f1)
  m=\$(printf '%s' '$(default_tier_selection medium)' | cut -d, -f1)
  l=\$(printf '%s' '$(default_tier_selection large)'  | cut -d, -f1)
  x=\$(printf '%s' '$(default_tier_selection xlarge)' | cut -d, -f1)
  [ \$f -le \$m ] && [ \$m -le \$l ] && [ \$l -le \$x ]"
# The remainder lands on xlarge, which gains most from parallel capacity.
MODEL_SERVER_COUNT=6
assert_eq "xlarge absorbs the remainder at N=6" "4,5,6" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=1
assert_eq "a single server backs every tier" "1" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=2
assert_eq "at N=2 the upper tiers share server 2" "2" "$(default_tier_selection large)"
assert_eq "and xlarge shares it too"              "2" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=3
assert_eq "at N=3 large and xlarge share server 3" "3" "$(default_tier_selection large)"
assert_eq "xlarge on server 3 as well"             "3" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=4

describe indices_to_urls
MODEL_SERVERS=(http://a:1 http://b:2 http://c:3)
assert_eq "single index"   "http://a:1"             "$(indices_to_urls '0')"
assert_eq "multiple"       "http://a:1,http://c:3"  "$(indices_to_urls '0 2')"
assert_eq "empty"          ""                       "$(indices_to_urls '')"

describe ip_in_same_subnet
assert_ok   "gateway inside /24"   ip_in_same_subnet 192.168.11.80/24 192.168.11.1
assert_fail "gateway outside /24"  ip_in_same_subnet 192.168.11.80/24 10.99.99.1
assert_ok   "wide prefix contains" ip_in_same_subnet 10.0.0.5/8 10.255.0.1
assert_ok   "unparseable is lenient" ip_in_same_subnet "garbage" "also-garbage"

# ── storage discovery ─────────────────────────────────────────────────────────
describe parse_pvesm_table
out="$(printf '%s\n' "$PVESM_REAL_OUTPUT" | parse_pvesm_table)"
assert_contains "reads Available despite (KiB) header tokens" "22194088960" "$out"
assert_eq "picks the Available column, not Used" \
  "2569773824" "$(printf '%s\n' "$PVESM_REAL_OUTPUT" | parse_pvesm_table | awk -F'\t' '$1=="vm_pool"{print $3}')"
assert_not_contains "excludes inactive storage" "dead-store" "$out"
assert_eq "row count (active only)" "5" "$(printf '%s\n' "$PVESM_REAL_OUTPUT" | parse_pvesm_table | grep -c .)"
alt="$(printf '%s\n' "$PVESM_ALT_ORDER" | parse_pvesm_table | awk -F'\t' '$1=="local-lvm"{print $3}')"
assert_eq "handles the alternate column order" "308819968" "$alt"

describe kib_to_gib
assert_eq "1 GiB"            "1"     "$(kib_to_gib 1048576)"
assert_eq "floors partial"   "0"     "$(kib_to_gib 1048575)"
assert_eq "large value"      "21165" "$(kib_to_gib 22194088960)"
assert_eq "zero"             "0"     "$(kib_to_gib 0)"
assert_eq "non-numeric -> 0" "0"     "$(kib_to_gib abc)"
assert_eq "empty -> 0"       "0"     "$(kib_to_gib '')"

describe storage_names_supporting
cfgdir="$(mktemp -d)"; STORAGE_CFG="${cfgdir}/storage.cfg"
cat > "$STORAGE_CFG" <<'EOF'
dir: local
	path /var/lib/vz
	content iso,vztmpl,backup

lvmthin: local-lvm
	thinpool data
	content rootdir,images

rbd: vm_pool
	pool rbd
	content images,rootdir
EOF
assert_eq "finds rootdir storages" "local-lvm vm_pool" "$(storage_names_supporting rootdir | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "finds vztmpl storages"  "local"             "$(storage_names_supporting vztmpl | tr -d '\n')"
assert_eq "unknown content type"   ""                  "$(storage_names_supporting snippets)"
STORAGE_CFG="/nonexistent"
assert_eq "unreadable config is silent" "" "$(storage_names_supporting rootdir)"
STORAGE_CFG="${cfgdir}/storage.cfg"

describe storage_candidates
mock_script pvesm <<'EOF'
for a in "$@"; do [ "$prev" = "-content" ] && content="$a"; prev="$a"; done
if [ "${content:-}" = "rootdir" ]; then
  echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
  echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
else
  echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
  echo "local                      dir     active        20155608        10782840         8323580   53.50%"
  echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
  echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
fi
exit 0
EOF
assert_eq "uses the server-side filter when it returns rows" \
  "local-lvm" "$(storage_candidates rootdir | awk -F'\t' '{print $1}' | tr -d '\n')"

mock_script pvesm <<'EOF'
for a in "$@"; do [ "$prev" = "-content" ] && content="$a"; prev="$a"; done
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
if [ -z "${content:-}" ]; then
  echo "local                      dir     active        20155608        10782840         8323580   53.50%"
  echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
  echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
fi
exit 0
EOF
assert_eq "falls back to storage.cfg when the filter is empty" \
  "local-lvm vm_pool" "$(storage_candidates rootdir | awk -F'\t' '{print $1}' | sort | tr '\n' ' ' | sed 's/ $//')"

cat > "$STORAGE_CFG" <<'EOF'
dir: local
	content iso,vztmpl,backup
EOF
assert_eq "readable config declaring none is definitive" "" "$(storage_candidates rootdir)"
STORAGE_CFG="/nonexistent"
assert_ne "unreadable config offers everything" "" "$(storage_candidates rootdir 2>/dev/null)"
STORAGE_CFG="${cfgdir}/storage.cfg"

describe storage_free_gib
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
exit 0
EOF
assert_eq "known storage"    "2450" "$(storage_free_gib vm_pool rootdir)"
assert_eq "unknown -> -1"    "-1"   "$(storage_free_gib nope rootdir)"

describe storage_supports_vztmpl
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "local                      dir     active        20155608        10782840         8323580   53.50%"
exit 0
EOF
assert_ok   "storage present"  storage_supports_vztmpl local
assert_fail "storage absent"   storage_supports_vztmpl vm_pool

describe select_storage_with_space
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
exit 0
EOF
NONINTERACTIVE=true
PICK=""
assert_ok "succeeds when something fits" select_storage_with_space rootdir 64 PICK ""
select_storage_with_space rootdir 64 PICK "" >/dev/null 2>&1
assert_eq "picks the largest that fits" "vm_pool" "$PICK"
PICK=""
select_storage_with_space rootdir 4 PICK "local-lvm" >/dev/null 2>&1
assert_eq "prefers the caller's choice when it fits" "local-lvm" "$PICK"
PICK=""
select_storage_with_space rootdir 4 PICK "does-not-exist" >/dev/null 2>&1
assert_eq "falls back when preferred is unknown" "vm_pool" "$PICK"
assert_fail "fails when nothing is big enough" select_storage_with_space rootdir 99999 PICK ""
NONINTERACTIVE=false

describe diagnose_storage
out="$(diagnose_storage rootdir 2>&1)"
assert_contains "reports the content type asked for" "rootdir" "$out"
assert_contains "shows all active storages"          "all active storages" "$out"

# ── template selection ────────────────────────────────────────────────────────
describe template_storages
TEMPLATE_STORAGE="my-tpl"
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "local                      dir     active        20155608        10782840         8323580   53.50%"
exit 0
EOF
out="$(template_storages)"
assert_contains "includes the configured storage first" "my-tpl" "$out"
assert_contains "includes discovered storages"          "local"  "$out"
assert_eq "deduplicates" "$(template_storages | sort -u | wc -l)" "$(template_storages | wc -l)"

describe find_existing_debian_template
mock_script pvesm <<'EOF'
echo "Name  Type  Status  Total (KiB)  Used (KiB)  Available (KiB)  %"
echo "local  dir  active  100  10  90  10%"
exit 0
EOF
mock_script pveam <<'EOF'
if [ "$1" = "list" ]; then
  echo "NAME                                                         SIZE"
  echo "local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst          120MB"
  echo "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst          119MB"
fi
exit 0
EOF
TEMPLATE_STORAGE="local"; TEMPLATE_NAME=""
assert_eq "picks the highest version" \
  "local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst" "$(find_existing_debian_template)"
TEMPLATE_NAME="debian-13-standard_13.0-1_amd64.tar.zst"
assert_eq "honours an explicit TEMPLATE_NAME" \
  "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst" "$(find_existing_debian_template)"
TEMPLATE_NAME=""
mock_command pveam 0 "NAME  SIZE"
assert_fail "fails when no template exists" find_existing_debian_template

describe select_available_debian_template
mock_script pveam <<'EOF'
if [ "$1" = "available" ]; then
  echo "section  package"
  echo "system   debian-13-standard_13.1-1_amd64.tar.zst"
  echo "system   debian-12-standard_12.7-1_amd64.tar.zst"
fi
exit 0
EOF
assert_eq "selects the newest debian 13" \
  "debian-13-standard_13.1-1_amd64.tar.zst" "$(select_available_debian_template)"
mock_command pveam 0 "section  package"
assert_fail "fails when nothing is downloadable" select_available_debian_template

# ── container helpers ─────────────────────────────────────────────────────────
describe require_command
assert_ok   "existing command"  require_command bash
assert_fail "missing command"   bash -c "source '$FUNCS'; require_command definitely-not-a-real-binary"

describe find_next_ct_id
mock_script pct <<'EOF'
[ "$1" = "status" ] && { case "$2" in 100|101) exit 0;; *) exit 1;; esac; }
exit 0
EOF
mock_command pvesh 0 "102"
CT_ID=""
assert_eq "uses pvesh nextid when free" "102" "$(find_next_ct_id)"
CT_ID="150"
assert_eq "honours an explicit free CT_ID" "150" "$(find_next_ct_id)"
CT_ID="100"
assert_fail "rejects an occupied CT_ID" find_next_ct_id
CT_ID="abc"
assert_fail "rejects a non-numeric CT_ID" find_next_ct_id
CT_ID=""

describe run_ct
CT_ID=999
mock_command pct 0
run_ct echo hello >/dev/null 2>&1
assert_contains "delegates to pct exec" "exec 999 -- echo hello" "$(mock_calls)"

describe apt_get
mock_reset_log
mock_command pct 0
assert_ok "succeeds first try" apt_get update
mock_reset_log
mock_command pct 1
assert_fail "gives up after retries" apt_get update
assert_eq "retried three times" "3" "$(mock_call_count 'apt-get update')"

describe wait_for_ct_ready
mock_script pct <<'EOF'
# systemctl probe succeeds, DNS probe succeeds
case "$*" in
  *is-system-running*) echo running;;
esac
exit 0
EOF
assert_ok "returns once systemd and DNS are up" wait_for_ct_ready

# ── gitea helpers ─────────────────────────────────────────────────────────────
describe init_gitea_curl_opts
GITEA_VERIFY_TLS=true;  init_gitea_curl_opts 2>/dev/null
assert_not_contains "verification on omits --insecure" "--insecure" "${GITEA_CURL_OPTS[*]}"
GITEA_VERIFY_TLS=false; init_gitea_curl_opts 2>/dev/null
assert_contains "verification off adds --insecure" "--insecure" "${GITEA_CURL_OPTS[*]}"

describe gitea_diagnose_rc
assert_contains "6 mentions DNS"          "DNS"         "$(gitea_diagnose_rc 6 https://g 2>&1)"
assert_contains "7 mentions the appliance" "nginx"      "$(gitea_diagnose_rc 7 https://g 2>&1)"
assert_contains "22 mentions 401"          "401"        "$(gitea_diagnose_rc 22 https://g 2>&1)"
assert_contains "60 mentions certificate"  "certificate" "$(gitea_diagnose_rc 60 https://g 2>&1)"
assert_contains "unknown code is reported" "99"         "$(gitea_diagnose_rc 99 https://g 2>&1)"

describe gitea_probe_user
mock_command curl 0 '{"login":"mike"}'
assert_eq "returns the login" "mike" "$(gitea_probe_user TOKEN 2>/dev/null)"
mock_command curl 22
assert_fail "fails when curl fails" gitea_probe_user TOKEN

describe gitea_api
auth="Authorization: token X"
mock_command curl 0 'body'
out="$(gitea_api GET https://g/api 2>/dev/null)"
assert_contains "passes the method through" "-X GET" "$(mock_calls)"
mock_reset_log
gitea_api POST https://g/api '{"a":1}' >/dev/null 2>&1
assert_contains "sends a JSON body on POST" "Content-Type: application/json" "$(mock_calls)"

describe resolve_gitea_repo
GITEA_REPO_OWNER=""; GITEA_OWNER="mike"
mock_script curl <<'EOF'
# GET /repos/mike/... -> 200 with the trailing status line gitea_api appends
echo '{"default_branch":"main"}'
echo 200
exit 0
EOF
assert_status "found under the token owner" 0 resolve_gitea_repo TOKEN
GITEA_REPO_OWNER="org-team"
mock_script curl <<'EOF'
echo '{"message":"not found"}'
echo 404
exit 0
EOF
assert_status "explicit owner, repo missing -> 2" 2 resolve_gitea_repo TOKEN
GITEA_REPO_OWNER=""

# ── config generation ─────────────────────────────────────────────────────────
describe push_local_config_tree
tree="$(mktemp -d)"; mkdir -p "${tree}/env"; echo "X=1" > "${tree}/env/router.env"
mock_reset_log; mock_command pct 0
CT_ID=321
push_local_config_tree "$tree" >/dev/null 2>&1
assert_contains "pushes a tarball into the container" "push 321" "$(mock_calls)"
assert_contains "extracts it under the config dir"    "tar -xzf"  "$(mock_calls)"
rm -rf "$tree"

describe cleanup_on_error
CT_CREATED=""; STAGE_DIR="$(mktemp -d)"
mock_reset_log; mock_command pct 0
cleanup_on_error >/dev/null 2>&1 || true
assert_eq "no container destroyed when none was created" "0" "$(mock_call_count 'destroy')"
assert_ok "removes the staging directory" bash -c "[[ ! -d '$STAGE_DIR' ]]"
CT_CREATED=1; STAGE_DIR=""; CT_ID=777
mock_reset_log
cleanup_on_error >/dev/null 2>&1 || true
assert_contains "destroys a half-provisioned container" "destroy 777" "$(mock_calls)"
CT_CREATED=""

# ── prompts ───────────────────────────────────────────────────────────────────
describe prompt_value
NONINTERACTIVE=false
RESULT=""
prompt_value "x" RESULT "thedefault" <<< ""
assert_eq "empty input takes the default" "thedefault" "$RESULT"
prompt_value "x" RESULT "thedefault" <<< "typed"
assert_eq "typed input wins" "typed" "$RESULT"
NONINTERACTIVE=true
RESULT=""
prompt_value "x" RESULT "auto"
assert_eq "non-interactive uses the default" "auto" "$RESULT"
NONINTERACTIVE=false

describe prompt_until_valid
RESULT=""
prompt_until_valid "ip" RESULT "10.0.0.1" valid_ipv4 <<< "" >/dev/null 2>&1
assert_eq "accepts the default" "10.0.0.1" "$RESULT"
prompt_until_valid "ip" RESULT "10.0.0.1" valid_ipv4 <<< $'bad\n10.0.0.9' >/dev/null 2>&1
assert_eq "re-prompts until valid" "10.0.0.9" "$RESULT"
NONINTERACTIVE=true
assert_fail "non-interactive rejects an invalid preset" \
  prompt_until_valid "ip" RESULT "not-an-ip" valid_ipv4
NONINTERACTIVE=false
# Exhausted stdin with an invalid default used to spin forever, hanging any
# piped or partially-answered run. It must give up instead.
assert_status "gives up when stdin runs out" 1 \
  timeout 5 bash -c "source '$FUNCS'; NONINTERACTIVE=false; R=''; \
                     prompt_until_valid 'ip' R 'not-an-ip' valid_ipv4 < /dev/null"
assert_ok "still accepts a valid default at EOF" \
  timeout 5 bash -c "source '$FUNCS'; NONINTERACTIVE=false; R=''; \
                     prompt_until_valid 'ip' R '10.0.0.1' valid_ipv4 < /dev/null"

describe prompt_secret
SECRET=""
prompt_secret "pw" SECRET <<< $'a\nb\nsame\nsame' >/dev/null 2>&1
assert_eq "loops until both entries match" "same" "$SECRET"

describe prompt_optional_secret
SECRET="preset"
prompt_optional_secret "tok" SECRET <<< "" >/dev/null 2>&1
assert_eq "blank input yields empty" "" "$SECRET"
prompt_optional_secret "tok" SECRET <<< "abc123" >/dev/null 2>&1
assert_eq "captures the value" "abc123" "$SECRET"

describe prompt_network_config
BRIDGE=vmbr0; IP_CIDR=10.0.0.5/24; GATEWAY=10.0.0.1; NAMESERVER=""
_pn_out="$(mktemp)"
prompt_network_config > "$_pn_out" 2>&1 <<< $'\n\n\n\n' || true
assert_eq "keeps defaults on empty input" "10.0.0.5/24" "$IP_CIDR"
IP_CIDR=192.168.50.10/24; GATEWAY=10.99.99.1
prompt_network_config > "$_pn_out" 2>&1 <<< $'\n\n\n\n' || true
assert_contains "warns when the gateway is off-subnet" "outside" "$(cat "$_pn_out")"
rm -f "$_pn_out"

describe prompt_mattermost_config
MATTERMOST_WEBHOOK_URL=""; MATTERMOST_CHANNEL="ollama-monitor"
MATTERMOST_MONITOR_USER="OllamaMonitor"; MATTERMOST_VERIFY_TLS="true"
_pm_out="$(mktemp)"
prompt_mattermost_config > "$_pm_out" 2>&1 <<< $'\n' || true
assert_contains "blank webhook disables alerting" "No webhook" "$(cat "$_pm_out")"
rm -f "$_pm_out"
prompt_mattermost_config <<< $'https://mm/hooks/x\nchan\nuser\nfalse' >/dev/null 2>&1
assert_eq "captures the webhook" "https://mm/hooks/x" "$MATTERMOST_WEBHOOK_URL"
assert_eq "captures the channel"  "chan" "$MATTERMOST_CHANNEL"
assert_eq "captures verify-tls"   "false" "$MATTERMOST_VERIFY_TLS"
# An internal Mattermost behind a self-signed cert must be configurable here.
MATTERMOST_VERIFY_TLS="true"
prompt_mattermost_config <<< $'https://mm/hooks/x\n\n\n\n' >/dev/null 2>&1
assert_eq "verify-tls defaults through" "true" "$MATTERMOST_VERIFY_TLS"
MATTERMOST_VERIFY_TLS="true"

describe prompt_model_servers
MODEL_SERVER_COUNT=3; MODEL_SERVER_MIN=1; MODEL_SERVER_MAX=20
MODEL_SERVER_1=10.0.0.51; MODEL_SERVER_2=10.0.0.52; MODEL_SERVER_3=10.0.0.53
MODEL_SERVER_4=""; MODEL_SERVER_5=""
TIER_FAST_SERVERS=""; TIER_MEDIUM_SERVERS=""; TIER_LARGE_SERVERS=""; TIER_XLARGE_SERVERS=""
MODEL_FAST=a; MODEL_MEDIUM=b; MODEL_LARGE=c; MODEL_XLARGE=d; OLLAMA_KEEP_ALIVE=""
MODEL_SERVERS=(); TIER_FAST_IDX=""; TIER_MEDIUM_IDX=""; TIER_LARGE_IDX=""; TIER_XLARGE_IDX=""
# Redirect to a file rather than $(...): command substitution runs the function
# in a subshell, where its assignments to MODEL_SERVERS et al. are discarded.
_pms_out="$(mktemp)"
prompt_model_servers > "$_pms_out" 2>&1 <<< $'0\n21\nabc\n2\n10.0.0.1\n10.0.0.2\n\n\n\n\n\n\n\n' || true
out="$(cat "$_pms_out")"
assert_contains "rejects a count below the minimum" "too few" "$out"
assert_contains "rejects a count above the maximum" "too many" "$out"
assert_contains "rejects a non-numeric count"       "not a whole number" "$out"
assert_eq "settles on the valid count" "2" "$MODEL_SERVER_COUNT"
assert_eq "normalises entered addresses" "http://10.0.0.1:11434" "${MODEL_SERVERS[0]}"
MODEL_SERVERS=(); MODEL_SERVER_COUNT=3
prompt_model_servers > "$_pms_out" 2>&1 <<< $'3\n10.0.0.1\n10.0.0.1\n10.0.0.3\n\n\n\n\n\n\n\n' || true
out="$(cat "$_pms_out")"; rm -f "$_pms_out"
assert_contains "warns about duplicate addresses" "same address" "$out"

# ── python provisioning ───────────────────────────────────────────────────────
describe ensure_openwebui_python
OPENWEBUI_PY_VERSION=3.12; OPENWEBUI_PY_DIR=/opt/python
mock_script pct <<'EOF'
shift 2   # drop "exec <id>"
[ "$1" = "--" ] && shift
case "$1" in
  bash) case "$*" in
          *"command -v python3.12"*) echo "/usr/bin/python3.12"; exit 0;;
          *) exit 0;;
        esac;;
  runuser) exit 0;;   # service user can execute it
  *) exit 0;;
esac
EOF
assert_eq "uses an existing usable interpreter" "/usr/bin/python3.12" "$(ensure_openwebui_python 2>/dev/null)"
mock_script pct <<'EOF'
shift 2; [ "$1" = "--" ] && shift
case "$1" in
  bash) case "$*" in
          *"command -v python3.12"*) echo "/root/.local/bin/python3.12"; exit 0;;
          *uv*) exit 0;;
          *) exit 0;;
        esac;;
  runuser) exit 1;;   # service user CANNOT execute the /root one
  *) exit 0;;
esac
EOF
out="$(ensure_openwebui_python 2>&1 >/dev/null)"
assert_contains "rejects an interpreter the service user cannot run" "not executable by the service user" "$out"

# ── privilege / fatal helpers ─────────────────────────────────────────────────
describe require_root
# `id` is stubbed rather than the test being run as a different user.
mock_command id 0 "0"
assert_ok "root passes" bash -c "source '$FUNCS'; require_root"
mock_command id 0 "1000"
assert_fail "non-root is rejected" bash -c "source '$FUNCS'; require_root"
out="$(bash -c "source '$FUNCS'; require_root" 2>&1)"
assert_contains "explains it needs the Proxmox host" "Proxmox host" "$out"
mock_command id 0 "0"

describe die_storage
assert_status "exits 1" 1 bash -c "source '$FUNCS'; die_storage"
assert_contains "names the reason" "storage that fits" \
  "$(bash -c "source '$FUNCS'; die_storage" 2>&1)"

# ── storage prompt ────────────────────────────────────────────────────────────
describe prompt_storage_config
mock_command pvesm 0 "$PVESM_REAL_OUTPUT"
ROOTFS_GB=32; STORAGE="local"
_ps_out="$(mktemp)"
prompt_storage_config > "$_ps_out" 2>&1 <<< $'\n' || true
assert_eq   "keeps the default size on empty input" "32" "$ROOTFS_GB"
assert_ne   "picks a storage with room"             ""   "$STORAGE"
ROOTFS_GB=32; STORAGE="local"
prompt_storage_config > "$_ps_out" 2>&1 <<< $'64\n' || true
assert_eq   "takes the typed size" "64" "$ROOTFS_GB"
# 64 GiB does not fit in `local` (8.3 GiB free) — it must move elsewhere.
assert_ne   "will not choose a storage that is too small" "local" "$STORAGE"
# Nothing has room at all -> die_storage must fire rather than continue.
mock_command pvesm 0 'Name   Type   Status   Total (KiB)   Used (KiB)   Available (KiB)   %
tiny    dir   active       1048576       524288            524288  50.00%'
ROOTFS_GB=64
assert_fail "aborts when nothing fits" \
  bash -c "source '$FUNCS'; NONINTERACTIVE=true; ROOTFS_GB=64; STORAGE=''; STORAGE_CFG=''; prompt_storage_config"
rm -f "$_ps_out"
mock_command pvesm 0 "$PVESM_REAL_OUTPUT"
ROOTFS_GB=32; STORAGE="local"

# ── gitea credential prompt ───────────────────────────────────────────────────
describe prompt_gitea_credentials
_pg_out="$(mktemp)"
GITEA_SERVER_URL="https://git.example.net"; GITEA_ADMIN_USER="tester"
GITEA_REPO_NAME="ollama-smart-router"; GITEA_DEPLOY_TOKEN=""; CONFIG_SOURCE="gitea"
mock_command curl 0 '{"login":"tester"}'
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\nTOKEN123\n' || true
assert_eq "accepts a verified token"  "TOKEN123" "$GITEA_DEPLOY_TOKEN"
assert_eq "owner comes from the token" "tester"  "$GITEA_OWNER"
assert_eq "config stays version controlled" "gitea" "$CONFIG_SOURCE"
# TLS verification is forced off for the TurnKey appliance's self-signed cert.
assert_eq "forces GITEA_VERIFY_TLS=false" "false" "$GITEA_VERIFY_TLS"

# A token owned by a different account: the real login wins as repo owner.
GITEA_DEPLOY_TOKEN=""; GITEA_ADMIN_USER="tester"
mock_command curl 0 '{"login":"someone-else"}'
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\nTOKEN123\n' || true
assert_eq "owner follows the token, not the typed username" "someone-else" "$GITEA_OWNER"
assert_contains "says whose token it is" "someone-else" "$(cat "$_pg_out")"

# No token at all -> fall back to a local, non-version-controlled config.
GITEA_DEPLOY_TOKEN=""; CONFIG_SOURCE="gitea"
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\n\n' || true
assert_eq "no token falls back to local" "local" "$CONFIG_SOURCE"

# Token rejected three times -> give up, but do not abort the install.
GITEA_DEPLOY_TOKEN=""; CONFIG_SOURCE="gitea"
mock_command curl 22
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\nbad1\nbad2\nbad3\n' || true
assert_eq "gives up after 3 attempts" "local" "$CONFIG_SOURCE"
assert_contains "reports the attempt count" "3" "$(cat "$_pg_out")"
assert_ok "returns 0 so provisioning continues" \
  bash -c "source '$FUNCS'; NONINTERACTIVE=true; GITEA_DEPLOY_TOKEN=''; GITEA_SERVER_URL=https://g.example; \
           GITEA_ADMIN_USER=t; GITEA_REPO_NAME=r; GITEA_VERIFY_TLS=false; GITEA_CURL_OPTS=(); \
           prompt_gitea_credentials"
rm -f "$_pg_out"
GITEA_ADMIN_USER="tester"; GITEA_OWNER="tester"; GITEA_DEPLOY_TOKEN=""

# ── gitea access test ─────────────────────────────────────────────────────────
describe test_gitea_access
GITEA_SERVER_URL="https://git.example.net"; GITEA_OWNER="tester"
GITEA_REPO_NAME="ollama-smart-router"; GITEA_REPO_OWNER=""; GITEA_REPO_PRIVATE=true
assert_ok "no token is a skip, not a failure" test_gitea_access ""

# NOTE on these curl stubs: gitea_probe_user calls curl WITHOUT -X and parses
# bare JSON, while gitea_api calls it WITH -X and appends a `\n<status>` line.
# A stub that answers both the same way makes the probe fail on the trailing
# status digits, so every case below branches on -X first.

# Happy path: auth ok, repo exists.
mock_script curl <<'EOF'
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;      # probe
esac
case "$*" in
  *) echo '{"default_branch":"main"}'; echo 200; exit 0;;
esac
EOF
out="$(test_gitea_access TOKEN 2>&1)"; rc=$?
assert_eq       "succeeds end to end"        "0" "$rc"
assert_contains "reports the authenticated user" "tester" "$out"
assert_contains "reports the resolved repo"       "Configuration repository: tester/ollama-smart-router" "$out"

# http:// remote: warn about the redirect that drops the Authorization header.
GITEA_SERVER_URL="http://git.example.net"
out="$(test_gitea_access TOKEN 2>&1)"
assert_contains "warns about http:// losing the token" "drops the auth token" "$out"
GITEA_SERVER_URL="https://git.example.net"

# Repo missing everywhere (404 + empty search) -> created under the token owner.
mock_script curl <<'EOF'
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;
esac
case "$*" in
  *"user/repos"*) echo '{"full_name":"tester/ollama-smart-router"}'; echo 201; exit 0;;
  *search*)       echo '{"data":[]}'; echo 200; exit 0;;
  *)              echo '{"message":"Not Found"}'; echo 404; exit 0;;
esac
EOF
out="$(test_gitea_access TOKEN 2>&1)" || true
assert_contains "creates the repo when it is missing" "Creating repository" "$out"
assert_contains "and reports the created repo"        "Configuration repository: tester/ollama-smart-router" "$out"

# Repo creation rejected -> non-zero and the HTTP code surfaced.
mock_script curl <<'EOF'
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;
esac
case "$*" in
  *"user/repos"*) echo '{"message":"forbidden"}'; echo 403; exit 0;;
  *search*)       echo '{"data":[]}'; echo 200; exit 0;;
  *)              echo '{"message":"Not Found"}'; echo 404; exit 0;;
esac
EOF
assert_fail "a rejected repo create fails the test" test_gitea_access TOKEN
assert_contains "surfaces the HTTP status" "403" "$(test_gitea_access TOKEN 2>&1)"

# Auth itself fails -> stop before touching the repository at all.
mock_command curl 22
mock_reset_log
assert_fail "an unusable token fails fast" test_gitea_access TOKEN
assert_eq   "no repo API calls are attempted" "0" "$(mock_call_count '-X')"

# ── Gitea deployment history ──────────────────────────────────────────────────
describe init_config_repo_history
CT_ID=910; CONFIG_REPO_DIR="/app/config-repo"
GITEA_SERVER_URL="https://git.example.net"; GITEA_OWNER="tester"
GITEA_REPO_NAME="ollama-smart-router"; GITEA_VERIFY_TLS=false
mock_reset_log; mock_command pct 0
init_config_repo_history "SECRETTOKEN" deployment-910-test >/dev/null 2>&1
calls="$(mock_calls)"
assert_contains "pushes a credential file into the container" "push 910" "$calls"
assert_contains "with 0600 permissions"                       "--perms 0600" "$calls"
assert_contains "sets the configured remote"  "ollama-smart-router.git" "$calls"
assert_contains "initializes git in place"    "init -q"                 "$calls"
# git's default-branch hint goes to STDERR, so `git init >/dev/null` does not
# suppress it and it reads like a warning in the install log.
assert_contains "without git's default-branch hint" "init.defaultBranch=main" "$calls"
assert_contains "uses a deployment branch"    "deployment-910-test"     "$calls"
assert_contains "honours GITEA_VERIFY_TLS"    "http.sslVerify=false"    "$calls"
assert_contains "removes the credential file afterwards" "rm -f /root/.git-credentials" "$calls"
assert_contains "tightens permissions on the generated tree" "chmod -R go-rwx" "$calls"
assert_not_contains "does not clone from Gitea" "git clone" "$calls"
assert_not_contains "does not pull from Gitea"  "git pull"  "$calls"
assert_not_contains "never puts the token on a command line" "SECRETTOKEN" "$calls"

# The credential entry must carry the remote's scheme; git will not match an
# https:// credential against an http:// request.
_cred_seen="$(mktemp)"
mock_script pct <<EOF
if [ "\$1" = "push" ]; then cp "\$3" "${_cred_seen}"; fi
exit 0
EOF
GITEA_SERVER_URL="http://git.example.net"
init_config_repo_history "SECRETTOKEN" deployment-910-test >/dev/null 2>&1
assert_file_contains "credential scheme follows the remote" \
  "http://tester:SECRETTOKEN@git.example.net" "$_cred_seen"
GITEA_SERVER_URL="https://git.example.net"
init_config_repo_history "SECRETTOKEN" deployment-910-test >/dev/null 2>&1
assert_file_contains "https remote gets an https credential" \
  "https://tester:SECRETTOKEN@git.example.net" "$_cred_seen"
rm -f "$_cred_seen"

# ── the generated apply-config.sh ─────────────────────────────────────────────
# Not a function, so the coverage gate does not see it — but it is what runs on
# every deploy, so it gets an integration test against a throwaway tree.
describe apply_config_script
_ac="$(mktemp)"
sed -n "/^cat > \"\${REPO_DIR}\/install\/apply-config.sh\" <<'APPLYEOF'\$/,/^APPLYEOF\$/p" \
  "$SCRIPT" | sed '1d;$d' > "$_ac"
assert_ok "extracts from the installer" bash -c "[[ -s '$_ac' ]]"
assert_ok "parses"                      bash -n "$_ac"

_acroot="$(mktemp -d)"; _acrepo="${_acroot}/repo"
mkdir -p "${_acrepo}"/{env,install} \
         "${_acrepo}"/services/{ollama-router,ollama-monitor,litellm-proxy} \
         "${_acrepo}/.git"
echo "x = 1" > "${_acrepo}/services/ollama-router/router.py"
echo "x = 1" > "${_acrepo}/services/ollama-monitor/monitor.py"
printf 'BACKEND_FAST=http://h:11434\n' > "${_acrepo}/env/router.env"
printf '#!/usr/bin/env bash\necho hi\n' > "${_acrepo}/install/manage-model-servers.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "${_acrepo}/tools-helper.sh"
printf '#!/bin/sh\necho hook\n'         > "${_acrepo}/.git/hook.sh"
chmod 0644 "${_acrepo}/install/manage-model-servers.sh" "${_acrepo}/tools-helper.sh" \
           "${_acrepo}/.git/hook.sh"

mkdir -p "${_acrepo}/services/nginx-tls"
printf 'server { listen 8080 ssl; }\n' > "${_acrepo}/services/nginx-tls/ollama-smart-router.conf"

BIN_DIR="${_acroot}/bin" PROFILE_DIR="${_acroot}/profile.d" LOGROTATE_DIR="${_acroot}/logrotate.d" \
  NGINX_CONF_DIR="${_acroot}/nginx.d" \
  bash "$_ac" "$_acrepo" "${_acroot}/router" "${_acroot}/webui" "${_acroot}/units" \
  > "${_acroot}/out" 2>&1
_acrc=$?
assert_eq "runs clean with the optional files absent" "0" "$_acrc"
assert_contains "warns about what it skipped" "router.ini" "$(cat "${_acroot}/out")"

# Executable bit on every repo script, but never inside .git.
assert_file_mode "install script made executable" "755" "${_acrepo}/install/manage-model-servers.sh"
assert_file_mode "script outside install/ too"    "755" "${_acrepo}/tools-helper.sh"
assert_file_mode "leaves .git alone"              "644" "${_acrepo}/.git/hook.sh"

# The management command is linked FIRST, so a later failure cannot hide it.
assert_ok "symlink created" bash -c "[[ -L '${_acroot}/bin/manage-model-servers' ]]"

# PATH for login shells.
_prof="${_acroot}/profile.d/ollama-router-path.sh"
assert_ok "profile.d snippet written" bash -c "[[ -f '$_prof' ]]"
assert_file_contains "adds the repo root"     "${_acrepo}" "$_prof"
assert_file_contains "adds install/"          "${_acrepo}/install" "$_prof"
assert_file_mode     "sourced, not executed"  "644" "$_prof"
_newpath="$(env -i PATH=/usr/bin:/bin sh -c ". '$_prof'; printf '%s' \"\$PATH\"")"
assert_contains "repo lands on PATH"    "${_acrepo}" "$_newpath"
assert_eq "appended, never prepended — repo cannot shadow system commands" \
  "/usr/bin:/bin" "${_newpath%%:${_acrepo}*}"
# Sourcing repeatedly must not grow PATH without bound.
_twice="$(env -i PATH=/usr/bin:/bin sh -c ". '$_prof'; . '$_prof'; . '$_prof'; printf '%s' \"\$PATH\"")"
assert_eq "idempotent when sourced again" "$_newpath" "$_twice"
_found="$(env -i PATH=/usr/bin:/bin sh -c ". '$_prof'; command -v manage-model-servers.sh")"
assert_eq "scripts resolve by name" "${_acrepo}/install/manage-model-servers.sh" "$_found"

# OS-level guardrail for file logs; the router also rotates decisions.jsonl
# internally, but this catches operator-provided files in the same directory.
_lr="${_acroot}/logrotate.d/ollama-smart-router"
assert_ok "logrotate config written" bash -c "[[ -f '$_lr' ]]"
assert_file_contains "rotates the decision logs" "/var/log/ollama-router/*.jsonl" "$_lr"
assert_file_contains "uses copytruncate for live writers" "copytruncate" "$_lr"

# The TLS front end is installed from the repo like everything else.
assert_ok "nginx site installed" bash -c "[[ -f '${_acroot}/nginx.d/ollama-smart-router.conf' ]]"
assert_file_contains "with the repo's content" "listen 8080 ssl" \
  "${_acroot}/nginx.d/ollama-smart-router.conf"

# copy_secret_env: the env files hold secrets, so in the container they are
# root:ollama-router 0640. Assert the mode rather than trusting the call site.
_env_mode="$(stat -c '%a' "${_acroot}/router/.env")"
assert_ok "the env file is not world-readable" \
  bash -c "[[ '${_env_mode}' == '640' || '${_env_mode}' == '600' ]]"

# Without the service account — a validation run — it must degrade to an
# owner-only copy rather than aborting before the units and nginx site are
# installed. Simulated by making getent report the group as absent.
_acroot2="$(mktemp -d)"
cp -r "${_acrepo}" "${_acroot2}/repo" 2>/dev/null || true
mkdir -p "${_acroot2}/repo/services/ollama-router"
echo "x = 1" > "${_acroot2}/repo/services/ollama-router/router.py"
mock_script getent <<'EOF'
exit 2                      # no such group
EOF
BIN_DIR="${_acroot2}/bin" PROFILE_DIR="${_acroot2}/profile.d" \
  LOGROTATE_DIR="${_acroot2}/logrotate.d" NGINX_CONF_DIR="${_acroot2}/nginx.d" \
  bash "$_ac" "${_acroot2}/repo" "${_acroot2}/router" "${_acroot2}/webui" "${_acroot2}/units" \
  > "${_acroot2}/out" 2>&1
assert_eq "still succeeds without the ollama-router group" "0" "$?"
assert_file_mode "and falls back to an owner-only copy" "600" "${_acroot2}/router/.env"
assert_ok "the units were still installed" \
  bash -c "[[ -f '${_acroot2}/nginx.d/ollama-smart-router.conf' ]]"
# Drop the getent stub again: it is a system lookup other tests rely on.
rm -f "${MOCK_BIN}/getent"
rm -rf "$_acroot2"

# A site naming a certificate that does not exist yet must not be reported as a
# broken proxy config — that is what a fresh install looks like before the cert
# is generated, and an nginx emerg trace there teaches you to ignore the one
# warning that matters.
_acroot3="$(mktemp -d)"; mkdir -p "${_acroot3}/repo/services/nginx-tls" \
  "${_acroot3}/repo/env" "${_acroot3}/repo/services/ollama-router" \
  "${_acroot3}/repo/services/ollama-monitor" "${_acroot3}/repo/install"
echo "x = 1" > "${_acroot3}/repo/services/ollama-router/router.py"
echo "x = 1" > "${_acroot3}/repo/services/ollama-monitor/monitor.py"
printf 'A=1\n' > "${_acroot3}/repo/env/router.env"
printf 'server {\n    ssl_certificate     /nonexistent/server.crt;\n}\n' \
  > "${_acroot3}/repo/services/nginx-tls/ollama-smart-router.conf"
BIN_DIR="${_acroot3}/bin" PROFILE_DIR="${_acroot3}/profile.d" \
  LOGROTATE_DIR="${_acroot3}/logrotate.d" NGINX_CONF_DIR="${_acroot3}/nginx.d" \
  bash "$_ac" "${_acroot3}/repo" "${_acroot3}/router" "${_acroot3}/webui" "${_acroot3}/units" \
  > "${_acroot3}/out" 2>&1
assert_eq "a missing certificate is not fatal" "0" "$?"
assert_contains "and is explained, not dumped as an nginx trace" \
  "does not exist yet" "$(cat "${_acroot3}/out")"
assert_contains "with the fix"  "cert renew" "$(cat "${_acroot3}/out")"
assert_not_contains "no scary rejection message" "rejected the configuration" \
  "$(cat "${_acroot3}/out")"
rm -rf "$_acroot3"

# Turning TLS off leaves the repo with no nginx site, but nginx would still be
# holding 8080 and 8000 — the very ports the applications bind directly in that
# mode. The repo is the source of truth, so the installed site has to go.
_acroot4="$(mktemp -d)"; mkdir -p "${_acroot4}/repo/env" "${_acroot4}/nginx.d" \
  "${_acroot4}/repo/services/ollama-router" "${_acroot4}/repo/services/ollama-monitor" \
  "${_acroot4}/repo/install"
echo "x = 1" > "${_acroot4}/repo/services/ollama-router/router.py"
echo "x = 1" > "${_acroot4}/repo/services/ollama-monitor/monitor.py"
printf 'A=1\n' > "${_acroot4}/repo/env/router.env"
printf 'server { listen 8080 ssl; }\n' > "${_acroot4}/nginx.d/ollama-smart-router.conf"
BIN_DIR="${_acroot4}/bin" PROFILE_DIR="${_acroot4}/profile.d" \
  LOGROTATE_DIR="${_acroot4}/logrotate.d" NGINX_CONF_DIR="${_acroot4}/nginx.d" \
  bash "$_ac" "${_acroot4}/repo" "${_acroot4}/router" "${_acroot4}/webui" "${_acroot4}/units" \
  > "${_acroot4}/out" 2>&1
assert_eq "apply still succeeds" "0" "$?"
assert_ok "the stale site is removed" \
  bash -c "[[ ! -f '${_acroot4}/nginx.d/ollama-smart-router.conf' ]]"
assert_contains "and says why" "no longer in the config repo" "$(cat "${_acroot4}/out")"
rm -rf "$_acroot4"

# A genuinely required file missing must still be fatal.
rm -f "${_acrepo}/services/ollama-router/router.py"
assert_status "a missing required file aborts" 1 \
  env BIN_DIR="${_acroot}/bin" PROFILE_DIR="${_acroot}/profile.d" LOGROTATE_DIR="${_acroot}/logrotate.d" \
      NGINX_CONF_DIR="${_acroot}/nginx.d" \
      bash "$_ac" "$_acrepo" "${_acroot}/router" "${_acroot}/webui" "${_acroot}/units"
rm -rf "$_acroot" "$_ac"

# ── container creation flags ──────────────────────────────────────────────────
# The privilege level is a security-relevant default that lives in exactly one
# place, so pin it rather than trusting a reader to notice a flipped digit.
describe container_create_flags
_cargs="$(grep -A 20 '^create_args=(' "$SCRIPT" | sed -n '/^create_args=(/,/^)/p')"
assert_contains "privilege level comes from CT_UNPRIVILEGED" \
  '-unprivileged "$CT_UNPRIVILEGED"' "$_cargs"
assert_contains "defaults to privileged" \
  'CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-0}"' "$(cat "$SCRIPT")"
assert_not_contains "no hardcoded unprivileged flag remains" \
  '-unprivileged 1' "$_cargs"
# A privileged container is not a containment boundary; the installer has to
# say so out loud rather than leaving it to the docs.
assert_contains "the operator is told at creation time" \
  "not a security" "$(cat "$SCRIPT")"

# Nesting is what lets systemd's per-unit sandboxing build its own mount
# namespaces inside the container, and every generated unit relies on those.
assert_contains "features default to nesting" \
  'CT_FEATURES="${CT_FEATURES:-nesting=1}"' "$(cat "$SCRIPT")"
assert_contains "features reach pct create" \
  'create_args+=(-features "$CT_FEATURES")' "$(cat "$SCRIPT")"
# An empty CT_FEATURES must omit the flag rather than pass an empty value,
# which pct rejects.
assert_contains "an empty value omits the flag" \
  '[[ -n "$CT_FEATURES" ]] && create_args+=' "$(cat "$SCRIPT")"

# ── the embedded copy of manage-model-servers.sh ──────────────────────────────
# The installer carries a COMPLETE copy of manage-model-servers.sh inside a
# heredoc, and that copy — not the file next to it — is what apply-config.sh
# symlinks onto PATH in the container. The two have drifted before, so pin the
# invariant rather than trusting that both get edited together.
describe embedded_manage_script
_emb="$(mktemp)"
sed -n "/^cat > \"\${REPO_DIR}\/install\/manage-model-servers.sh\" <<'MANAGEEOF'\$/,/^MANAGEEOF\$/p" \
  "$SCRIPT" | sed '1d;$d' > "$_emb"
assert_ok "extracts from the installer" bash -c "[[ -s '$_emb' ]]"
assert_ok "parses"                      bash -n "$_emb"
_standalone="${HERE}/../manage-model-servers.sh"
if [[ -f "$_standalone" ]]; then
  assert_ok "byte-identical to the standalone script" diff -q "$_emb" "$_standalone"
else
  skip "byte-identical to the standalone script" "no standalone copy alongside"
fi
rm -f "$_emb"

# ── TLS ───────────────────────────────────────────────────────────────────────
# Open WebUI cannot terminate TLS itself — `open-webui serve` passes only host
# and port to uvicorn — so nginx fronts it. What is testable here is the
# certificate: a self-signed cert with the wrong SANs is rejected by every
# current browser, and CN has not been accepted as an identity since Chrome 58.
TLS_DIR=/app/tls
TLS_CERT_DAYS=3650
TLS_KEY_BITS=2048
TLS_EXTRA_SAN=""

describe tls_san_list
assert_eq "ip and hostname, plus loopback" \
  "DNS:osr,DNS:localhost,IP:192.168.11.80,IP:127.0.0.1" \
  "$(tls_san_list 192.168.11.80 osr '')"
# An extra name may be a DNS name or an address; it has to be sorted by shape,
# because an IP written as DNS: silently fails to match when a client connects.
assert_eq "extra names are classified by shape" \
  "DNS:osr,DNS:localhost,DNS:chat.example.com,IP:192.168.11.80,IP:127.0.0.1,IP:10.0.0.5" \
  "$(tls_san_list 192.168.11.80 osr 'chat.example.com,10.0.0.5')"
assert_eq "whitespace around entries is ignored" \
  "DNS:osr,DNS:localhost,DNS:a.lan,IP:192.168.11.80,IP:127.0.0.1" \
  "$(tls_san_list 192.168.11.80 osr '  a.lan , ')"
# Regression: an earlier version set IFS=, to split the extra list and left it
# set, so the dedup check joined with commas and every duplicate got through.
assert_eq "duplicates are dropped" \
  "DNS:osr,DNS:localhost,DNS:a.lan,IP:192.168.11.80,IP:127.0.0.1" \
  "$(tls_san_list 192.168.11.80 osr 'a.lan,a.lan')"
# Regression: tr leaves no newline after the last field, so a bare read drops
# it — and a single extra name IS the last field, which made TLS_EXTRA_SAN with
# one entry a complete no-op.
assert_eq "a single extra name is not dropped" \
  "DNS:osr,DNS:localhost,DNS:only.example.com,IP:192.168.11.80,IP:127.0.0.1" \
  "$(tls_san_list 192.168.11.80 osr 'only.example.com')"
assert_eq "a trailing comma is harmless" \
  "DNS:osr,DNS:localhost,DNS:a.lan,IP:192.168.11.80,IP:127.0.0.1" \
  "$(tls_san_list 192.168.11.80 osr 'a.lan,')"
assert_eq "a loopback host does not duplicate itself" \
  "DNS:localhost,IP:127.0.0.1" "$(tls_san_list 127.0.0.1 localhost '')"
assert_eq "no ip or host still yields a usable list" \
  "DNS:localhost,IP:127.0.0.1" "$(tls_san_list '' '' '')"
assert_not_contains "never emits an empty entry" "DNS:," "$(tls_san_list '' '' ',,')"

describe generate_tls_cert
# Run openssl for real against a temp dir, so this asserts on a certificate
# rather than on a command line.
_tls="$(mktemp -d)"
TLS_DIR="$_tls"
mock_script pct <<'EOF'
shift 3
"$@"
EOF
assert_ok "generates a certificate" generate_tls_cert 192.168.11.80 osr
assert_ok "certificate written"  bash -c "[[ -s '${_tls}/server.crt' ]]"
assert_ok "private key written"  bash -c "[[ -s '${_tls}/server.key' ]]"
assert_file_mode "the key is not readable by anyone else" "600" "${_tls}/server.key"
assert_file_mode "the certificate is world-readable"      "644" "${_tls}/server.crt"
_san="$(openssl x509 -in "${_tls}/server.crt" -noout -ext subjectAltName 2>/dev/null)"
assert_contains "carries the IP as an IP entry"   "IP Address:192.168.11.80" "$_san"
assert_contains "carries the hostname"            "DNS:osr"                  "$_san"
assert_contains "carries localhost"               "DNS:localhost"            "$_san"
# The key must actually match the certificate, or nginx refuses to start.
assert_eq "key and certificate match" \
  "$(openssl x509 -noout -modulus -in "${_tls}/server.crt" | openssl md5)" \
  "$(openssl rsa  -noout -modulus -in "${_tls}/server.key" 2>/dev/null | openssl md5)"
# A cert without serverAuth is refused by some clients even when trusted.
_ext="$(openssl x509 -in "${_tls}/server.crt" -noout -text)"
assert_contains "is an end-entity certificate" "CA:FALSE"          "$_ext"
assert_contains "is usable as a server cert"   "TLS Web Server Authentication" "$_ext"
assert_ok "is currently valid" openssl x509 -in "${_tls}/server.crt" -noout -checkend 0
TLS_EXTRA_SAN="extra.example.com"
assert_ok "regenerates with an extra name" generate_tls_cert 192.168.11.80 osr
assert_contains "which lands in the certificate" "DNS:extra.example.com" \
  "$(openssl x509 -in "${_tls}/server.crt" -noout -ext subjectAltName)"
TLS_EXTRA_SAN=""
rm -rf "$_tls"
TLS_DIR=/app/tls

describe ct_tls_ok
# The probe must distinguish "listening" from "completing a handshake" — the
# whole reason it exists rather than reusing ct_port_listening.
# Stub pct, NOT bash. ct_tls_ok is `run_ct bash -c "openssl s_client ..."`, so
# putting a stub named `bash` on PATH would also replace the shell every later
# assertion in this file runs its command with.
mock_script pct <<'EOF'
exit 0
EOF
assert_ok "reports a good handshake" ct_tls_ok 8080
mock_script pct <<'EOF'
exit 1
EOF
assert_fail "reports a failed handshake" ct_tls_ok 8080

describe verify_service_executables
mock_reset_log
mock_script pct <<'EOF'
shift 3
case "$1" in
  chmod|runuser) exit 0 ;;
  *) "$@" ;;
esac
EOF
assert_ok "service executables are verified as the service user" verify_service_executables
assert_contains "router venv made traversable" \
  "chmod -R a+rX /app/router/venv /app/openwebui/venv" "$(mock_calls)"
assert_contains "router python executed as the service user" \
  "runuser -u ollama-router -- /app/router/venv/bin/python" "$(mock_calls)"
# A failure here must be legible, because the ERR trap destroys the container
# and takes the evidence with it. Naming the executable is the whole point.
mock_script pct <<'EOF'
shift 3
case "$1" in
  chmod) exit 0 ;;
  runuser) exit 1 ;;              # the service account cannot run it
  *) "$@" ;;
esac
EOF
_vout="$(mktemp)"
verify_service_executables > "$_vout" 2>&1; _vrc=$?
assert_eq       "returns non-zero when the service user cannot execute" "1" "$_vrc"
assert_contains "names the router interpreter" \
  "cannot run /app/router/venv/bin/python" "$(cat "$_vout")"
assert_contains "names the Open WebUI interpreter" \
  "cannot run /app/openwebui/venv/bin/python" "$(cat "$_vout")"
assert_contains "explains the systemd symptom" "203/EXEC" "$(cat "$_vout")"
assert_contains "and the 502 it surfaces as"   "502"      "$(cat "$_vout")"
assert_contains "and the likely cause"         "umask"    "$(cat "$_vout")"
rm -f "$_vout"
mock_script pct <<'EOF'
shift 3
case "$1" in
  chmod|runuser) exit 0 ;;
  *) "$@" ;;
esac
EOF
mock_reset_log
assert_ok "passes again once they are executable" verify_service_executables
assert_contains "open-webui script checked" \
  "runuser -u ollama-router -- test -x /app/openwebui/venv/bin/open-webui" "$(mock_calls)"

# ── Open WebUI first-start handling ───────────────────────────────────────────
# These exist because a clean install came up with a dead UI twice. The unit
# starts fine — Type=simple succeeds the instant the process forks — and then
# Open WebUI dies inside its own first-run migration. The installer has to
# notice that, not just launch it and declare victory.
CT_ID=100
OPENWEBUI_PORT=8080
# The port Open WebUI ITSELF binds. With TLS on these differ — nginx owns the
# public one — and start_openwebui_verified must wait on this one, or it would
# see nginx and declare success before Open WebUI had started.
OPENWEBUI_BIND_PORT=8080

describe ct_port_listening
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:8000 0.0.0.0:*'
EOF
# run_ct shells out through pct; route the inner command to the stubs.
mock_script pct <<'EOF'
shift 3                 # drop: exec <id> --
"$@"
EOF
assert_ok   "finds a listening port"        ct_port_listening 8000
assert_fail "does not find a closed port"   ct_port_listening 8080
# 8000 must not match 18000 or 8000x — the awk anchor is the whole point.
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:18000 0.0.0.0:*'
EOF
assert_fail "does not match a port that merely ends the same" ct_port_listening 8000

describe ct_wait_for_port
mock_command sleep 0                      # no real waiting in a test suite
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:8080 0.0.0.0:*'
EOF
assert_ok "returns as soon as the port is up" ct_wait_for_port 8080 30

# Never listening, unit still trying: times out with 1.
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:9999 0.0.0.0:*'
EOF
mock_script systemctl <<'EOF'
case "$*" in *is-active*) echo activating ;; esac
EOF
assert_status "times out while the unit is still activating" 1 ct_wait_for_port 8080 10 open-webui.service

# Unit gave up: return 2 immediately rather than waiting out the deadline.
mock_script systemctl <<'EOF'
case "$*" in *is-active*) echo failed ;; esac
EOF
assert_status "gives up when the unit does" 2 ct_wait_for_port 8080 600 open-webui.service
assert_status "no unit named means wait the whole deadline" 1 ct_wait_for_port 8080 10

describe openwebui_migration_broken
mock_script journalctl <<'EOF'
echo "sqlalchemy.exc.OperationalError: (sqlite3.OperationalError) duplicate column name: info_json"
EOF
assert_ok "recognises the migration failure" openwebui_migration_broken
mock_script journalctl <<'EOF'
echo "Loading WEBUI_SECRET_KEY from /app/openwebui/.webui_secret_key"
EOF
assert_fail "does not fire on a healthy log" openwebui_migration_broken

describe openwebui_reset_db
_ow="$(mktemp -d)"
mock_script systemctl <<'EOF'
exit 0
EOF
# No database yet: nothing to do, and it must not fail.
mock_script pct <<'EOF'
shift 3
case "$1" in
  test) exit 1 ;;                        # no webui.db
  *)    "$@" ;;
esac
EOF
assert_ok "no database is not an error" openwebui_reset_db

# A database with accounts in it must be refused — this is the guard that stops
# the installer wiping a real deployment if it is ever re-run against one.
mock_script pct <<'EOF'
shift 3
case "$1" in
  test) exit 0 ;;
  */python) echo 3 ;;                    # three accounts
  *)       "$@" ;;
esac
EOF
out="$(openwebui_reset_db 2>&1)"; rc=$?
assert_eq       "refuses to reset a populated database" "1" "$rc"
assert_contains "and says why"  "refusing to reset"     "$out"

mock_script pct <<'EOF'
shift 3
case "$1" in
  test) exit 0 ;;
  */python) echo 0 ;;                    # empty: safe to discard
  *)       "$@" ;;
esac
EOF
out="$(openwebui_reset_db 2>&1)"; rc=$?
assert_eq       "resets an empty database"  "0" "$rc"
assert_contains "keeps a copy"              "broken-" "$out"
rm -rf "$_ow"

describe start_openwebui_verified
mock_command sleep 0
mock_script systemctl <<'EOF'
case "$*" in *is-active*) echo active ;; esac
EOF
# Happy path: the port comes up.
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:8080 0.0.0.0:*'
EOF
mock_script pct <<'EOF'
shift 3
"$@"
EOF
# NOT $(...): start_openwebui_verified sets OPENWEBUI_RESET, and a command
# substitution is a subshell, so the assignment would be discarded and the
# assertion would always see the value it started with.
_owout="$(mktemp)"
OPENWEBUI_RESET=false
start_openwebui_verified > "$_owout" 2>&1; rc=$?
assert_eq       "succeeds when the port comes up" "0" "$rc"
assert_contains "says so"  "listening on 8080"    "$(cat "$_owout")"
assert_eq       "no reset was needed" "false"     "$OPENWEBUI_RESET"

# The real case: first start dies in the migration, reset, second start works.
# The ss stub answers "closed" until the reset has happened.
_flag="$(mktemp -u)"
mock_script ss <<EOF
if [ -e "${_flag}" ]; then echo 'LISTEN 0 2048 0.0.0.0:8080 0.0.0.0:*'
else echo 'LISTEN 0 2048 0.0.0.0:9999 0.0.0.0:*'; fi
EOF
mock_script journalctl <<'EOF'
echo "sqlite3.OperationalError) duplicate column name: info_json"
EOF
mock_script pct <<EOF
shift 3
case "\$1" in
  test)     exit 0 ;;
  */python) echo 0 ;;
  bash)     : > "${_flag}"; exit 0 ;;      # the mv happened -> port opens next
  *)        "\$@" ;;
esac
EOF
OPENWEBUI_RESET=false
start_openwebui_verified > "$_owout" 2>&1; rc=$?
out="$(cat "$_owout")"
assert_eq       "recovers from the migration failure" "0" "$rc"
assert_contains "explains what it did" "Discarding the empty database" "$out"
assert_contains "and confirms the retry" "after the retry" "$out"
assert_eq       "records that it reset" "true" "$OPENWEBUI_RESET"
rm -f "$_flag"

# A port clash must NOT be treated as a migration failure: resetting the
# database would destroy data to fix something entirely unrelated.
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:9999 0.0.0.0:*'
EOF
mock_script journalctl <<'EOF'
echo "ERROR:    [Errno 98] error while attempting to bind on address ('0.0.0.0', 8080): address already in use"
EOF
mock_script pct <<'EOF'
shift 3
"$@"
EOF
OPENWEBUI_RESET=false
start_openwebui_verified > "$_owout" 2>&1; rc=$?
out="$(cat "$_owout")"
assert_eq       "reports failure"                 "1" "$rc"
assert_contains "names the real cause"            "already in use" "$out"
assert_contains "and how to find the holder"      "ss -lntp"       "$out"
assert_eq       "did NOT reset the database"      "false" "$OPENWEBUI_RESET"
assert_not_contains "and did not blame migrations" "Discarding the empty database" "$out"

# Something else entirely: no reset, and a warning rather than a silent success.
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:9999 0.0.0.0:*'
EOF
mock_script journalctl <<'EOF'
echo "ModuleNotFoundError: No module named 'open_webui'"
EOF
mock_script pct <<'EOF'
shift 3
"$@"
EOF
OPENWEBUI_RESET=false
start_openwebui_verified > "$_owout" 2>&1; rc=$?
out="$(cat "$_owout")"
assert_eq       "reports failure"        "1" "$rc"
assert_contains "warns clearly"          "did not come up" "$out"
assert_contains "says the API still works" ":8000" "$out"
assert_eq       "did not touch the database" "false" "$OPENWEBUI_RESET"
rm -f "$_owout"

describe report_services
mock_script systemctl <<'EOF'
case "$*" in
  *is-active*open-webui*) echo failed ;;
  *is-active*)            echo active ;;
esac
EOF
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:8000 0.0.0.0:*'
EOF
mock_script pct <<'EOF'
shift 3
"$@"
EOF
out="$(report_services 2>&1)"; rc=$?
assert_eq       "non-zero when something is down" "1" "$rc"
assert_contains "names every unit"        "litellm-proxy"  "$out"
assert_contains "shows the failed one"    "failed"         "$out"
assert_contains "reports the live port"   "listening on 8000" "$out"
assert_contains "and the dead one"        "NOT listening on 8080" "$out"
mock_script systemctl <<'EOF'
case "$*" in *is-active*) echo active ;; esac
EOF
mock_script ss <<'EOF'
echo 'LISTEN 0 2048 0.0.0.0:8000 0.0.0.0:*'
echo 'LISTEN 0 2048 0.0.0.0:8080 0.0.0.0:*'
EOF
assert_ok "zero when everything is up" report_services
TLS_ENABLED=true
ROUTER_BIND_PORT=8010
OPENWEBUI_BIND_PORT=8088
OPENWEBUI_PORT=8080
mock_script pct <<'EOF'
shift 3
case "$1" in
  ss)
    echo 'LISTEN 0 2048 0.0.0.0:8000 0.0.0.0:*'
    echo 'LISTEN 0 2048 0.0.0.0:8080 0.0.0.0:*'
    echo 'LISTEN 0 2048 127.0.0.1:8010 0.0.0.0:*'
    ;;
  bash) exit 0 ;;
  *) "$@" ;;
esac
EOF
out="$(report_services 2>&1)"; rc=$?
assert_eq       "non-zero when an nginx upstream is down" "1" "$rc"
assert_contains "names the missing upstream" "Open WebUI upstream" "$out"
assert_contains "explains the 502"           "nginx will return 502" "$out"
TLS_ENABLED=false

# ── the generated systemd units ───────────────────────────────────────────────
# Also not functions. These assertions exist because of a real outage: every
# unit used Requires= on its upstream, and Requires= propagates stop/restart.
# A crash-looping litellm-proxy therefore stopped ollama-router, which stopped
# open-webui — nine seconds into its first-ever start, part way through the
# alembic migration. webui.db was left with the new column added but the
# revision unstamped, so every subsequent start failed with
# "duplicate column name: info_json" and the UI never came back.
describe systemd_units
_units="$(mktemp -d)"
for _svc in ollama-router litellm-proxy ollama-monitor open-webui; do
  sed -n "/^cat > \"\${REPO_DIR}\/services\/[a-z-]*\/${_svc}.service\" <<'UNITEOF'\$/,/^UNITEOF\$/p" \
    "$SCRIPT" | sed '1d;$d' > "${_units}/${_svc}.service"
  assert_ok "extracts ${_svc}.service" bash -c "[[ -s '${_units}/${_svc}.service' ]]"
done

# The rule: ordering yes, propagation no.
for _svc in ollama-router ollama-monitor open-webui; do
  assert_not_contains "${_svc} does not use Requires=" \
    "Requires=" "$(grep -v '^#' "${_units}/${_svc}.service")"
done
assert_file_contains "open-webui still ORDERS after the router" \
  "After=network-online.target ollama-router.service" "${_units}/open-webui.service"
assert_file_contains "open-webui wants the router" \
  "Wants=network-online.target ollama-router.service" "${_units}/open-webui.service"
assert_file_contains "the router orders after litellm" \
  "After=network-online.target litellm-proxy.service" "${_units}/ollama-router.service"

# open-webui's serve() has LITERAL defaults (host="0.0.0.0", port=8080) and
# never reads HOST/PORT from the environment. Relying on the env file alone
# left it binding the port nginx owns, so it died with "address already in use"
# and the proxy answered 502 for a port nothing was listening on. The flags are
# the fix, and this assertion is what stops them being "tidied away" later.
assert_file_contains "open-webui is told where to bind on the command line" \
  "serve --host \${HOST} --port \${PORT}" "${_units}/open-webui.service"
assert_file_contains "and the values come from the env file" \
  "EnvironmentFile=/app/openwebui/.env" "${_units}/open-webui.service"

# The long first start must survive: migrations plus an embedding-model download.
assert_file_contains "open-webui keeps a long start timeout" \
  "TimeoutStartSec=600" "${_units}/open-webui.service"
# Every unit runs unprivileged and comes back on its own.
for _svc in ollama-router litellm-proxy ollama-monitor open-webui; do
  assert_file_contains "${_svc} runs as the service account" \
    "User=ollama-router" "${_units}/${_svc}.service"
  assert_file_contains "${_svc} restarts" "Restart=always" "${_units}/${_svc}.service"
done
# The monitor's state directory is what keeps a restart from re-announcing.
assert_file_contains "monitor gets a state directory" \
  "StateDirectory=ollama-monitor" "${_units}/ollama-monitor.service"
# LiteLLM must stay off the network.
assert_file_contains "litellm binds loopback only" \
  "--host 127.0.0.1" "${_units}/litellm-proxy.service"
rm -rf "$_units"

# ── summary ───────────────────────────────────────────────────────────────────
rm -rf "$cfgdir"
summary
