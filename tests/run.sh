#!/bin/sh
set -eu

REPO=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/googlewifi-led-tests.XXXXXX")
DAEMON_PID=
trap 'if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; fi; rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/leds" "$TEST_ROOT/run"
export TEST_ROOT
REAL_FLOCK=$(command -v flock || true)
export REAL_FLOCK

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
equal() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

cat > "$TEST_ROOT/bin/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    'passwall2.@global[0].enabled') printf '%s\n' "${MOCK_ENABLED:-1}";;
    'passwall2.@global[0].node_socks_port') printf '%s\n' "${MOCK_PORT:-1070}";;
    'system.@system[0].leds_off') printf '0\n';;
    *) exit 1;;
esac
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/bin/sh
if [ "${MOCK_BLOCK:-0}" = 1 ]; then
    printf '%s\n' "$$" > "$TEST_ROOT/curl.pid"
    exec /bin/sleep 30
fi
printf '%s\n' "$@" >> "$TEST_ROOT/curl.args"
calls=0
[ ! -f "$TEST_ROOT/curl.calls" ] || read -r calls < "$TEST_ROOT/curl.calls"
calls=$((calls + 1))
printf '%s\n' "$calls" > "$TEST_ROOT/curl.calls"
if [ "${MOCK_FALLBACK:-0}" = 1 ] && [ "$calls" = 1 ]; then
    printf '000 0.000000\n'; exit 7
fi
printf '%s %s\n' "${MOCK_CODE:-204}" "${MOCK_SECONDS:-0.123456}"
exit "${MOCK_EXIT:-0}"
MOCK
cat > "$TEST_ROOT/bin/flock" <<'MOCK'
#!/bin/sh
[ "${MOCK_LOCKED:-0}" = 0 ] || exit 1
if [ -n "$REAL_FLOCK" ]; then exec "$REAL_FLOCK" "$@"; fi
exit 0
MOCK
cat > "$TEST_ROOT/bin/logger" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_ROOT/logger.log"
MOCK
cat > "$TEST_ROOT/bin/sleep" <<'MOCK'
#!/bin/sh
printf '%s\n' "$$" > "$TEST_ROOT/sleep.pid"
exec /bin/sleep "$@"
MOCK
chmod +x "$TEST_ROOT/bin/uci" "$TEST_ROOT/bin/curl" "$TEST_ROOT/bin/flock" "$TEST_ROOT/bin/logger" "$TEST_ROOT/bin/sleep"
PATH="$TEST_ROOT/bin:$PATH"
export PATH
. "$REPO/lib/monitor.sh"
LED_ROOT="$TEST_ROOT/leds"
RUNTIME_DIR="$TEST_ROOT/run"
for color in Red Green Blue; do
    mkdir -p "$LED_ROOT/LED0_$color"
    printf '255\n' > "$LED_ROOT/LED0_$color/max_brightness"
    printf '17\n' > "$LED_ROOT/LED0_$color/brightness"
    printf '[none] timer heartbeat\n' > "$LED_ROOT/LED0_$color/trigger"
done

gwl_load_config
gwl_validate_leds
gwl_prepare_probe
PROBE_TO_REMOVE=$PROBE_FILE
equal "$(gwl_milliseconds 0.009999)" 9 'fractional milliseconds'
equal "$(gwl_milliseconds 1.234567)" 1234 'seconds conversion'
equal "$(gwl_milliseconds 10.012345)" 10012 'double-digit seconds'
equal "$(gwl_milliseconds 000010.008999)" 10008 'leading zeros'
if gwl_uint test '-1' 0 255 >/dev/null 2>&1; then fail 'negative setting accepted'; fi
if gwl_uint test '9999999999' 0 255 >/dev/null 2>&1; then fail 'oversized setting accepted'; fi
if gwl_milliseconds '1.2.3' >/dev/null 2>&1; then fail 'invalid timing accepted'; fi
printf 'PASS: configuration and time validation\n'

export http_proxy=http://bad.invalid:9999 https_proxy=http://bad.invalid:9999
export ALL_PROXY=http://bad.invalid:9999 no_proxy='*'
gwl_probe
equal "$SAMPLE_STATE" healthy 'successful SOCKS probe'
equal "$SAMPLE_MS" 123 'probe latency'
grep -Fxq 'socks5h://127.0.0.1:1070' "$TEST_ROOT/curl.args" || fail 'SOCKS proxy not explicit'
grep -Fxq -- '--noproxy' "$TEST_ROOT/curl.args" || fail 'no_proxy bypass not overridden'
grep -Fxq '=https' "$TEST_ROOT/curl.args" || fail 'protocol not restricted'
equal "$(head -n 1 "$TEST_ROOT/curl.args")" -q '.curlrc not disabled'
if grep -Eq '^(-k|--insecure|-L|--location)$' "$TEST_ROOT/curl.args"; then fail 'TLS or redirect safety weakened'; fi
printf 'PASS: SOCKS enforcement and TLS configuration\n'

MOCK_SECONDS=1.200000; export MOCK_SECONDS
gwl_probe
equal "$SAMPLE_STATE" slow 'slow threshold'
MOCK_CODE=200; export MOCK_CODE
if gwl_probe; then fail 'captive portal HTTP 200 accepted'; fi
equal "$SAMPLE_REASON" unexpected_http_status 'HTTP failure reason'
MOCK_CODE=204; MOCK_EXIT=7; export MOCK_CODE MOCK_EXIT
if gwl_probe; then fail 'failed curl with HTTP 204 accepted'; fi
MOCK_EXIT=0; MOCK_SECONDS=0.100000; MOCK_FALLBACK=1
export MOCK_EXIT MOCK_SECONDS MOCK_FALLBACK
rm -f "$TEST_ROOT/curl.calls"
gwl_probe
equal "$SAMPLE_REASON" endpoint_2 'fallback endpoint'
MOCK_FALLBACK=0; MOCK_ENABLED=0; export MOCK_FALLBACK MOCK_ENABLED
rm -f "$TEST_ROOT/curl.calls"
gwl_probe
equal "$SAMPLE_STATE" disabled 'disabled Passwall2'
[ ! -f "$TEST_ROOT/curl.calls" ] || fail 'disabled state made a request'
MOCK_ENABLED=1; MOCK_PORT=0; export MOCK_ENABLED MOCK_PORT
if gwl_probe; then fail 'invalid SOCKS port accepted'; fi
equal "$SAMPLE_REASON" socks_port_missing 'port failure reason'
MOCK_PORT=1070; export MOCK_PORT
printf 'PASS: slow, failed, disabled, fallback, and invalid-port probes\n'

DISPLAY_STATE=healthy; SAMPLE_STATE=unreachable
FAILURES=0; SUCCESSES=0
gwl_next_state
equal "$DISPLAY_STATE" healthy 'one failed sample'
gwl_next_state
equal "$DISPLAY_STATE" unreachable 'two failed samples'
RECOVERY_THRESHOLD=2; SAMPLE_STATE=healthy
gwl_next_state
equal "$DISPLAY_STATE" unreachable 'recovery debounce'
gwl_next_state
equal "$DISPLAY_STATE" healthy 'recovered'
SAMPLE_STATE=disabled; gwl_next_state
equal "$DISPLAY_STATE" disabled 'immediate disabled state'
SAMPLE_STATE=unreachable; gwl_next_state
equal "$DISPLAY_STATE" starting 'enabled but waiting for failure threshold'
printf 'PASS: failure and recovery hysteresis\n'

gwl_save_leds
DISPLAY_STATE=healthy; gwl_apply_state
equal "$(cat "$LED_ROOT/LED0_Green/brightness")" 64 'green brightness'
equal "$(cat "$LED_ROOT/LED0_Red/brightness")" 0 'red off while healthy'
DISPLAY_STATE=slow; gwl_apply_state
equal "$(cat "$LED_ROOT/LED0_Red/brightness")" 64 'yellow red channel'
equal "$(cat "$LED_ROOT/LED0_Green/brightness")" 64 'yellow green channel'
DISPLAY_STATE=unreachable; gwl_apply_state
equal "$(cat "$LED_ROOT/LED0_Red/trigger")" timer 'kernel blinking'
equal "$(cat "$LED_ROOT/LED0_Red/delay_on")" 500 'blink period'
gwl_save_leds
gwl_restore_leds
for color in Red Green Blue; do
    equal "$(cat "$LED_ROOT/LED0_$color/brightness")" 17 'original brightness restored'
    equal "$(cat "$LED_ROOT/LED0_$color/trigger")" none 'original trigger restored'
done
printf 'none [timer] heartbeat\n' > "$LED_ROOT/LED0_Red/trigger"
printf '100\n' > "$LED_ROOT/LED0_Red/delay_on"
printf '900\n' > "$LED_ROOT/LED0_Red/delay_off"
gwl_save_leds
DISPLAY_STATE=healthy; gwl_apply_state
gwl_restore_leds
equal "$(cat "$LED_ROOT/LED0_Red/trigger")" timer 'timer trigger restored'
equal "$(cat "$LED_ROOT/LED0_Red/delay_off")" 900 'timer period restored'
rm -f "$PROBE_TO_REMOVE"
printf 'PASS: LED colors, crash snapshot preservation, and restoration\n'

reset_fake_leds() {
    for color in Red Green Blue; do
        printf '[none] timer heartbeat\n' > "$LED_ROOT/LED0_$color/trigger"
        printf '17\n' > "$LED_ROOT/LED0_$color/brightness"
    done
}

wait_for_file() {
    attempts=0
    while [ ! -s "$1" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 5 ] || fail "timed out waiting for $1"
        /bin/sleep 1
    done
}

reset_fake_leds
daemon_runtime="$TEST_ROOT/daemon"
LED_ROOT="$LED_ROOT" RUNTIME_DIR="$daemon_runtime" sh "$REPO/led.sh" run > "$TEST_ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
wait_for_file "$TEST_ROOT/sleep.pid"
grep -Fxq 'state=healthy' "$daemon_runtime/status" || fail 'daemon did not become healthy'
sleep_pid=$(cat "$TEST_ROOT/sleep.pid")
read -r calls_before < "$TEST_ROOT/curl.calls"
kill -USR1 "$DAEMON_PID"
attempts=0
while :; do
    read -r calls_after < "$TEST_ROOT/curl.calls"
    [ "$calls_after" -le "$calls_before" ] || break
    attempts=$((attempts + 1))
    [ "$attempts" -le 5 ] || fail 'requested probe did not wake the daemon'
    /bin/sleep 1
done
wait_for_file "$TEST_ROOT/sleep.pid"
sleep_pid=$(cat "$TEST_ROOT/sleep.pid")
kill "$DAEMON_PID"
wait "$DAEMON_PID"
DAEMON_PID=
if kill -0 "$sleep_pid" 2>/dev/null; then fail 'sleep child survived shutdown'; fi
grep -Fxq 'state=stopped' "$daemon_runtime/status" || fail 'shutdown status missing'
equal "$(cat "$LED_ROOT/LED0_Green/brightness")" 17 'shutdown restored brightness'
reset_fake_leds
MOCK_LOCKED=1 LED_ROOT="$LED_ROOT" RUNTIME_DIR="$daemon_runtime" sh "$REPO/led.sh" run > "$TEST_ROOT/lock.log" 2>&1 && fail 'contended lock accepted'
equal "$(cat "$LED_ROOT/LED0_Blue/brightness")" 17 'contended controller touched LEDs'
MOCK_BLOCK=1 LED_ROOT="$LED_ROOT" RUNTIME_DIR="$daemon_runtime" sh "$REPO/led.sh" run > "$TEST_ROOT/blocked.log" 2>&1 &
DAEMON_PID=$!
wait_for_file "$TEST_ROOT/curl.pid"
curl_pid=$(cat "$TEST_ROOT/curl.pid")
kill -USR1 "$DAEMON_PID"
/bin/sleep 1
kill -0 "$curl_pid" 2>/dev/null || fail 'check request killed the active probe'
kill -0 "$DAEMON_PID" 2>/dev/null || fail 'check request killed the daemon'
kill "$DAEMON_PID"
wait "$DAEMON_PID"
DAEMON_PID=
if kill -0 "$curl_pid" 2>/dev/null; then fail 'curl child survived shutdown'; fi
equal "$(cat "$LED_ROOT/LED0_Blue/brightness")" 17 'blocked-probe shutdown restored LEDs'
printf 'PASS: daemon shutdown, child cleanup, and lock contention\n'

stage="$TEST_ROOT/stage with spaces"
mkdir -p "$stage/etc/config" "$stage/usr/libexec"
printf '#!/bin/sh\necho unrelated\n/usr/local/LED/led.sh &\nexit 0\n' > "$stage/etc/rc.local"
printf 'existing configuration\n' > "$stage/etc/config/googlewifi_led"
printf 'original controller\n' > "$stage/usr/libexec/googlewifi-led"
DESTDIR="$stage" sh "$REPO/install.sh" >/dev/null
equal "$(cat "$stage/etc/config/googlewifi_led")" 'existing configuration' 'existing config preserved'
grep -Fxq 'echo unrelated' "$stage/etc/rc.local" || fail 'unrelated boot command removed'
if grep -Fq '/usr/local/LED/led.sh &' "$stage/etc/rc.local"; then fail 'legacy boot entry remains'; fi
backup="$stage/usr/libexec/googlewifi-led-googlewifi-led-install-$(date '+%Y-%m-%d').codex.bak"
equal "$(cat "$backup")" 'original controller' 'pre-install backup'
DESTDIR="$stage" sh "$REPO/install.sh" >/dev/null
equal "$(cat "$backup")" 'original controller' 'backup overwritten on reinstall'
[ -x "$stage/etc/init.d/googlewifi-led" ] || fail 'init script missing'
[ -f "$stage/www/luci-static/resources/view/system/googlewifi_led.js" ] || fail 'LuCI view missing'
[ -f "$stage/www/luci-static/resources/view/system/led-trigger/googlewifi.js" ] || fail 'native LED integration missing'
clean_stage="$TEST_ROOT/clean-stage"
DESTDIR="$clean_stage" sh "$REPO/install.sh" >/dev/null
cmp "$REPO/files/googlewifi_led.config" "$clean_stage/etc/config/googlewifi_led" || fail 'default config differs'
if DESTDIR=/ sh "$REPO/install.sh" >/dev/null 2>&1; then fail 'unsafe staging root accepted'; fi
if DESTDIR=/tmp/.. sh "$REPO/install.sh" >/dev/null 2>&1; then fail 'root alias accepted'; fi
printf 'PASS: installer backups, migration, config preservation, and idempotency\n'
printf 'All regression checks passed.\n'
