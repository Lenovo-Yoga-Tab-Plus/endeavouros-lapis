#!/bin/bash
# Put WCN7850 firmware where the TB520FU device tree asks for it.
#
# The wifi node sets firmware-name = "tb520fu". ath12k then loads amss.bin,
# m3.bin, and regdb.bin from ath12k/WCN7850/hw2.0/tb520fu/, and loads board
# files from the directory above that. The generic board.bin is the one that
# works with upstream WLAN.HMT.1.1 firmware. board-2.bin is moved aside so
# the driver does not prefer it.
#
# Pass the rootfs path when staging an image. With no argument the script
# stages the running system, which is what the pacman hook does.
set -euo pipefail

ROOT="${1:-}"
FW="$ROOT/usr/lib/firmware/ath12k/WCN7850/hw2.0"
BOARD="$ROOT/usr/lib/lapis/ath12k-board.bin"
DEST="$FW/tb520fu"

if [ ! -d "$FW" ]; then
    echo "ath12k firmware directory is missing: $FW" >&2
    exit 1
fi
if [ ! -f "$BOARD" ]; then
    echo "generic ath12k board file is missing: $BOARD" >&2
    exit 1
fi

mkdir -p "$DEST"

copy_firmware() {
    local name="$1"
    local src=""
    if [ -f "$FW/$name" ]; then
        src="$FW/$name"
    elif [ -f "$FW/$name.zst" ]; then
        src="$DEST/$name.decoded"
        zstd -qdc "$FW/$name.zst" > "$src"
    elif [ -f "$FW/$name.xz" ]; then
        src="$DEST/$name.decoded"
        xz -dc "$FW/$name.xz" > "$src"
    else
        echo "missing $FW/$name" >&2
        exit 1
    fi
    install -m 644 "$src" "$DEST/$name"
    if [ "$src" = "$DEST/$name.decoded" ]; then
        rm -f "$src"
    fi
}

copy_firmware amss.bin
copy_firmware m3.bin

regdb_src=""
if [ -f "$FW/board-2.bin" ]; then
    regdb_src="$FW/board-2.bin"
elif [ -f "$FW/board-2.bin.zst" ]; then
    regdb_src="$DEST/board-2.bin.decoded"
    zstd -qdc "$FW/board-2.bin.zst" > "$regdb_src"
elif [ -f "$FW/board-2.bin.xz" ]; then
    regdb_src="$DEST/board-2.bin.decoded"
    xz -dc "$FW/board-2.bin.xz" > "$regdb_src"
else
    echo "missing $FW/board-2.bin" >&2
    exit 1
fi

python3 - "$regdb_src" "$DEST/regdb.bin" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
off = (len(b"QCA-ATH12K-BOARD") + 1 + 3) & ~3
while off + 8 <= len(data):
    iid, ilen = struct.unpack_from("<II", data, off)
    body = data[off + 8:off + 8 + ilen]
    off += 8 + ((ilen + 3) & ~3)
    sub = 0
    while iid == 1 and sub + 8 <= len(body):
        sid, slen = struct.unpack_from("<II", body, sub)
        if sid == 1:
            open(dst, "wb").write(body[sub + 8:sub + 8 + slen])
            raise SystemExit(0)
        sub += 8 + ((slen + 3) & ~3)
sys.exit("no REGDB IE in board-2.bin")
PY
if [ "$regdb_src" = "$DEST/board-2.bin.decoded" ]; then
    rm -f "$regdb_src"
fi
if [ ! -s "$DEST/regdb.bin" ]; then
    echo "regdb.bin is empty" >&2
    exit 1
fi

install -m 644 "$BOARD" "$FW/board.bin"

hide_board() {
    local name="$1"
    if [ -f "$FW/$name" ]; then
        mv -f "$FW/$name" "$FW/$name.upstream-hold"
    fi
}
hide_board board-2.bin
hide_board board-2.bin.zst
hide_board board-2.bin.xz
hide_board board.bin.zst
hide_board board.bin.xz
