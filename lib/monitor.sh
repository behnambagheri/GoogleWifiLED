#!/bin/sh
# Shared by the foreground controller and the isolated regression tests.

gwl_error() {
    printf 'googlewifi-led: %s\n' "$*" >&2
}

gwl_get() {
    local value
    value=$(uci -q get "googlewifi_led.main.$1" 2>/dev/null) || value=
    printf '%s\n' "${value:-$2}"
}

gwl_uint() {
    local name="$1" value="$2" minimum="$3" maximum="$4"
    case "$value" in ''|*[!0-9]*) gwl_error "$name must be an integer"; return 1;; esac
    [ "${#value}" -le 6 ] || { gwl_error "$name is too large"; return 1; }
    while [ "${value#0}" != "$value" ]; do value=${value#0}; done
    value=${value:-0}
    if [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
        gwl_error "$name must be between $minimum and $maximum"
        return 1
    fi
    printf '%s\n' "$value"
}

gwl_load_config() {
    ENABLED=$(gwl_uint enabled "$(gwl_get enabled 1)" 0 1) || return 1
    SOCKS_PORT=$(gwl_uint socks_port "$(gwl_get socks_port 0)" 0 65535) || return 1
    INTERVAL=$(gwl_uint interval "$(gwl_get interval 30)" 5 3600) || return 1
    CONNECT_TIMEOUT=$(gwl_uint connect_timeout "$(gwl_get connect_timeout 3)" 1 30) || return 1
    REQUEST_TIMEOUT=$(gwl_uint request_timeout "$(gwl_get request_timeout 8)" 1 60) || return 1
    FAILURE_THRESHOLD=$(gwl_uint failure_threshold "$(gwl_get failure_threshold 2)" 1 10) || return 1
    RECOVERY_THRESHOLD=$(gwl_uint recovery_threshold "$(gwl_get recovery_threshold 1)" 1 10) || return 1
    SLOW_MS=$(gwl_uint slow_ms "$(gwl_get slow_ms 1200)" 1 60000) || return 1
    BRIGHTNESS=$(gwl_uint brightness "$(gwl_get brightness 64)" 1 255) || return 1
    CHECK_URLS=$(gwl_get check_url 'https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204')
    local url count=0
    for url in $CHECK_URLS; do
        case "$url" in
            https://?*) ;;
            *) gwl_error 'check_url must use HTTPS'; return 1;;
        esac
        case "$url" in *'@'*) gwl_error 'check_url must not contain credentials'; return 1;; esac
        count=$((count + 1))
    done
    [ "$count" -ge 1 ] && [ "$count" -le 3 ] || {
        gwl_error 'configure between one and three check_url entries'; return 1;
    }
    LED_ROOT=${LED_ROOT:-/sys/class/leds}
    RUNTIME_DIR=${RUNTIME_DIR:-/var/run/googlewifi-led}
    DISPLAY_STATE=starting
    SAMPLE_STATE=starting
    SAMPLE_MS=0
    SAMPLE_CODE=000
    SAMPLE_CURL_EXIT=0
    SAMPLE_REASON=starting
    FAILURES=0
    SUCCESSES=0
    CHILD_PID=
    CHILD_KIND=none
    PROBE_REQUESTED=0
    PROBE_FILE=
    OWNS_LEDS=0
}

gwl_validate_leds() {
    local color path maximum
    local section
    for section in $(uci -q show system 2>/dev/null | sed -n "s/^system\.\([^=]*\)\.sysfs='LED0_\(Red\|Green\|Blue\)'$/\1/p"); do
        if [ "$section" != googlewifi_led ] || [ "$(uci -q get "system.$section.trigger")" != googlewifi ]; then
            gwl_error 'another OpenWrt UCI LED rule already owns the RGB channels'
            return 1
        fi
    done
    for color in Red Green Blue; do
        path="$LED_ROOT/LED0_$color"
        [ -r "$path/max_brightness" ] && [ -w "$path/brightness" ] && [ -w "$path/trigger" ] || {
            gwl_error "missing or inaccessible Google WiFi LED: $path"; return 1;
        }
        read -r maximum < "$path/max_brightness"
        maximum=$(gwl_uint max_brightness "$maximum" 1 65535) || return 1
        [ "$BRIGHTNESS" -le "$maximum" ] || {
            gwl_error "brightness exceeds the $color LED maximum ($maximum)"; return 1;
        }
        grep -qw timer "$path/trigger" || {
            gwl_error "timer trigger is unavailable for $path"; return 1;
        }
    done
}

gwl_milliseconds() {
    local seconds="$1" whole fraction
    case "$seconds" in ''|*[!0-9.]*|*.*.*) return 1;; esac
    whole=${seconds%%.*}
    fraction=${seconds#*.}
    [ "$fraction" != "$seconds" ] || fraction=0
    whole=$(gwl_uint duration "$whole" 0 999999) || return 1
    fraction=$(printf '%.3s' "${fraction}000")
    printf '%s\n' "$((whole * 1000 + 1$fraction - 1000))"
}

gwl_prepare_probe() {
    PROBE_FILE=$(mktemp "${TMPDIR:-/tmp}/googlewifi-led-probe.XXXXXX") || return 1
}

gwl_wake() {
    PROBE_REQUESTED=1
    if [ "$CHILD_KIND" = sleep ] && [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null || true
    fi
}

gwl_wait_probe() {
    local result
    while :; do
        if wait "$CHILD_PID"; then result=0; else result=$?; fi
        # USR1 may interrupt wait; keep waiting for the same probe, not a new one.
        if kill -0 "$CHILD_PID" 2>/dev/null; then continue; fi
        return "$result"
    done
}

gwl_probe() {
    local passwall_enabled port url result=1 seconds endpoint=0
    SAMPLE_STATE=unreachable
    SAMPLE_MS=0
    SAMPLE_CODE=000
    SAMPLE_CURL_EXIT=0
    SAMPLE_REASON=request_failed
    passwall_enabled=$(uci -q get 'passwall2.@global[0].enabled' 2>/dev/null) || passwall_enabled=
    if [ "$ENABLED" = 0 ] || [ "$passwall_enabled" = 0 ]; then
        SAMPLE_STATE=disabled
        SAMPLE_REASON=disabled
        return 0
    fi
    [ "$passwall_enabled" = 1 ] || { SAMPLE_REASON=passwall2_config_missing; return 1; }
    port=$SOCKS_PORT
    if [ "$port" = 0 ]; then
        port=$(uci -q get 'passwall2.@global[0].node_socks_port' 2>/dev/null) || port=
    fi
    port=$(gwl_uint node_socks_port "$port" 1 65535 2>/dev/null) || {
        SAMPLE_REASON=socks_port_missing; return 1;
    }

    for url in $CHECK_URLS; do
        endpoint=$((endpoint + 1))
        # -q ignores .curlrc; explicit proxy and empty no_proxy prevent bypass.
        # Do not follow redirects, disable TLS verification, or start another core.
        CHILD_KIND=probe
        curl -q --silent --output /dev/null --write-out '%{http_code} %{time_starttransfer}\n' \
            --proxy "socks5h://127.0.0.1:$port" --noproxy '' --proto '=https' \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time "$REQUEST_TIMEOUT" \
            "$url" > "$PROBE_FILE" 2>/dev/null &
        CHILD_PID=$!
        if gwl_wait_probe; then result=0; else result=$?; fi
        CHILD_PID=
        CHILD_KIND=none
        SAMPLE_CURL_EXIT=$result
        SAMPLE_CODE=000
        seconds=0
        read -r SAMPLE_CODE seconds < "$PROBE_FILE" || true
        if [ "$result" = 0 ] && [ "$SAMPLE_CODE" = 204 ]; then
            SAMPLE_MS=$(gwl_milliseconds "$seconds") || { SAMPLE_REASON=invalid_timing; continue; }
            SAMPLE_REASON="endpoint_$endpoint"
            SAMPLE_STATE=healthy
            [ "$SAMPLE_MS" -lt "$SLOW_MS" ] || SAMPLE_STATE=slow
            return 0
        fi
        case "$result" in
            0) SAMPLE_REASON=unexpected_http_status;;
            7) SAMPLE_REASON=connection_failed;;
            28) SAMPLE_REASON=request_timeout;;
            35|51|60|77) SAMPLE_REASON=tls_failed;;
            97) SAMPLE_REASON=socks_failed;;
            *) SAMPLE_REASON=request_failed;;
        esac
    done
    return 1
}

gwl_next_state() {
    case "$SAMPLE_STATE" in
        disabled)
            FAILURES=0; SUCCESSES=0; DISPLAY_STATE=disabled
            ;;
        healthy|slow)
            FAILURES=0
            [ "$SUCCESSES" -ge "$RECOVERY_THRESHOLD" ] || SUCCESSES=$((SUCCESSES + 1))
            case "$DISPLAY_STATE" in
                starting|unreachable|disabled)
                    [ "$SUCCESSES" -lt "$RECOVERY_THRESHOLD" ] || DISPLAY_STATE=$SAMPLE_STATE
                    ;;
                *) DISPLAY_STATE=$SAMPLE_STATE;;
            esac
            ;;
        *)
            SUCCESSES=0
            [ "$FAILURES" -ge "$FAILURE_THRESHOLD" ] || FAILURES=$((FAILURES + 1))
            # A disabled display must not stay blue after Passwall2 is enabled.
            [ "$DISPLAY_STATE" != disabled ] || DISPLAY_STATE=starting
            [ "$FAILURES" -lt "$FAILURE_THRESHOLD" ] || DISPLAY_STATE=unreachable
            ;;
    esac
}

gwl_save_leds() {
    local color path trigger brightness delay_on delay_off
    for color in Red Green Blue; do
        # Preserve the original snapshot across a crash and procd respawn.
        [ ! -f "$RUNTIME_DIR/original.$color" ] || continue
        path="$LED_ROOT/LED0_$color"
        trigger=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$path/trigger")
        [ -n "$trigger" ] || trigger=none
        read -r brightness < "$path/brightness"
        delay_on=0; delay_off=0
        if [ "$trigger" = timer ]; then
            read -r delay_on < "$path/delay_on"
            read -r delay_off < "$path/delay_off"
        fi
        printf '%s %s %s %s\n' "$trigger" "$brightness" "$delay_on" "$delay_off" \
            > "$RUNTIME_DIR/original.$color" || return 1
    done
    OWNS_LEDS=1
}

gwl_write_led() {
    # procd preloads libsetlbf: printf can split its value and newline into two
    # writes, and sysfs rejects the second write. BusyBox echo writes one record.
    if ! echo "$2" > "$1"; then
        gwl_error "unable to write LED attribute: $1"
        return 1
    fi
}

gwl_restore_leds() {
    local color path trigger brightness delay_on delay_off
    [ "$OWNS_LEDS" = 1 ] || return 0
    for color in Red Green Blue; do
        path="$LED_ROOT/LED0_$color"
        read -r trigger brightness delay_on delay_off < "$RUNTIME_DIR/original.$color" || continue
        gwl_write_led "$path/trigger" none
        gwl_write_led "$path/brightness" "$brightness"
        gwl_write_led "$path/trigger" "$trigger"
        if [ "$trigger" = timer ]; then
            gwl_write_led "$path/delay_on" "$delay_on"
            gwl_write_led "$path/delay_off" "$delay_off"
        fi
        rm -f "$RUNTIME_DIR/original.$color"
    done
    OWNS_LEDS=0
}

gwl_apply_state() {
    local color path active trigger=none
    for color in Red Green Blue; do
        path="$LED_ROOT/LED0_$color"
        gwl_write_led "$path/trigger" none || return 1
        gwl_write_led "$path/brightness" 0 || return 1
    done
    case "$DISPLAY_STATE" in
        healthy) active=Green;;
        slow) active='Red Green';;
        unreachable) active=Red; trigger=timer;;
        starting) active=Blue; trigger=timer;;
        disabled) active=Blue;;
        *) return 1;;
    esac
    for color in $active; do
        path="$LED_ROOT/LED0_$color"
        gwl_write_led "$path/brightness" "$BRIGHTNESS" || return 1
        if [ "$trigger" = timer ]; then
            gwl_write_led "$path/trigger" timer || return 1
            gwl_write_led "$path/delay_on" 500 || return 1
            gwl_write_led "$path/delay_off" 500 || return 1
        fi
    done
}

gwl_status() {
    printf 'state=%s\nsample=%s\nlatency_ms=%s\nhttp_code=%s\ncurl_exit=%s\nreason=%s\nfailures=%s\n' \
        "$DISPLAY_STATE" "$SAMPLE_STATE" "$SAMPLE_MS" "$SAMPLE_CODE" "$SAMPLE_CURL_EXIT" "$SAMPLE_REASON" "$FAILURES"
    printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

gwl_cleanup() {
    local owned="$OWNS_LEDS"
    trap '' INT TERM USR1
    if [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    gwl_restore_leds
    if [ "$owned" = 1 ]; then
        DISPLAY_STATE=stopped
        gwl_status > "$RUNTIME_DIR/status.new"
        mv "$RUNTIME_DIR/status.new" "$RUNTIME_DIR/status"
    fi
    [ -z "$PROBE_FILE" ] || rm -f "$PROBE_FILE"
}

gwl_run() {
    local previous
    [ "$ENABLED" = 1 ] || return 0
    [ "$(uci -q get 'system.@system[0].leds_off' 2>/dev/null)" != 1 ] || return 0
    command -v flock >/dev/null 2>&1 || { gwl_error 'flock is required'; return 1; }
    gwl_validate_leds || return 1
    umask 077
    mkdir -p "$RUNTIME_DIR" || return 1
    chmod 700 "$RUNTIME_DIR" || return 1
    exec 9> "$RUNTIME_DIR/lock"
    flock -n 9 || { gwl_error 'another controller is already running'; return 1; }
    gwl_prepare_probe || return 1
    trap 'exit 0' INT TERM
    trap gwl_wake USR1
    trap gwl_cleanup EXIT
    gwl_save_leds || return 1
    gwl_apply_state || return 1
    while :; do
        PROBE_REQUESTED=0
        previous=$DISPLAY_STATE
        gwl_probe || true
        gwl_next_state
        if [ "$DISPLAY_STATE" != "$previous" ]; then
            gwl_apply_state || return 1
            logger -t googlewifi-led "state=$DISPLAY_STATE reason=$SAMPLE_REASON latency_ms=$SAMPLE_MS"
        fi
        gwl_status > "$RUNTIME_DIR/status.new"
        mv "$RUNTIME_DIR/status.new" "$RUNTIME_DIR/status"
        if [ "$PROBE_REQUESTED" = 0 ]; then
            sleep "$INTERVAL" &
            CHILD_PID=$!
            CHILD_KIND=sleep
            [ "$PROBE_REQUESTED" = 0 ] || kill "$CHILD_PID" 2>/dev/null || true
            wait "$CHILD_PID" || true
            CHILD_PID=
            CHILD_KIND=none
        fi
    done
}

gwl_main() {
    set -f
    gwl_load_config || return 1
    command -v curl >/dev/null 2>&1 || { gwl_error 'curl is required'; return 1; }
    case "${1:-check}" in
        run) gwl_run;;
        check)
            gwl_validate_leds || return 1
            gwl_prepare_probe || return 1
            trap 'exit 130' INT
            trap 'exit 143' TERM
            trap gwl_cleanup EXIT
            printf 'LEDs: Google WiFi RGB devices available\n'
            printf 'Probe: existing Passwall2 SOCKS listener; LEDs will not be changed\n'
            local result=0
            gwl_probe || result=$?
            DISPLAY_STATE=$SAMPLE_STATE
            gwl_status
            return "$result"
            ;;
        status)
            if [ -r "$RUNTIME_DIR/status" ]; then cat "$RUNTIME_DIR/status";
            else gwl_error 'no daemon status is available'; return 1; fi
            ;;
        *) gwl_error 'usage: googlewifi-led {check|run|status}'; return 2;;
    esac
}
