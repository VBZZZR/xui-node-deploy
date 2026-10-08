#!/usr/bin/env bash
set -Eeuo pipefail

TEST_MODE="${1:-full}"
case "$TEST_MODE" in full|--config-only|--regressions) ;; *) echo 'Usage: bash test-xui-node-docker.sh [--config-only|--regressions]' >&2; exit 2 ;; esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d /tmp/xui-node-docker-test.XXXXXX)
export XUI_NODE_DOCKER_LIBRARY_MODE=1
export XUI_DOCKER_TEST_STACK="${TEST_ROOT}/stack"
export XUI_DEPLOY_STATE_DIR="${TEST_ROOT}/state"
export XUI_DEPLOY_XUI_DIR="${XUI_TEST_RELEASE_DIR:-${SCRIPT_DIR}/release-v3.7.0/x-ui}"

# shellcheck source=xui-node-docker.sh
source "${SCRIPT_DIR}/xui-node-docker.sh"

fail_test() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_jq() {
    local expression="$1" file="$2" message="$3"
    jq -e "$expression" "$file" >/dev/null || fail_test "$message"
}

install -d -m 0700 "$STATE_DIR"
jq -n '{
  schema:1,
  domain:"us1.example.com",
  publicIPv4:"203.0.113.10",
  countryCode:"US",
  nodeName:"US1",
  displayName:"🇺🇸 US1",
  mainPanelBase:"https://panel.example.com:42173/example/panel/nodes",
  panelPort:32123,
  panelBasePath:"0123456789abcdef0123456789abcdef",
  adminUsername:"admin_0123456789ab",
  adminPassword:"test-password-not-for-production",
  testEmail:"deploy-test-us1-01234567@local.test",
  inboundId:0,
  registeredNodeId:0
}' > "$STATE_FILE"
chmod 0600 "$STATE_FILE"

# Regression checks need no binaries, Docker daemon, firewall or network.
# Real pin/config validation below remains mandatory for full/config-only modes.
(
    trap - ERR
    LOCAL_API_TOKEN=offline-form-token-01234567890123456789
    is_done() { return 1; }
    mark_done() { printf '%s' "$1" > "${TEST_ROOT}/scan-marked"; }
    curl() {
        local header='' output='' body='' url="${!#}"
        local original_args
        original_args=$(printf '%s\n' "$@")
        [[ "$original_args" != *"$LOCAL_API_TOKEN"* ]] || exit 71
        while (( $# )); do
            case "$1" in
                --header) header="${2#@}"; shift 2 ;;
                --output) output="$2"; shift 2 ;;
                --data-binary) body="${2#@}"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ "$header" == /dev/fd/* ]] || exit 72
        cat "$header" > "${TEST_ROOT}/headers"
        case "$url" in
            */scanRealityTarget)
                grep -Fqx 'Content-Type: application/x-www-form-urlencoded' "${TEST_ROOT}/headers" || exit 73
                python3 - "$body" <<'PY'
import pathlib, sys, urllib.parse
assert urllib.parse.parse_qs(pathlib.Path(sys.argv[1]).read_text()) == {
    'target': ['www.google.com:443'], 'sni': ['www.google.com'],
    'xver': ['0'], 'allowPrivate': ['false']}
PY
                printf '%s' '{"success":true,"obj":{"feasible":true,"tls13":true,"x25519":true,"certValid":true}}' > "$output"
                ;;
            *)
                grep -Fqx 'Content-Type: application/json' "${TEST_ROOT}/headers" || exit 74
                if [[ -n "$body" ]]; then
                    jq -e '.example==true' "$body" >/dev/null || exit 75
                fi
                printf '%s' '{"success":true}' > "$output"
                ;;
        esac
        printf '200'
    }
    scan_reality_target
    [[ "$(cat "${TEST_ROOT}/scan-marked")" == reality-target ]] || fail_test "scan was not marked successful"
    printf '%s' '{"example":true}' > "${TEST_ROOT}/json-body"
    local_api_call "$LOCAL_API_TOKEN" POST /inbounds/add "${TEST_ROOT}/json-body" >/dev/null
    local_api_call "$LOCAL_API_TOKEN" GET /server/status >/dev/null

    die() { exit 41; }
    local_api_call() { printf '%s' '{"success":true,"obj":{"feasible":false,"tls13":true,"x25519":true,"certValid":true}}'; }
    if (scan_reality_target >/dev/null 2>&1); then
        fail_test "infeasible target was accepted"
    else
        [[ "$?" == 41 ]] || fail_test "unexpected scan failure status"
    fi
)

(
    # The visible name follows any country/name; the sync tag stays unchanged.
    for label in '🇺🇸 US1' '🇩🇪 DE2' '🇱🇻 LV1'; do
        cfg_set_string displayName "$label"
        build_inbound_payload "${TEST_ROOT}/remark.json" synthetic-private synthetic-public synthetic-uuid 0123456789abcdef 1893456000000 /test
        jq -e --arg label "$label" '.remark==$label and .tag=="in-443-tcp" and .port==443' "${TEST_ROOT}/remark.json" >/dev/null || fail_test "inbound remark does not follow displayName"
    done
    cfg_set_string displayName '🇺🇸 US1'
)

(
    # The LV1 export masked optional seeds even when empty. Do not silently
    # activate custom Vision seeds or ML-DSA from export placeholders.
    build_inbound_payload "${TEST_ROOT}/lv1-profile.json" synthetic-private synthetic-public synthetic-uuid 0123456789abcdef 1893456000000 /test
    assert_jq '.settings.testseed == [] and (.settings.clients | length == 1) and .settings.clients[0].flow == "xtls-rprx-vision"' "${TEST_ROOT}/lv1-profile.json" "optional seeds or test clients changed"
    assert_jq '.streamSettings.realitySettings | .settings.fingerprint == "firefox" and .maxTimeDiff == 0 and .mldsa65Seed == "" and .settings.mldsa65Verify == "" and (has("minClientVer")|not) and (has("maxClientVer")|not)' "${TEST_ROOT}/lv1-profile.json" "LV1 REALITY profile differs"
    assert_jq '.sniffing.enabled == true and .sniffing.destOverride == ["http","tls","fakedns"]' "${TEST_ROOT}/lv1-profile.json" "LV1 sniffing differs"
    assert_jq '[.. | strings | select(contains("<GENERATE_NEW>"))] | length == 0' "${TEST_ROOT}/lv1-profile.json" "masked export placeholder leaked into payload"
)

(
    SSH_CONNECTION='198.51.100.1 50000 203.0.113.10 2222'
    ss() { printf '%s\n' \
        'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
        'LISTEN 0 128 127.0.0.1:6010 0.0.0.0:* users:(("sshd",pid=2,fd=3))' \
        'LISTEN 0 128 [::1]:6011 [::]:* users:(("sshd",pid=2,fd=4))'; }
    systemctl() { return 0; }
    detected=$(detect_ssh_ports)
    grep -Fxq 2222 <<< "$detected" || fail_test "active SSH port was lost"
    if grep -Eq '^(6010|6011)$' <<< "$detected"; then fail_test "X11 loopback ports treated as public SSH"; fi
)
(
    trap - ERR
    [[ "$(normalize_main_panel_base)" == 'https://panel.example.com:42173/example' ]] || fail_test "panel URL normalization failed"
    for value in 'http://panel.example.com/base' 'https://name:pass@panel.example.com/base' 'https://panel.example.com/base?token=private' 'https://panel.example.com:99999/base'; do
        if printf '%s' "$value" | normalize_panel_url >/dev/null; then fail_test "unsafe panel URL accepted"; fi
    done
    valid_admin_email 'admin+test@example.com' || fail_test "valid email rejected"
    if valid_admin_email 'invalid email'; then fail_test "invalid email accepted"; fi
    ensure_admin_email <<< 'admin@example.com'
    [[ "$(cfg_get '.adminEmail')" == 'admin@example.com' ]] || fail_test "email not persisted"
    ensure_admin_email </dev/null
    ensure_main_panel_base </dev/null
    # Exercise the new prompt and subsequent reuse without real credentials.
    cfg_set_string mainPanelBase ''
    ensure_main_panel_base <<< 'https://panel.example.com:42173/example/panel/nodes/'
    [[ "$(cfg_get '.mainPanelBase')" == 'https://panel.example.com:42173/example' ]] || fail_test "panel URL not persisted"
    ensure_main_panel_base </dev/null
)
printf 'PASS: REALITY form, default JSON, token pipe, inbound names, LV1 profile, SSH/X11 and personal configuration checks.\n'
if [[ "$TEST_MODE" == --regressions ]]; then
    bash -n "${SCRIPT_DIR}/xui-node-docker.sh"
    printf 'SKIP: real Xray/pinned binary and full deployment checks (--regressions).\n'
    exit 0
fi

valid_domain "node.example.com" || fail_test "valid domain rejected"
if valid_domain "not_a_domain"; then
    fail_test "invalid domain accepted"
fi
[[ "$(country_flag US)" == "🇺🇸" ]] || fail_test "country flag conversion failed"
[[ "$(normalize_main_panel_base)" == "https://panel.example.com:42173/example" ]] || fail_test "main URL normalization failed"

[[ -x "$XRAY_BIN" ]] || fail_test "pinned Xray fixture is missing"
if [[ "$TEST_MODE" == full ]]; then
    verify_pinned_binaries || fail_test "release binary hashes or versions differ"
else
    [[ "$(sha256sum "$XRAY_BIN" | awk '{print $1}')" == "$XRAY_BINARY_SHA256" ]] || fail_test "Xray fixture hash differs"
    printf 'SKIP: real x-ui executable validation (--config-only); deployment pin checks remain mandatory.\n'
fi

keys=$($XRAY_BIN x25519)
private_key=$(sed -n 's/^PrivateKey:[[:space:]]*//p' <<< "$keys")
public_key=$(sed -n 's/^Password (PublicKey):[[:space:]]*//p' <<< "$keys")
client_uuid=$($XRAY_BIN uuid)
payload="${TEST_ROOT}/inbound.json"
build_inbound_payload "$payload" "$private_key" "$public_key" "$client_uuid" "0123456789abcdef" "1893456000000" "/0123456789abcdef"

assert_jq '.port == 443 and .protocol == "vless" and .tag == "in-443-tcp"' "$payload" "inbound identity differs"
assert_jq '.remark == "🇺🇸 US1"' "$payload" "inbound display name differs"
assert_jq '.enable==false' "$payload" "inbound must be stored disabled until validation"
assert_jq '.settings.clients | length == 1' "$payload" "expected exactly one client"
assert_jq '.settings.clients[0] | .flow == "xtls-rprx-vision" and .limitIp == 3 and .totalGB == 5368709120 and .enable == true' "$payload" "test client limits differ"
assert_jq '.streamSettings | .network == "tcp" and .security == "reality"' "$payload" "transport differs"
assert_jq '.streamSettings.realitySettings | .target == "www.google.com:443" and (.serverNames == ["www.google.com"])' "$payload" "Google REALITY target differs"
assert_jq '.streamSettings.realitySettings | (has("minClientVer") | not) and (has("maxClientVer") | not)' "$payload" "client version constraints must be absent"
assert_jq '.settings.clients[0].subId | length==32' "$payload" "unique subscription identity missing"

preflight="${TEST_ROOT}/preflight.json"
jq '{
      log:{loglevel:"warning"},
      inbounds:[(. | {listen:"0.0.0.0",port,protocol,settings,streamSettings,tag,sniffing})],
      outbounds:[
        {protocol:"freedom",settings:{},tag:"direct"},
        {protocol:"blackhole",settings:{},tag:"blocked"}
      ]
    }
    | .inbounds[0].streamSettings.realitySettings |= del(.settings)' "$payload" > "$preflight"
"$XRAY_BIN" run -test -config "$preflight" >/dev/null
assert_jq '.inbounds[0].streamSettings.realitySettings | (has("settings") | not)' "$preflight" "server preflight leaked client-side Reality metadata"

bash -n "${SCRIPT_DIR}/xui-node-docker.sh"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${SCRIPT_DIR}/xui-node-docker.sh"
fi

printf 'PASS: payload, declared version pins, URL normalization and actual Xray preflight are valid.\n'
printf 'Temporary test data: %s\n' "$TEST_ROOT"

# Offline API/flow checks. All network and service calls in these cases are
# replaced with shell functions; no listener, VPS, firewall or panel is touched.
trap - ERR
die() { printf 'EXPECTED-STOP: %s\n' "$*" >&2; exit 41; }
cfg_test_email=$(cfg_get '.testEmail')

(
    NODE_API_TOKEN="offline-node-token-012345678901234567890123456789"
    build_node_payload "${TEST_ROOT}/node.json"
    assert_jq '.scheme=="https" and .tlsVerifyMode=="verify" and .allowPrivateAddress==false and .inboundSyncMode=="selected" and .inboundTags==["in-443-tcp"] and .enable==true' "${TEST_ROOT}/node.json" "unsafe node sync payload"
)

(
    # Exercise api_call itself, including its header pipe, without a network.
    curl() {
        local header="" output="" arg
        while (( $# )); do
            arg="$1"; shift
            case "$arg" in
                --header) header="$1"; shift ;;
                --output) output="$1"; shift ;;
            esac
        done
        [[ "$header" == @/dev/fd/* ]] || exit 71
        [[ "$(sed -n '1p' "${header#@}")" == 'Authorization: Bearer offline-api-token-01234567890123456789' ]] || exit 72
        printf '{"success":true,"obj":{}}' > "$output"
        printf '200'
    }
    result=$(api_call 'offline-api-token-01234567890123456789' GET 'https://example.com/api')
    jq -e '.success==true' <<< "$result" >/dev/null || fail_test "API pipe header failed"
    if api_call $'bad-token\r\nInjected: header' GET 'https://example.com/api' >/dev/null 2>&1; then
        fail_test "API accepted newline injection"
    fi
    curl() { return 28; }
    if api_call 'offline-api-token-01234567890123456789' POST 'https://example.com/api' >/dev/null 2>&1; then
        fail_test "API timeout was treated as success"
    fi
    curl() { printf '403'; }
    if api_call 'offline-api-token-01234567890123456789' GET 'https://example.com/api' >/dev/null 2>&1; then
        fail_test "HTTP rejection was treated as success"
    fi
)

(
    LOCAL_API_TOKEN=unused
    local_api_call() { printf '{"success":false,"obj":null}'; }
    if find_existing_inbound >/dev/null; then fail_test "API envelope error treated as empty inbound list"; fi
    local_api_call() { printf '{"success":true,"obj":[]}'; }
    [[ -z "$(find_existing_inbound)" ]] || fail_test "empty inbound list not recognized"
    local_api_call() { printf '{"success":true,"obj":[{"tag":"foreign"}]}'; }
    if find_existing_inbound >/dev/null; then fail_test "unknown inbound accepted"; fi
)

(
    LOCAL_API_TOKEN=unused
    is_done() { return 1; }
    find_existing_inbound() { jq -c '.' "$payload"; }
    refresh_xray_after_validation() { :; }
    verify_actual_xray() { :; }
    local_api_call() {
        case "$2:$3" in
            GET:/clients/get/*)
                printf '{"success":true,"obj":{"client":{"id":27,"uuid":"%s","enable":false,"expiryTime":1,"totalGB":5368709120},"usedTraffic":100}}' "$client_uuid"
                ;;
            POST:/clients/update/*)
                jq -e --arg uuid "$client_uuid" '.id==$uuid and .enable==true and .totalGB==5368709120 and .limitIp==3' "$4" >/dev/null || exit 73
                printf '{"success":true}'
                ;;
            *) exit 74 ;;
        esac
    }
    rearm_test_client_if_needed <<< 'ТЕСТ'
)

(
    LOCAL_API_TOKEN=unused
    local_api_call() { printf '{"success":true,"obj":{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct","settings":{}}]}}'; }
    validate_generated_candidate "$payload" >/dev/null
)

(
    main_api_call() {
        case "$1:$2" in
            GET:/inbounds/list)
                jq -n --arg email "$cfg_test_email" '{success:true,obj:[{id:42,nodeId:7,tag:"n7-in-443-tcp",port:443,protocol:"vless",settings:{clients:[{email:$email,enable:false}]}}]}'
                ;;
            GET:/clients/get/*)
                printf '{"success":true,"obj":{"client":{"enable":false},"inboundIds":[42]}}'
                ;;
            *) exit 75 ;;
        esac
    }
    verify_main_sync 7 >/dev/null
)

if (
    detect_ssh_ports() { printf '443\n'; }
    check_initial_conflicts
) >/dev/null 2>&1; then
    fail_test "SSH on TCP/443 did not stop preflight"
fi

if (
    is_done() { return 1; }
    register_with_main_panel
) >/dev/null 2>&1; then
    fail_test "registration allowed before external test"
fi

if (
    LOCAL_API_TOKEN=unused
    is_done() { [[ "$1" == client-verified ]]; }
    local_api_call() { jq -n --arg email "$cfg_test_email" '{success:true,obj:[{email:$email,enable:true}]}'; }
    ensure_node_sync_token() { exit 76; }
    register_with_main_panel
) >/dev/null 2>&1; then
    fail_test "registration allowed with enabled client"
fi

printf 'PASS: offline API headers/errors, disabled-create, full candidate, UUID rearm, selective-sync and stop gates.\n'

run_registration_fixture() (
    scenario="$1"
    trace="${TEST_ROOT}/registration-${scenario}.trace"
    LOCAL_API_TOKEN=unused
    NODE_API_TOKEN=offline-node-token-012345678901234567890123456789
    is_done() {
        [[ "$1" == client-verified ]] ||
        { [[ "$1" == registration-attempted ]] && [[ "$scenario" == resume || "$scenario" == wrong-identity ]]; }
    }
    mark_done() { printf 'mark:%s\n' "$1" >> "$trace"; }
    cfg_set_number() { printf 'state:%s=%s\n' "$1" "$2" >> "$trace"; }
    ensure_node_sync_token() { :; }
    finalize_local_credentials() { printf 'finalize\n' >> "$trace"; }
    local_api_call() {
        [[ "$2:$3" == GET:/clients/list ]] || exit 80
        jq -n --arg email "$cfg_test_email" --arg uuid "$client_uuid" '{success:true,obj:[{email:$email,uuid:$uuid,subId:"temporary-subscription-identity",enable:false}]}'
    }
    main_api_call() {
        printf '%s %s\n' "$1" "$2" >> "$trace"
        case "$1:$2" in
            GET:/nodes/list)
                if [[ "$scenario" == resume || "$scenario" == wrong-identity ]]; then
                    jq --arg scenario "$scenario" '{success:true,obj:[(.|.id=7|if $scenario=="wrong-identity" then .inboundTags+=["foreign"] else . end)]}' "${TEST_ROOT}/node.json"
                else
                    printf '{"success":true,"obj":[]}'
                fi
                ;;
            GET:/clients/list) printf '{"success":true,"obj":[]}' ;;
            POST:/nodes/test|POST:/nodes/probe/7)
                if [[ "$scenario" == unreachable ]]; then
                    printf '{"success":true,"obj":{"status":"offline","xrayState":"error"}}'
                else
                    printf '{"success":true,"obj":{"status":"online","xrayState":"running","panelVersion":"3.7.0","xrayVersion":"26.7.28"}}'
                fi
                ;;
            POST:/nodes/inbounds)
                printf '{"success":true,"obj":[{"tag":"in-443-tcp","port":443,"protocol":"vless"}]}'
                ;;
            POST:/nodes/add)
                [[ "$scenario" != timeout ]] || return 28
                jq '{success:true,obj:(.|.id=7)}' "${TEST_ROOT}/node.json"
                ;;
            GET:/nodes/get/7) jq '{success:true,obj:(.|.id=7)}' "${TEST_ROOT}/node.json" ;;
            GET:/inbounds/list)
                jq -n --arg email "$cfg_test_email" '{success:true,obj:[{id:42,nodeId:7,tag:"n7-in-443-tcp",port:443,protocol:"vless",settings:{clients:[{email:$email,enable:false}]}}]}'
                ;;
            GET:/clients/get/*) printf '{"success":true,"obj":{"client":{"enable":false},"inboundIds":[42]}}' ;;
            *) exit 81 ;;
        esac
    }
    register_with_main_panel <<< 'offline-main-token-012345678901234567890123456789'
)

run_registration_fixture fresh >/dev/null
[[ "$(grep -c '^POST /nodes/add$' "${TEST_ROOT}/registration-fresh.trace")" == 1 ]] || fail_test "fresh registration did not issue exactly one add"
grep -q '^mark:registered$' "${TEST_ROOT}/registration-fresh.trace" || fail_test "fresh registration not verified"
run_registration_fixture resume >/dev/null
if grep -q '^POST /nodes/add$' "${TEST_ROOT}/registration-resume.trace"; then fail_test "resume created duplicate node"; fi
for scenario in timeout unreachable wrong-identity; do
    if run_registration_fixture "$scenario" >/dev/null 2>&1; then fail_test "registration $scenario was treated as success"; fi
    if grep -q '^mark:registered$' "${TEST_ROOT}/registration-${scenario}.trace"; then fail_test "$scenario falsely marked registered"; fi
done
grep -q '^mark:registration-attempted$' "${TEST_ROOT}/registration-timeout.trace" || fail_test "timeout lost reconciliation marker"
if grep -q '^POST /nodes/add$' "${TEST_ROOT}/registration-unreachable.trace"; then fail_test "offline node was added"; fi
if grep -q '^POST /nodes/add$' "${TEST_ROOT}/registration-wrong-identity.trace"; then fail_test "mismatching duplicate was mutated"; fi
printf 'PASS: fresh registration, uncertain add, duplicate reconciliation, reachability and identity mismatch.\n'


# Docker configuration and rejection tests; no Docker daemon is required.
install -d -m 0700 "$STACK_DIR"
jq -n --arg archive "$XUI_ARCHIVE_SHA256" --arg xui "$XUI_BINARY_SHA256" --arg xray "$XRAY_BINARY_SHA256" \
  '{schema:1,platform:"linux/amd64",image:("ghcr.io/mhsanaei/3x-ui@sha256:"+("a"*64)),
    xuiVersion:"3.7.0",xrayVersion:"26.7.28",archiveSha256:$archive,xuiSha256:$xui,xraySha256:$xray}' > "$IMAGE_LOCK_FILE"
validate_image_lock "$IMAGE_LOCK_FILE" || fail_test "valid immutable image lock rejected"
for bad in \
  '.image="ghcr.io/mhsanaei/3x-ui:latest"' \
  '.image="untrusted.example/xui@sha256:"+("a"*64)' \
  '.xrayVersion="27.0.0"' \
  '.archiveSha256="incorrect"' \
  '.platform="linux/arm64"'; do
    jq "$bad" "$IMAGE_LOCK_FILE" > "$TEST_ROOT/bad-image-lock.json"
    if validate_image_lock "$TEST_ROOT/bad-image-lock.json"; then fail_test "unsafe lock accepted: $bad"; fi
done
(
    # Rendering is isolated; the fixed production log path is handled by a harmless install wrapper.
    install() {
        local arg
        local -a filtered=()
        for arg in "$@"; do
            [[ "$arg" == "$LOG_DIR/xui" ]] || filtered+=("$arg")
        done
        command install "${filtered[@]}"
    }
    compose() { [[ "$1" == config && "$2" == --quiet ]]; }
    generate_runtime_files
)
python3 - "$COMPOSE_FILE" "$STACK_DIR" <<'PY'
import json, pathlib, subprocess, sys
path, stack = map(pathlib.Path, sys.argv[1:])
doc = json.loads(path.read_text())  # JSON is emitted as valid YAML/Compose input.
c = doc["services"]["xui"]
assert c["network_mode"] == "host" and "ports" not in c
assert c["read_only"] and c["cap_drop"] == ["ALL"]
assert c["cap_add"] == ["NET_BIND_SERVICE"]
assert c["pull_policy"] == "never" and "@sha256:" in c["image"]
mounts = {m["target"]: m for m in c["volumes"]}
assert mounts["/app/x-ui"]["read_only"]
assert mounts["/app/bin/xray-linux-amd64"]["read_only"]
assert mounts["/etc/letsencrypt"]["read_only"]
assert mounts["/var/run/fail2ban"]["source"] == "/run/fail2ban"
assert not mounts["/etc/x-ui"]["read_only"]
assert all("docker.sock" not in str(m) for m in c["volumes"])
assert all(not any(word in k.lower() for word in ("password", "token")) for k in c["environment"])
for script in (stack/"runtime").glob("*.sh"):
    subprocess.run(["sh", "-n", str(script)], check=True)
print("PASS: Compose parses; host networking, mounts, capability limits and startup scripts are valid.")
PY
(
    expected_image="sha256:offline-image"
    container_image="$expected_image"
    verify_pinned_binaries() { return 0; }  # Isolate Docker identity rejection from release fixture availability.
    docker_local() {
        case "$1:$2" in
          image:inspect) printf '%s\n' "$expected_image" ;;
          inspect:*)
            jq -n --arg img "$container_image" --arg version "$SCRIPT_VERSION" --arg db "$DB_DIR" --arg release "$XUI_DIR" \
              '[{State:{Running:true},Image:$img,HostConfig:{NetworkMode:"host",Privileged:false,ReadonlyRootfs:true},
                Mounts:[{Destination:"/etc/x-ui",Source:$db,RW:true},{Destination:"/app/x-ui",Source:($release+"/x-ui"),RW:false},{Destination:"/app/bin/xray-linux-amd64",Source:($release+"/bin/xray-linux-amd64"),RW:false}],
                Config:{Labels:{"io.xui-node-docker.managed":$version}}}]' ;;
          exec:*)
            if [[ "${3:-}" == fail2ban-client && "${4:-}" == ping ]]; then
                printf 'Server replied: pong\n'
            fi ;;
          *) exit 77 ;;
        esac
    }
    verify_runtime || fail_test "expected container rejected"
    # A container on a different image must not pass even with the same name.
    container_image="sha256:other"
    if verify_runtime; then fail_test "changed container image accepted"; fi
)
"$XRAY_BIN" run -test -config stdin: < "$preflight" >/dev/null
printf 'PASS: image-lock rejects drift; runtime identity and Xray stdin validation are checked.\n'
