#!/bin/sh
# Run from a checkout or from /usr/libexec/googlewifi-led.
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
if [ -r "$SCRIPT_DIR/lib/monitor.sh" ]; then
    . "$SCRIPT_DIR/lib/monitor.sh"
else
    . /usr/share/googlewifi-led/monitor.sh || exit 1
fi
gwl_main "$@"
