#!/bin/sh
# Install reviewed local files; never download and execute a moving main branch.
set -eu
umask 022

SOURCE_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
DESTDIR=${DESTDIR:-}
START_SERVICE=1
case "${1:-}" in
    '') ;;
    --no-start) START_SERVICE=0;;
    *) printf 'Usage: sh install.sh [--no-start]\n' >&2; exit 2;;
esac
case "$DESTDIR" in
    '') ;;
    /) printf 'DESTDIR must be an absolute staging directory, not /\n' >&2; exit 1;;
    /*)
        mkdir -p "$DESTDIR"
        DESTDIR=$(CDPATH= cd -P "$DESTDIR" && pwd)
        [ "$DESTDIR" != / ] || { printf 'DESTDIR resolves to the live root\n' >&2; exit 1; }
        START_SERVICE=0
        ;;
    *) printf 'DESTDIR must be absolute\n' >&2; exit 1;;
esac

for source_file in led.sh lib/monitor.sh files/googlewifi-led.init files/googlewifi_led.config files/googlewifi-led.trigger luci/menu.json luci/acl.json luci/monitor.js luci/view.js luci/trigger.js; do
    [ -r "$SOURCE_DIR/$source_file" ] || { printf 'Missing source: %s\n' "$source_file" >&2; exit 1; }
done
for source_file in led.sh lib/monitor.sh files/googlewifi-led.init files/googlewifi-led.trigger; do
    sh -n "$SOURCE_DIR/$source_file"
done

backup_file() {
    [ -e "$1" ] || return 0
    backup="$1-googlewifi-led-install-$(date '+%Y-%m-%d').codex.bak"
    # Preserve the first pre-install copy when installation is repeated today.
    [ -e "$backup" ] || cp -p "$1" "$backup"
}

install_file() {
    source_file="$SOURCE_DIR/$1"
    target_file="$DESTDIR$2"
    target_dir=$(dirname "$target_file")
    mkdir -p "$target_dir"
    backup_file "$target_file"
    temporary_file=$(mktemp "$target_dir/.googlewifi-led.XXXXXX")
    cp "$source_file" "$temporary_file"
    chmod "$3" "$temporary_file"
    mv -f "$temporary_file" "$target_file"
    temporary_file=
}

temporary_file=
trap '[ -z "$temporary_file" ] || rm -f "$temporary_file"' EXIT

if [ -z "$DESTDIR" ]; then
    [ "$(id -u)" = 0 ] || { printf 'Run this installer as root on OpenWrt\n' >&2; exit 1; }
    [ -r /etc/openwrt_release ] && [ -x /sbin/procd ] || {
        printf 'This installer requires OpenWrt with procd\n' >&2; exit 1;
    }
    for color in Red Green Blue; do
        [ -w "/sys/class/leds/LED0_$color/brightness" ] || {
            printf 'Google WiFi RGB LEDs were not found\n' >&2; exit 1;
        }
    done
    missing=
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
    command -v flock >/dev/null 2>&1 || missing="$missing flock"
    [ -s /etc/ssl/certs/ca-certificates.crt ] || missing="$missing ca-bundle"
    if [ -n "$missing" ]; then
        if command -v apk >/dev/null 2>&1; then
            apk update
            apk add $missing
        elif command -v opkg >/dev/null 2>&1; then
            opkg update
            opkg install $missing
        else
            printf 'Neither apk nor opkg is available\n' >&2; exit 1
        fi
    fi
    # Validate existing settings before stopping or replacing a working service.
    (
        . "$SOURCE_DIR/lib/monitor.sh"
        gwl_load_config && gwl_validate_leds
    )
    # Stop only this service and the exact legacy scripts, never proxy cores.
    if [ -x /etc/init.d/googlewifi-led ]; then /etc/init.d/googlewifi-led stop; fi
    for cmdline in /proc/[0-9]*/cmdline; do
        [ -r "$cmdline" ] || continue
        command_line=$(tr '\000' ' ' < "$cmdline" 2>/dev/null) || continue
        case "$command_line" in
            'sh /usr/local/LED/led.sh '*|'/bin/sh /usr/local/LED/led.sh '*|\
            'sh /usr/local/LED/shoe.sh '*|'/bin/sh /usr/local/LED/shoe.sh '*|\
            'sh /usr/local/LED/choe.sh '*|'/bin/sh /usr/local/LED/choe.sh '*)
                legacy_pid=${cmdline#/proc/}; legacy_pid=${legacy_pid%/cmdline}
                kill "$legacy_pid" 2>/dev/null || true
                ;;
        esac
    done
fi

install_file led.sh /usr/libexec/googlewifi-led 755
install_file lib/monitor.sh /usr/share/googlewifi-led/monitor.sh 644
install_file files/googlewifi-led.init /etc/init.d/googlewifi-led 755
install_file files/googlewifi-led.trigger /usr/libexec/led-trigger/googlewifi 644
if [ ! -e "$DESTDIR/etc/config/googlewifi_led" ]; then
    install_file files/googlewifi_led.config /etc/config/googlewifi_led 600
fi

if [ -n "$DESTDIR" ] || [ -d /www/luci-static/resources ]; then
    install_file luci/menu.json /usr/share/luci/menu.d/luci-app-googlewifi-led.json 644
    install_file luci/acl.json /usr/share/rpcd/acl.d/luci-app-googlewifi-led.json 644
    install_file luci/monitor.js /www/luci-static/resources/tools/googlewifi_led.js 644
    install_file luci/view.js /www/luci-static/resources/view/system/googlewifi_led.js 644
    install_file luci/trigger.js /www/luci-static/resources/view/system/led-trigger/googlewifi.js 644
fi

# Remove only the old project's exact boot entry, retaining all other commands.
rc_local="$DESTDIR/etc/rc.local"
legacy_pattern='^[[:space:]]*/usr/local/LED/led\.sh[[:space:]]*&[[:space:]]*$'
if [ -f "$rc_local" ] && grep -Eq "$legacy_pattern" "$rc_local"; then
    backup_file "$rc_local"
    temporary_file=$(mktemp "$(dirname "$rc_local")/.googlewifi-led.XXXXXX")
    cp -p "$rc_local" "$temporary_file"
    sed "\|$legacy_pattern|d" "$rc_local" > "$temporary_file"
    mv -f "$temporary_file" "$rc_local"
    temporary_file=
fi

if [ -z "$DESTDIR" ]; then
    if ! uci -q get system.googlewifi_led >/dev/null; then
        backup_file /etc/config/system
        uci set system.googlewifi_led=led
        uci set system.googlewifi_led.name='Passwall2 monitor (RGB ring)'
        uci set system.googlewifi_led.sysfs=LED0_Blue
        uci set system.googlewifi_led.trigger=googlewifi
        uci commit system
    fi
    /etc/init.d/googlewifi-led enable
    if [ "$START_SERVICE" = 1 ]; then /etc/init.d/googlewifi-led start; fi
    printf 'Installed. Diagnose with: /etc/init.d/googlewifi-led check\n'
    printf 'Status: /usr/libexec/googlewifi-led status\n'
else
    printf 'Staged files in %s; no packages, services, or LEDs were changed\n' "$DESTDIR"
fi
