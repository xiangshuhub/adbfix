#!/system/bin/sh
# ADB Fixed Port — boot duties, then hand off to the watchdog.
#
# post-fs-data.sh pins the port properties. This script makes sure adbd is
# actually listening on that port at boot, applies the stay-awake-while-charging
# setting, and launches the watchdog. The loop itself lives in
# adbfix-watchdog.sh and runs detached, so nothing here blocks Magisk's
# late_start stage.
MODDIR=${0%/*}
TAG=adbfix
PORT=5555
MAX_RETRY=5
LOG="$MODDIR/watchdog.log"
WD="$MODDIR/adbfix-watchdog.sh"

# File log is the reliable channel: `log` does not reach logcat from Magisk's
# private mount namespace, so keep the file as the source of truth and treat
# logcat as best-effort.
log_note() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [service] $1" >> "$LOG" 2>/dev/null
  /system/bin/log -t "$TAG" "$1" 2>/dev/null
}

port_up() {
  /system/bin/netstat -tln 2>/dev/null | /system/bin/grep -q ":$PORT "
}

recover_adbd() {
  log_note "port $PORT not listening, restarting adbd"
  /system/bin/stop adbd
  /system/bin/start adbd
}

# Keep the log bounded. This runs once per boot, which is enough for an
# event-only log.
if [ -f "$LOG" ]; then
  sz=$(wc -c < "$LOG" 2>/dev/null)
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  [ "$sz" -gt 262144 ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
fi

# --- 1. wait for boot --------------------------------------------------------
until [ "$(/system/bin/getprop sys.boot_completed)" = "1" ]; do
  /system/bin/sleep 2
done

# --- 2. stay awake while charging (no effect on battery) ---------------------
/system/bin/settings put global stay_on_while_plugged_in 7

# --- 3. make sure the port is up right now -----------------------------------
retry=0
while [ "$retry" -lt "$MAX_RETRY" ]; do
  port_up && break
  recover_adbd
  /system/bin/sleep 3
  retry=$((retry + 1))
done
if port_up; then
  log_note "port $PORT up after boot (retries=$retry)"
else
  log_note "port $PORT still down after $MAX_RETRY attempts at boot"
fi

# --- 4. hand off to the watchdog ---------------------------------------------
if [ ! -f "$WD" ]; then
  log_note "watchdog script missing ($WD), not started"
  exit 0
fi

# Detached: own session (setsid), every std fd redirected. Magisk's late_start
# therefore does not wait on it, and nothing holds a pipe open into a dead
# reader.
/system/bin/setsid /system/bin/sh "$WD" </dev/null >>"$LOG" 2>&1 &

log_note "watchdog launched"
exit 0
