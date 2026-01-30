#!/usr/bin/env bash
set -u  # no -e: finish all checks, report all failures.

# Expected BAR sizes in bytes
EXP_BAR0_SIZE=$((32 * 1024 * 1024))                    # 32MB
EXP_BAR2_SIZE=$((128 * 1024 * 1024 * 1024))            # 128GB
EXP_BAR4_SIZE=$((8 * 1024 * 1024))                     # 8MB
EXP_ROM_SIZE=$((1 * 1024 * 1024))                      # 1MB

log()  { echo "[INFO] $*"; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; }
warn() { echo "[WARN] $*"; }

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

fmt_bytes() {
  local n="$1"
  local kib=$((1024))
  local mib=$((1024 * 1024))
  local gib=$((1024 * 1024 * 1024))
  local tib=$((1024 * 1024 * 1024 * 1024))
  if (( n >= tib && n % tib == 0 )); then
    echo "$((n / tib))TB"
  elif (( n >= gib && n % gib == 0 )); then
    echo "$((n / gib))GB"
  elif (( n >= mib && n % mib == 0 )); then
    echo "$((n / mib))MB"
  elif (( n >= kib && n % kib == 0 )); then
    echo "$((n / kib))KB"
  else
    echo "${n}B"
  fi
}

# sysfs resource line N (0-based): size=end-start+1
# echoes size, 0 if unassigned, -1 on error
get_size_from_resource_line() {
  local devpath="$1"
  local line_idx="$2"
  local resfile="$devpath/resource"

  [[ -r "$resfile" ]] || { echo 0; return 0; }

  local line
  line="$(awk -v n=$((line_idx + 1)) 'NR==n {print $0}' "$resfile" 2>/dev/null || true)"
  [[ -n "${line:-}" ]] || { echo 0; return 0; }

  local start end flags
  # shellcheck disable=SC2162
  read start end flags <<<"$line" || { echo -1; return 0; }

  if [[ "$start" == "0x0000000000000000" && "$end" == "0x0000000000000000" ]]; then
    echo 0
    return 0
  fi

  local size
  size=$(( end - start + 1 )) || { echo -1; return 0; }
  if (( size < 0 )); then echo -1; else echo "$size"; fi
}

check_size() {
  local name="$1"
  local got="$2"
  local exp="$3"

  if (( got == exp )); then
    pass "$name size OK: got=$(fmt_bytes "$got") ($got) expected=$(fmt_bytes "$exp") ($exp)"
    return 0
  else
    if (( got == 0 )); then
      fail "$name size FAIL: got=UNASSIGNED(0) expected=$(fmt_bytes "$exp") ($exp)"
    else
      fail "$name size FAIL: got=$(fmt_bytes "$got") ($got) expected=$(fmt_bytes "$exp") ($exp)"
    fi
    return 1
  fi
}

# ROM BAR size probe via config space offset 0x30 (Expansion ROM BAR)
# echoes:
#  - size in bytes (>=0)
#  - 0 if mask indicates no ROM implemented / cannot probe
#  - -1 on error
probe_rom_size_setpci() {
  local bdf="$1"

  command -v setpci >/dev/null 2>&1 || { echo -1; return 0; }

  local old mask
  old="$(setpci -s "$bdf" 30.l 2>/dev/null || true)"
  [[ -n "${old:-}" ]] || { echo -1; return 0; }

  # Write all-ones except bit0 (enable). Keep bit0=0 to avoid enabling decode accidentally.
  setpci -s "$bdf" 30.l=fffffffe 2>/dev/null || { echo -1; return 0; }
  mask="$(setpci -s "$bdf" 30.l 2>/dev/null || true)"
  # Restore
  setpci -s "$bdf" 30.l="$old" 2>/dev/null || true

  [[ -n "${mask:-}" ]] || { echo -1; return 0; }

  # Compute size from mask: use address bits [31:11] typically => mask & 0xfffff800
  # size = ~(mask_addr) + 1 (32-bit)
  local mask_addr size
  mask_addr=$(( (mask & 0xFFFFF800) & 0xFFFFFFFF ))
  if (( mask_addr == 0 )); then
    echo 0
    return 0
  fi
  size=$(( ((~mask_addr) + 1) & 0xFFFFFFFF ))
  echo "$size"
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
  echo "pcie bar size check fail"
  exit 1
fi

EP_BDF_NORM=""
if EP_BDF_NORM="$(normalize_bdf "$EP_BDF" 2>/dev/null)"; then
  pass "BDF format OK: input=$EP_BDF normalized=$EP_BDF_NORM"
else
  fail "Invalid BDF format: '$EP_BDF' (expected like 18:00.0 or 0000:18:00.0)"
  echo "pcie bar size check fail"
  exit 1
fi

DEVPATH="/sys/bus/pci/devices/$EP_BDF_NORM"
if [[ -d "$DEVPATH" ]]; then
  pass "Device present in sysfs: $DEVPATH"
else
  fail "Device NOT present in sysfs: $DEVPATH"
  OVERALL_FAIL=1
fi

log "Expected BAR0=$(fmt_bytes "$EXP_BAR0_SIZE") BAR2=$(fmt_bytes "$EXP_BAR2_SIZE") BAR4=$(fmt_bytes "$EXP_BAR4_SIZE") ROM=$(fmt_bytes "$EXP_ROM_SIZE")"

# BAR0/2/4 via sysfs resource
if [[ -d "$DEVPATH" ]]; then
  BAR0_GOT="$(get_size_from_resource_line "$DEVPATH" 0)"
  (( BAR0_GOT == -1 )) && { fail "BAR0 parse error from $DEVPATH/resource"; OVERALL_FAIL=1; } || \
    check_size "BAR0" "$BAR0_GOT" "$EXP_BAR0_SIZE" || OVERALL_FAIL=1

  BAR2_GOT="$(get_size_from_resource_line "$DEVPATH" 2)"
  (( BAR2_GOT == -1 )) && { fail "BAR2 parse error from $DEVPATH/resource"; OVERALL_FAIL=1; } || \
    check_size "BAR2" "$BAR2_GOT" "$EXP_BAR2_SIZE" || OVERALL_FAIL=1

  BAR4_GOT="$(get_size_from_resource_line "$DEVPATH" 4)"
  (( BAR4_GOT == -1 )) && { fail "BAR4 parse error from $DEVPATH/resource"; OVERALL_FAIL=1; } || \
    check_size "BAR4" "$BAR4_GOT" "$EXP_BAR4_SIZE" || OVERALL_FAIL=1

  # ROM: try sysfs first (OS assigned), if 0 then fallback to setpci probe (true size)
  ROM_GOT_SYS="$(get_size_from_resource_line "$DEVPATH" 6)"
  if (( ROM_GOT_SYS == -1 )); then
    fail "ROM parse error from $DEVPATH/resource"
    OVERALL_FAIL=1
  elif (( ROM_GOT_SYS != 0 )); then
    log "ROM size source: sysfs resource"
    check_size "ROM" "$ROM_GOT_SYS" "$EXP_ROM_SIZE" || OVERALL_FAIL=1
  else
    log "ROM size source: sysfs resource shows UNASSIGNED(0); trying setpci probe at config offset 0x30"
    if command -v setpci >/dev/null 2>&1; then
      pass "Command exists: setpci"
      ROM_GOT_PROBE="$(probe_rom_size_setpci "$EP_BDF" 2>/dev/null || echo -1)"
      if (( ROM_GOT_PROBE == -1 )); then
        fail "ROM size probe failed via setpci (need permission/root, or device not responding)"
        OVERALL_FAIL=1
      else
        check_size "ROM" "$ROM_GOT_PROBE" "$EXP_ROM_SIZE" || OVERALL_FAIL=1
      fi
    else
      fail "Command missing: setpci (install pciutils). ROM cannot be probed when sysfs is UNASSIGNED."
      OVERALL_FAIL=1
    fi
  fi
else
  warn "Skipping BAR size checks because device sysfs path is missing."
  OVERALL_FAIL=1
fi

if (( OVERALL_FAIL == 0 )); then
  echo "pcie bar size check pass"
  exit 0
else
  echo "pcie bar size check fail"
  exit 1
fi
