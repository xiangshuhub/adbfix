# ADB Fixed Port

A Magisk module that keeps `adbd` listening on TCP port **5555** across reboots — for
devices you drive over WiFi with no USB cable attached.

Normally, wireless ADB needs a USB connection to bootstrap: you plug in, run
`adb tcpip 5555`, and unplug. That setting lives in `service.adb.tcp.port`, which does
**not** survive a reboot, so you have to repeat the whole dance every time. This module
makes the port permanent and keeps it alive.

## What it does

| | |
|---|---|
| **Pins the port** | `post-fs-data.sh` sets `service.adb.tcp.port` and `persist.adb.tcp.port` to 5555, so `adbd` binds the port from boot. |
| **Verifies at boot** | `service.sh` waits for `sys.boot_completed`, then checks the port is *actually* listening and restarts `adbd` if it is not. |
| **Watches afterwards** | `adbfix-watchdog.sh` re-checks every 60 s and restarts `adbd` when the port goes away, with bounded retries and a 10-minute back-off. |
| **Stays awake while charging** | Sets `stay_on_while_plugged_in=7`. This has **zero** effect on battery — it only applies while a charger is attached. |

### Why verifying at boot matters

Setting the property is not enough. `adbd` is declared `disabled` in `init.usb.rc` and is
started by a `sys.usb.config=…,adb` property trigger, which can fire **before**
`post-fs-data.sh` runs. In that ordering `adbd` is already up and bound to USB only, and
setting the port property afterwards does not move it. `service.sh` closes that gap.

## Requirements

- Magisk 20.4+ (developed and tested on Magisk 30.7)
- Android with the legacy `service.adb.tcp.port` path (tested on Android 16 / API 36)
- Stock tools only: `netstat`, `stop`, `start`, `settings`, `setsid`, `getprop`

## Install

Zip the repo contents and install through the Magisk app (Modules → Install from storage), or:

```sh
adb push adbfix.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/adbfix.zip'
```

Then reboot. The device should come up on 5555 with no USB involved:

```sh
adb connect <device-ip>:5555
```

## Control

```sh
# follow the log (this is the authoritative one — see the note below)
adb shell su -c 'cat /data/adb/modules/adbfix/watchdog.log'

# stop the watchdog temporarily, e.g. while you want USB debugging to stick
adb shell su -c 'kill $(cat /data/adb/modules/adbfix/watchdog.pid)'

# start it again
adb shell su -c 'sh /data/adb/modules/adbfix/service.sh'
```

## Design notes

Three non-obvious things bit during development; all are worth knowing if you fork this.

**A pidfile alone does not give you single-instance.** PIDs are reused, and after a
reboot the pid recorded at the *previous* boot almost certainly belongs to some
unrelated process. A bare `kill -0 "$pid"` then succeeds, the fresh watchdog concludes
it is already running, exits — and you have **no watchdog at all, silently**. It is
invisible from the outside because `persist.adb.tcp.port` still makes `adbd` bind the
port at boot, so everything looks healthy until the first time you actually need
recovery. Check the process *identity*, not just its existence:

```sh
same_watchdog() {
    kill -0 "$1" 2>/dev/null || return 1
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q adbfix-watchdog
}
```

**Do not use `exec 9>file` + `flock -n 9` for the single-instance lock.** On Android,
`/system/bin/sh` is mksh, which silently ignores high-numbered file-descriptor
redirections — the fd is never opened and `flock` fails with `Bad file descriptor`.
Magisk runs module scripts with its *own* busybox `ash`, which *does* support it, so this
works under Magisk and then breaks the moment anyone runs the script by hand or from a
different context. This module uses a **pidfile** instead, which behaves the same under
both shells.

**Log to a file, not to logcat.** Magisk runs service scripts inside a private mount
namespace where `log` does not reach logcat, so `logcat -s <tag>` stays empty even though
the script clearly ran. `watchdog.log` is written unconditionally; the `log` call is kept
only as a best-effort extra.

Also: `$$` inside a `( … ) &` subshell expands to the *parent* shell's PID, which is
already gone by the time you read it. The watchdog is therefore a separate script, where
`$$` at top level is correct.

## Limitations

- **No recovery while the device is fully suspended.** `sleep` does not wake a suspended
  SoC, so the loop is simply frozen and recovery latency is unbounded while asleep. This
  is inherent to not holding a wakelock. While charging,
  `stay_on_while_plugged_in` keeps the device awake and recovery becomes deterministic —
  that synergy is why the two features ship in one module.
- **The watchdog repairs the port, not the properties.** It never writes
  `service.adb.tcp.port`, so it will not fight a deliberate manual change. If something
  clears both properties, restarting `adbd` will not bring the port back; the watchdog
  retries five times and then backs off for ten minutes rather than restarting `adbd`
  forever.
- **The watchdog is not self-supervising.** If it dies, nothing restarts it. Re-run
  `service.sh` or reboot.

## Compatibility

The module is deliberately conservative and touches nothing outside ADB and one power
setting. It does not disable Doze, does not hold a wakelock, and does not modify
SELinux policy.

Note that `adbd` binds `[::]:5555` — **all** interfaces, not just WiFi. The port is
reachable from the whole local network. ADB's own RSA authentication (`ro.adb.secure=1`)
still applies, so an unauthorized host cannot get a shell, but the port is not hidden. If
you need it confined, restrict it with iptables rather than expecting this module to.

## License

MIT — see [LICENSE](LICENSE).
