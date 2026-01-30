#!/usr/bin/env bash
set -u  # no -e: finish all checks, report all failures.

# Fixed expected values
EXP_VENDOR_HEX="0x1ed5"
EXP_DEVICE_HEX="0x0610"

log()  { echo "[INFO] $*"; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 -ep <BDF>

Example:
  $0 -ep 18:00.0
EOF
}

normalize_bdf() {
  local bdf="$1"
  if [[ "$bdf" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
    echo "$bdf"
  elif [[ "$bdf" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
    echo "0000:$bdf"
  else
    return 1
  fi
}

norm_hex16() {
  local x="$1"
  x="${x,,}"
  x="${x#0x}"
  printf "0x%04s" "$x" | tr ' ' '0'
}

EP_BDF=""
while (( $# )); do
  case "$1" in
    -ep) shift; EP_BDF="${1:-}"; shift || true ;;
    -h|--help) usage; exit 2 ;;
    *) fail "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

OVERALL_FAIL=0

if [[ -z "${EP_BDF:-}" ]]; then
  fail "Missing -ep <BDF>"
  usage
  echo "pcie id check fail"
  exit 1
fi

if ! command -v lspci >/dev/null 2>&1; then
  fail "Command missing: lspci (install pciutils)"
  OVERALL_FAIL=1
else
  pass "Command exists: lspci"
fi

EP_BDF_NORM=""
if EP_BDF_NORM="$(normalize_bdf "$EP_BDF" 2>/dev/null)"; then
  pass "BDF format OK: input=$EP_BDF normalized=$EP_BDF_NORM"
else
  fail "Invalid BDF format: '$EP_BDF' (expected like 18:00.0 or 0000:18:00.0)"
  echo "pcie id check fail"
  exit 1
fi

DEVPATH="/sys/bus/pci/devices/$EP_BDF_NORM"
if [[ -d "$DEVPATH" ]]; then
  pass "Device present in sysfs: $DEVPATH"
else
  fail "Device NOT present in sysfs: $DEVPATH"
  OVERALL_FAIL=1
fi

log "Expected vendor=$(norm_hex16 "$EXP_VENDOR_HEX") device=$(norm_hex16 "$EXP_DEVICE_HEX")"

if command -v lspci >/dev/null 2>&1; then
  # lspci -n -s <bdf> prints: "18:00.0 0302: 1ed5:0610"
  LINE="$(lspci -n -s "$EP_BDF" 2>/dev/null || true)"
  [[ -n "${LINE:-}" ]] || LINE="$(lspci -n -s "$EP_BDF_NORM" 2>/dev/null || true)"

  if [[ -z "${LINE:-}" ]]; then
    fail "lspci query failed for $EP_BDF (and $EP_BDF_NORM)"
    OVERALL_FAIL=1
  else
    log "lspci: $LINE"
    VD="$(echo "$LINE" | sed -nE 's/.* ([0-9a-fA-F]{4}):([0-9a-fA-F]{4}).*/\1:\2/p' | head -n1)"
    if [[ -z "${VD:-}" ]]; then
      fail "Could not parse vendor/device from lspci output"
      OVERALL_FAIL=1
    else
      GOT_VENDOR="$(norm_hex16 "0x${VD%%:*}")"
      GOT_DEVICE="$(norm_hex16 "0x${VD##*:}")"
      EXP_VENDOR="$(norm_hex16 "$EXP_VENDOR_HEX")"
      EXP_DEVICE="$(norm_hex16 "$EXP_DEVICE_HEX")"

      if [[ "$GOT_VENDOR" == "$EXP_VENDOR" && "$GOT_DEVICE" == "$EXP_DEVICE" ]]; then
        pass "Device ID OK: vendor=$GOT_VENDOR device=$GOT_DEVICE"
      else
        fail "Device ID mismatch: got vendor=$GOT_VENDOR device=$GOT_DEVICE expected vendor=$EXP_VENDOR device=$EXP_DEVICE"
        OVERALL_FAIL=1
      fi
    fi
  fi
fi

if (( OVERALL_FAIL == 0 )); then
  echo "pcie id check pass"
  exit 0
else
  echo "pcie id check fail"
  exit 1
fi
