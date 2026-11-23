#!/bin/bash
# Re-apply the ath12k board-file layout after linux-firmware replaces it.
set -euo pipefail
/usr/lib/lapis/stage-ath12k.sh
