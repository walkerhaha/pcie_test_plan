#!/usr/bin/env bash
set -euo pipefail

# Change PCIe Endpoint (EP) Target Link Speed (LnkCtl2) and retrain link
# via parent bridge Secondary Bus Reset.
#
# Usage:
#   sudo ./pcie_speed_change_ep.sh -ep af:00.0 -tg 4
#   sudo ./pcie_speed_change_ep.sh -ep 0000:af:00.0 -tg 5
#
# TARGET GEN CODE:
#   1=Gen1 (2.5GT/s)
#   2=Gen2 (5.0GT/s)
#   3=Gen3 (8.0GT/s)
#   4=Gen4 (16GT/s)
#   5=Gen5 (32GT/s)

usage() {
  cat >&2 <<'EOF'
Usage: sudo ./pcie_speed_change_ep.sh -ep <EP_BDF> -tg <TARGET_GEN_CODE>

  -ep  EP BDF, e.g. af:00.0 or 0000:af:00.0
  -tg  Target Gen code: 1..5

Example:
  sudo ./pcie_speed_change_ep.sh -ep af:00.0 -tg 4
EOF
  exit 2
}

EP_IN=""
TG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -ep)
      [[ $# -ge 2 ]] || usage
      EP_IN="$2"
      shift 2
      ;;
    -tg)
      [[ $# -ge 2 ]] || usage
      TG="$2"
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

if [[ -z "$EP_IN" || -z "$TG" ]]; then
  usage
fi

if [[ ! "$TG" =~ ^[1-5]$ ]]; then
  echo "Error: -tg must be 1..5" >&2
  exit 2
fi

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
echo "TARGET=$TG"
echo

echo "[Before]"
lspci -vv -s "$RP_SHORT" | egrep -i "Express|LnkCap:|LnkSta:|LnkCtl2:" || true
lspci -vv -s "$EP_SHORT" | egrep -i "Express|LnkCap:|LnkSta:|LnkCtl2:" || true
echo

echo "== Set EP Target Link Speed (LnkCtl2) =="
orig=$(setpci -s "$EP_SHORT" CAP_EXP+30.w)
new=$(printf "%04x" $(( (16#$orig & 0xfff0) | (TG & 0xf) )))
echo "EP LnkCtl2: 0x$orig -> 0x$new"
setpci -s "$EP_SHORT" CAP_EXP+30.w="$new"
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

# Verify whether EP LnkCtl2 Target Link Speed matches requested TG
after=$(setpci -s "$EP_SHORT" CAP_EXP+30.w)
after_tg=$((16#$after & 0x000f))

if [[ "$after_tg" -eq "$TG" ]]; then
  echo "Target Link Speed Update: $TG success"
else
  echo "Target Link Speed Update: $TG fail"
  echo "  Observed EP LnkCtl2=0x$after (TargetLinkSpeed field=$after_tg)" >&2
  exit 1
fi
