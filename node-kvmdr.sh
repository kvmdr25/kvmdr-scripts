#!/bin/bash
timestamp=$(date +%Y%m%d_%H%M%S)
logfile="/backup/systemlog/node_$timestamp.log"

echo "=== Node KVMDR started at $(date) ===" >> "$logfile"
/usr/bin/node /root/ovirt-backup-server.js >> "$logfile" 2>&1

ln -sf "$logfile" /backup/systemlog/node_latest.log
