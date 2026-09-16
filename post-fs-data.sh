#!/system/bin/sh
# Set adbd to listen on fixed tcp port 5555 at boot
setprop service.adb.tcp.port 5555
# Persist the port so adbd still binds 5555 after a wipe or when other modules are disabled
setprop persist.adb.tcp.port 5555
