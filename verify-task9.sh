#!/bin/bash
# =============================================================================
# Post-provisioning verification — Task 9
# Run over SSH on the target machine (keelan@192.168.0.45).
#
# Usage:
#   ssh keelan@192.168.0.45 'bash -s' < verify-task9.sh
#   # or copy the file to the target and run:
#   bash verify-task9.sh
#
# Exit code: 0 = all checks passed, 1 = one or more checks failed.
# =============================================================================
set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✅ PASS: $1"; ((PASS++)); }
fail() { echo "  ❌ FAIL: $1"; ((FAIL++)); }
warn() { echo "  ⚠️  WARN: $1"; ((WARN++)); }

echo "============================================================"
echo " Post-provisioning verification — nevua-ketana"
echo " Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo " Kernel: $(uname -r)"
echo " OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
echo "============================================================"
echo ""

# =============================================================================
# Phase A — right after provisioning (llama server still disabled,
#           data not yet restored)
# =============================================================================
echo "═══════════════════════════════════════════════════════════"
echo " Phase A — Post-provisioning (llama server disabled)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# --- bcache-reassemble.service ---
echo "[1] bcache-reassemble.service"
if systemctl is-active --quiet bcache-reassemble.service; then
  pass "bcache-reassemble.service is active"
else
  fail "bcache-reassemble.service is NOT active"
fi

# --- bcache device exists ---
echo ""
echo "[2] bcache device (/dev/bcache*)"
if ls /dev/bcache* >/dev/null 2>&1; then
  BCACHE_DEV=$(ls /dev/bcache* | head -1)
  pass "bcache device exists: $BCACHE_DEV"
else
  BCACHE_DEV=""
  fail "No /dev/bcache* device found"
fi

# --- Mount point ---
if [ -n "$BCACHE_DEV" ]; then
  echo ""
  echo "[3] /var/mnt/cached-storage mount"
  if findmnt /var/mnt/cached-storage >/dev/null 2>&1; then
    pass "/var/mnt/cached-storage is mounted"
  else
    fail "/var/mnt/cached-storage is NOT mounted"
  fi

  echo ""
  echo "[4] bcache cache policy"
  if [ -f "/sys/block/bcache0/bcache/cache_policy" ]; then
    POLICY=$(cat /sys/block/bcache0/bcache/cache_policy)
    if [ "$POLICY" = "writearound" ]; then
      pass "Cache policy is '$POLICY'"
    else
      fail "Cache policy is '$POLICY' (expected 'writearound')"
    fi
  else
    fail "Cannot read cache policy (sysfs path missing)"
  fi

  echo ""
  echo "[5] Mount unit After=bcache-reassemble.service"
  if systemctl cat var-mnt-cached-storage.mount 2>/dev/null | grep -q "After=.*bcache-reassemble.service"; then
    pass "Mount unit has After=bcache-reassemble.service"
  else
    # Also check if the x-systemd.after= is in fstab (which maps to After=)
    if grep -q "x-systemd.after=bcache-reassemble.service" /etc/fstab; then
      pass "fstab has x-systemd.after=bcache-reassemble.service (maps to After=)"
    else
      fail "Mount unit does NOT have After=bcache-reassemble.service"
    fi
  fi
fi

# --- llama-server.service ---
echo ""
echo "[6] llama-server.service status"
LLAMA_ENABLED=$(systemctl is-enabled llama-server.service 2>/dev/null || echo "unknown")
if [ "$LLAMA_ENABLED" = "generated" ]; then
  pass "llama-server.service is 'generated' (quadlet unit without [Install])"
elif [ "$LLAMA_ENABLED" = "disabled" ]; then
  pass "llama-server.service is 'disabled' (quadlet unit without [Install], Ignition no-op)"
else
  fail "llama-server.service enabled status is '$LLAMA_ENABLED' (expected 'generated' or 'disabled')"
fi

# Check no failed container attempts
FAILED_CONTAINERS=$(podman ps -a --filter "name=llama-server" --filter "status=created" --filter "status=exited" --filter "status=dead" --format "{{.Names}}:{{.Status}}" 2>/dev/null | grep -c "llama-server" || true)
if [ "$FAILED_CONTAINERS" -eq 0 ]; then
  pass "No failed llama-server container attempts"
else
  warn "Found $FAILED_CONTAINERS llama-server container(s) in non-running state"
fi

# --- firewall ---
echo ""
echo "[7] llama-server-firewall.service"
if systemctl is-active --quiet llama-server-firewall.service; then
  pass "llama-server-firewall.service is active"
else
  fail "llama-server-firewall.service is NOT active"
fi

echo ""
echo "[8] Firewall port 8001/tcp"
if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "8001/tcp"; then
  pass "Port 8001/tcp is open in firewalld"
else
  fail "Port 8001/tcp is NOT open in firewalld"
fi

# --- WoL ---
echo ""
echo "[9] Wake-on-LAN (enp14s0)"
if [ -d "/sys/class/net/enp14s0" ]; then
  WOL_STATUS=$(sudo ethtool enp14s0 2>/dev/null | grep -i "wake-on" | awk '{print $2}')
  if [ "$WOL_STATUS" = "g" ]; then
    pass "WoL enabled on enp14s0 (Wake-on: g)"
  else
    fail "WoL is '$WOL_STATUS' on enp14s0 (expected 'g')"
  fi
else
  warn "Network interface enp14s0 not found (WoL check skipped)"
fi

# --- Failed units ---
echo ""
echo "[10] Failed systemd units"
FAILED_UNITS=$(systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null | wc -l)
if [ "$FAILED_UNITS" -eq 0 ]; then
  pass "No failed systemd units"
else
  fail "$FAILED_UNITS failed systemd unit(s):"
  systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null
fi

# --- bcache done marker ---
echo ""
echo "[11] setup-bcache.done marker"
if [ -f /var/lib/setup-bcache.done ]; then
  pass "setup-bcache.done marker exists"
else
  warn "setup-bcache.done marker NOT found (bcache setup may not have completed)"
fi

# --- setup-bcache.service should be disabled ---
echo ""
echo "[12] setup-bcache.service disabled"
if systemctl is-enabled setup-bcache.service 2>/dev/null | grep -q "disabled"; then
  pass "setup-bcache.service is disabled (one-shot complete)"
else
  fail "setup-bcache.service is NOT disabled (expected disabled after one-shot)"
fi

# =============================================================================
# Phase B — after restoring models and enabling the server
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Phase B — After restoring models + enabling server"
echo "═══════════════════════════════════════════════════════════"
echo ""

# --- Models restored ---
echo "[13] Models directory"
if [ -d /var/mnt/cached-storage/llama-models ]; then
  MODEL_COUNT=$(find /var/mnt/cached-storage/llama-models -name "*.gguf" 2>/dev/null | wc -l)
  if [ "$MODEL_COUNT" -gt 0 ]; then
    pass "llama-models directory exists with $MODEL_COUNT .gguf files"
  else
    fail "llama-models directory exists but no .gguf files found"
  fi
else
  fail "/var/mnt/cached-storage/llama-models does not exist"
fi

# --- llama-server.service active ---
echo ""
echo "[14] llama-server.service active"
if systemctl is-active --quiet llama-server.service; then
  pass "llama-server.service is active"
else
  fail "llama-server.service is NOT active"
fi

# --- Container logs ---
echo ""
echo "[15] Container logs (last 5 lines)"
if podman logs llama-server 2>&1 | tail -5; then
  if podman logs llama-server 2>&1 | tail -10 | grep -qi "error\|fail\|missing"; then
    warn "Container logs contain error/failure keywords"
  else
    pass "No error/failure keywords in recent logs"
  fi
else
  warn "Could not retrieve container logs"
fi

# --- Health check ---
echo ""
echo "[16] llama.cpp server health"
HEALTH=$(curl -sf localhost:8001/health 2>/dev/null)
if [ -n "$HEALTH" ]; then
  pass "Server responds on localhost:8001/health"
  echo "       Response: $HEALTH"
else
  # Try /v1/models as fallback
  MODELS=$(curl -sf localhost:8001/v1/models 2>/dev/null)
  if [ -n "$MODELS" ]; then
    pass "Server responds on localhost:8001/v1/models"
  else
    fail "Server does NOT respond on localhost:8001"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Summary"
echo "═══════════════════════════════════════════════════════════"
echo "  ✅ Passed: $PASS"
echo "  ❌ Failed: $FAIL"
echo "  ⚠️  Warnings: $WARN"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  Result: ALL CHECKS PASSED ✓"
  exit 0
else
  echo "  Result: $FAIL CHECK(S) FAILED ✗"
  exit 1
fi
