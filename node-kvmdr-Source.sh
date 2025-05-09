#!/bin/bash
logdir="/backup/systemlog"
timestamp=$(date +%Y%m%d_%H%M%S)
logfile="$logdir/node_Source_${timestamp}.log"
latest_log="$logdir/node_Source_latest.log"

echo "=== Node KVMDR started at $(date) ===" >> "$logfile"

/usr/bin/node /root/ovirt-backup-server.js >> "$logfile" 2>&1 &

ln -sf "$logfile" "$latest_log"

sleep 3

sqlite3 /root/vmSettings.db "UPDATE Source SET node_start = '$timestamp' WHERE id = 1;"

wait $!
