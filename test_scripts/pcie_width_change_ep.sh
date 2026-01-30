#!/usr/bin/env bash
set -euo pipefail

# Change PCIe Endpoint (EP) Target Link Width (vendor/extended register @ 0x710)
# and retrain link via parent bridge Secondary Bus Reset.
#
# Usage:
#   sudo ./pcie_width_change_ep.sh -ep af:00.0 -tw x8
#   sudo ./pcie_width_change_ep.sh -ep 0000:af:00.0 -tw x4
#
# Target width encoding written into bits [19:16] at offset 0x710 (dword):
#   x1 -> 0x1 << 16
#   x2 -> 0x3 << 16
#   x4 -> 0x7 << 16
#   x8 -> 0xf << 16

usage() {
  cat >&2 <<'EOF'
Usage: sudo ./pcie_width_change_ep.sh -ep <EP_BDF> -tw <TARGET_WIDTH>

  -ep  EP BDF, e.g. af:00.0 or 0000:af:00.0
  -tw  Target link width: x1|x2|x4|x8

Example:
  sudo ./pcie_width_change_ep.sh -ep af:00.0 -tw x8
EOF
  exit 2
}

EP_IN=""
TW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -ep)
      [[ $# -ge 2 ]] || usage
      EP_IN="$2"
      shift 2
      ;;
    -tw)
      [[ $# -ge 2 ]] || usage
      TW="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$EP_IN" || -z "$TW" ]]; then
  usage
fi

case "$TW" in
  x1) TW_MASK_HEX="00010000" ;; # 0x1 << 16
  x2) TW_MASK_HEX="00030000" ;; # 0x3 << 16
  x4) TW_MASK_HEX="00070000" ;; # 0x7 << 16
  x8) TW_MASK_HEX="000f0000" ;; # 0xf << 16
  *)
    echo "Error: -tw must be one of x1|x2|x4|x8" >&2
    exit 2
    ;;
esac

if [[ "$EP_IN" =~ ^0000: ]]; then
  EP_FULL="$EP_IN"
  EP_SHORT="${EP_IN#0000:}"
else
  EP_FULL="0000:$EP_IN"
  EP_SHORT="$EP_IN"
fi

if [[ ! -e "/sys/bus/pci/devices/$EP_FULL" ]]; then
  echo "Error: EP device not found in sysfs: /sys/bus/pci/devices/$EP_FULL" >&2
  exit 1
fi

# Find parent bridge/root port of the EP
RP_FULL="$(basename "$(readlink -f "/sys/bus/pci/devices/$EP_FULL/../")")"
RP_SHORT="${RP_FULL#0000:}"

echo "EP=$EP_SHORT"
echo "RP(parent)=$RP_SHORT"
echo "TARGET_WIDTH=$TW"
echo

echo "[Before]"
lspci -vv -s "$RP_SHORT" | egrep -i "Express|LnkCap:|LnkSta:|LnkCtl2:" || true
lspci -vv -s "$EP_SHORT" | egrep -i "Express|LnkCap:|LnkSta:|LnkCtl2:" || true
echo

echo "== Set EP Target Link Width (offset 0x710 dword, bits[19:16]) =="

# Read current dword at 0x710
orig=$(setpci -s "$EP_SHORT" 710.l)   # 8 hex digits
orig_u32=$((16#$orig))
mask=$((0x000f0000))
tw_u32=$((16#$TW_MASK_HEX))

new_u32=$(( (orig_u32 & ~mask) | (tw_u32 & mask) ))
new=$(printf "%08x" "$new_u32")

echo "EP[0x710].l: 0x$orig -> 0x$new (set bits[19:16] to match $TW)"
setpci -s "$EP_SHORT" 710.l="$new"
echo

echo "== Pulse Secondary Bus Reset on parent bridge (Bridge Control bit6 @ 0x3e) =="
bctl=$(setpci -s "$RP_SHORT" 3e.b)
echo "RP BridgeCtl(0x3e): 0x$bctl"
setpci -s "$RP_SHORT" 3e.b=$(printf "%02x" $((16#$bctl | 0x40)))
sleep 0.1
setpci -s "$RP_SHORT" 3e.b=$(printf "%02x" $((16#$bctl & ~0x40)))
echo

echo "== Wait for link settle =="
sleep 2
echo

echo "[After reset]"
lspci -vv -s "$RP_SHORT" | egrep -i "LnkSta:|LnkCtl2:" || true
lspci -vv -s "$EP_SHORT" | egrep -i "LnkSta:|LnkCtl2:" || true
echo

# Verify target width field (bits[19:16]) matches requested encoding
after=$(setpci -s "$EP_SHORT" 710.l)
after_u32=$((16#$after))
after_field=$(( (after_u32 & mask) >> 16 ))
want_field=$(( (tw_u32 & mask) >> 16 ))

if [[ "$after_field" -eq "$want_field" ]]; then
  echo "Target Link Width Update: $TW success"
else
  echo "Target Link Width Update: $TW fail"
  echo "  Observed EP[0x710].l=0x$after (bits[19:16]=0x$(printf "%x" "$after_field"))" >&2
  exit 1
fi
