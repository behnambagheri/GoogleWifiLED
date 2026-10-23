# Google WiFi LED Monitor for Passwall2

Show Passwall2 connectivity on the Google WiFi RGB ring, with settings and live status in LuCI.

Based on [amirhosseinchoghaei/GoogleWifiLED](https://github.com/amirhosseinchoghaei/GoogleWifiLED). This version adds a supervised OpenWrt service, HTTPS checks through the existing SOCKS listener, configurable thresholds, and LuCI integration.

Tested on **Google WiFi (Gale), OpenWrt 25.12.6, Passwall2 26.10.20, and Xray 26.10.21**. Requires the `LED0_Red`, `LED0_Green`, and `LED0_Blue` LEDs.

## Install

Enable Passwall2 and its local **Node Socks Listen Port** first. Run as root on the router:

```sh
wget -O /tmp/googlewifi-led.tar.gz https://github.com/behnambagheri/GoogleWifiLED/archive/refs/heads/main.tar.gz &&
  tar -xzf /tmp/googlewifi-led.tar.gz -C /tmp &&
  cd /tmp/GoogleWifiLED-main &&
  sh install.sh
```

The installer installs missing dependencies (`curl`, `flock`, and CA certificates), preserves settings, backs up replaced files, and enables startup automatically. No reboot is needed. Repeat the same steps to update.

Refresh LuCI after installation:

```sh
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
/etc/init.d/rpcd reload
```

Log out and back in if the new menu is missing. Use `sh install.sh --no-start` to install without starting immediately.

## Use

Open **System → Passwall2 LED Monitor** to view connectivity, run **Check now**, and change settings with **Save & Apply**. **System → LED Configuration → Passwall2 monitor (RGB ring) → Edit** also links to this page.

| LED | Meaning |
| --- | --- |
| Green | HTTPS check succeeded in under 1,200 ms |
| Yellow | HTTPS check succeeded, but was slower |
| Blinking red | Two consecutive checks failed |
| Blinking blue | Starting or waiting for samples |
| Solid blue | Passwall2 is disabled |

Defaults work without configuration: brightness **64/255**, interval **30 seconds**, two failed checks before red, and one successful check to recover. Google and Cloudflare HTTPS 204 endpoints provide fallback. The SOCKS port follows Passwall2 automatically.

The monitor checks the configured destinations through Passwall2; it does not verify every LAN route. Keep the RGB channels assigned to this monitor only.

## Command line

Settings are stored in `/etc/config/googlewifi_led`. For example:

```sh
uci set googlewifi_led.main.brightness='32'
uci commit googlewifi_led
/etc/init.d/googlewifi-led reload
```

```sh
/etc/init.d/googlewifi-led check       # Test connectivity without changing LEDs
/etc/init.d/googlewifi-led probe       # Request a fresh sample
/etc/init.d/googlewifi-led status      # Controller process status
/usr/libexec/googlewifi-led status    # Latest connectivity result
logread -e googlewifi-led
```

To stop and disable automatic startup:

```sh
/etc/init.d/googlewifi-led stop
/etc/init.d/googlewifi-led disable
```

Stopping restores the previous LED settings. Backups sit beside replaced files as `*-googlewifi-led-install-YYYY-MM-DD.codex.bak`.

## Tests

```sh
sh tests/run.sh
node tests/luci.js
```

Tests use simulated LEDs and networking. The service and web controls were also verified on the router, including recovery after reboot.
