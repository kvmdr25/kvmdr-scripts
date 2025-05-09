#!/bin/bash
logdir="/backup/systemlog"
timestamp=$(date +%Y%m%d_%H%M%S)
logfile="$logdir/npm_$timestamp.log"

# Rotate existing npm_latest.log
if [ -e "$logdir/npm_latest.log" ]; then
    prev_log=$(readlink -f "$logdir/npm_latest.log" || echo "")
    if [ -n "$prev_log" ] && [ -f "$prev_log" ]; then
        mv "$prev_log" "${prev_log%.log}_final.log"
    fi
    rm -f "$logdir/npm_latest.log"
fi

# Start logging
echo "=== NPM KVMDR started at $(date) ===" >> "$logfile"
cd /root/ovirt-webgui/src/components || exit 1

# Start app in background and immediately update symlink
npm start >> "$logfile" 2>&1 &
ln -sf "$logfile" "$logdir/npm_latest.log"

# Hold foreground so systemd doesn’t restart
wait $!
