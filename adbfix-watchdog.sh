#!/system/bin/sh
# adbfix watchdog — keep adbd listening on TCP 5555.
#
# Launched detached by service.sh. Single instance is enforced with a pidfile,
# which is portable across both shells on this device. (An earlier version used
# `exec 9>file` + `flock -n 9`; mksh silently ignores high-fd redirections, so
# the lock failed with "Bad file descriptor" and the loop never started when the
# script was run by anything other than busybox ash.)
#
# Scope: repairs the *port* only. It never writes service/persist.adb.tcp.port,
# so the module will not fight a deliberate manual change; it only ever
# restarts adbd so it re-binds the port that is already configured.
MODDIR=${0%/*}
TAG=adbfix
PORT=5555
INTERVAL=60
MAX_RETRY=5
PIDFILE="$MODDIR/watchdog.pid"
LOG="$MODDIR/watchdog.log"

log_note() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $1" >> "$LOG" 2>/dev/null
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

# --- single instance ---------------------------------------------------------
# A pidfile alone is NOT enough. PIDs are reused: after a reboot the pid recorded
# at the previous boot almost certainly belongs to some unrelated process, so a
# bare `kill -0` succeeds and the fresh watchdog concludes it is already running
# and exits -- leaving no watchdog at all, silently. Verify the identity of the
# process too, by checking that its cmdline is this script.
same_watchdog() {
  _pid="$1"
  [ -n "$_pid" ] || return 1
  case "$_pid" in *[!0-9]*) return 1 ;; esac
  kill -0 "$_pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | /system/bin/grep -q adbfix-watchdog
}

if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  if same_watchdog "$old"; then
    log_note "watchdog already running (pid $old), standing down"
    exit 0
  fi
  log_note "stale pidfile (pid ${old:-empty} is not this watchdog), taking over"
fi
echo $$ > "$PIDFILE"
log_note "watchdog started (pid $$, interval ${INTERVAL}s)"

# --- loop --------------------------------------------------------------------
# sleep does not wake a suspended SoC, so recovery latency is unbounded while
# the device is fully asleep. That is inherent to the conservative
# no-wakelock setting; while charging, stay_on_while_plugged_in keeps the
# device awake and this becomes deterministic.
fails=0
while true; do
  /system/bin/sleep "$INTERVAL"

  if port_up; then
    fails=0
    continue
  fi

  recover_adbd
  /system/bin/sleep 3
  if port_up; then
    fails=0
    log_note "recovered port $PORT"
  else
    fails=$((fails + 1))
    log_note "recovery attempt $fails/$MAX_RETRY failed; port $PORT still down"
    if [ "$fails" -ge "$MAX_RETRY" ]; then
      log_note "backing off 10min after $MAX_RETRY consecutive failures"
      fails=0
      /system/bin/sleep 600
    fi
  fi
done
