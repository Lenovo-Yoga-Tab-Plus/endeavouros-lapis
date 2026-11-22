#!/bin/bash
# Re-apply the binaries and the ath12k layout after pacman replaces them.
set -euo pipefail
install -m 755 /usr/lib/lapis/hexagonrpcd /usr/bin/hexagonrpcd
install -m 755 /usr/lib/lapis/qrtr-ns /usr/bin/qrtr-ns
/usr/lib/lapis/stage-ath12k.sh
