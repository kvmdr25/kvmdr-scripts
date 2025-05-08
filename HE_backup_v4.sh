#!/bin/bash

echo ""
echo "#########################"
echo " KVMDR Replicator MVP"
echo " Release : Summer '25"
echo " Codename: M2_Kent"
echo "#########################"
echo ""
echo "<---- Branch for HE Backup ---->"
echo "________________________________"
echo ""

HE_HOST="$1"
timestamp=$(date +%Y%m%d%H%M%S)
backup_time="$2"  # format: HH:MM


backup_date="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}"   # YYYY-MM-DD
backup_time="${timestamp:8:2}:${timestamp:10:2}:${timestamp:12:2}" # HH:MM:SS

echo " "
echo "Timestamp     : $timestamp"
echo " "
echo "Backup Date   : $backup_date"
echo " "
echo "Backup Time   : $backup_time"
echo " "

BACKUP_BASE="/backup/HE/$HE_HOST"
DEST_DIR="$BACKUP_BASE/$timestamp"
LOGFILE="/var/log/kvmdr/he_backup.log"
trace_log="/kvmdr/log/$HE_HOST/trace_$timestamp.log"
log_events="/kvmdr/log/$HE_HOST/events_$timestamp.log"

mkdir -p "$DEST_DIR" "$BACKUP_BASE/answer" "$BACKUP_BASE/ova" "$(dirname "$trace_log")"

# Logging functions
log_trace() {
    echo "[$(date '+%F %T')] $1" | tee -a "$trace_log"
}
log_events() {
    echo "[$(date '+%F %T')] $1" >> "$log_events"
}

# Databases
jobid_db="/root/vmSettings.db"
backup_db="/root/Backup_Index.db"
backup_failed=0

# HE Protection check
he_enabled=0
host_check=$(sqlite3 "$jobid_db" "SELECT he_protection_enabled FROM Source WHERE host_ip = '$HE_HOST';")

if [ -n "$host_check" ]; then
    he_enabled=$host_check
else
    host_check=$(sqlite3 "$jobid_db" "SELECT he_protection_enabled FROM Target WHERE host_ip = '$HE_HOST';")
    if [ -n "$host_check" ]; then
        he_enabled=$host_check
    fi
fi

if [ "$he_enabled" -ne 1 ]; then
    echo "[ERROR] Host Engine Protection is not enabled for $HE_HOST. Aborting backup."
    exit 1
fi

# Create he_backups table if missing
sqlite3 "$backup_db" <<EOF
CREATE TABLE IF NOT EXISTS he_backups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  host TEXT NOT NULL,
  backup_date TEXT,
  backup_time TEXT,
  engine_backup_file TEXT,
  dom_md_available INTEGER DEFAULT 0,
  dom_md_path TEXT,
  ova_file TEXT,
  answers_conf_path TEXT,
  hosted_engine_conf_path TEXT
);
EOF

# Job registration
job_type="HE Backup"
vm_id_input="$HE_HOST"

log_trace "Registering Job ID"
log_events "Registering Job ID"

sqlite3 "$jobid_db" "INSERT INTO table_jobid (job_type, vm_id, timestamp, status, logs_path, vm_name) VALUES ('$job_type', '$vm_id_input', '$timestamp', 'Running', '$log_events', '$vm_id_input');"

job_id=$(sqlite3 "$jobid_db" "SELECT job_id FROM table_jobid WHERE vm_id = '$vm_id_input' AND job_type = '$job_type' AND timestamp = '$timestamp';")

echo ""
echo " Job ID: $job_id"
echo ""

log_trace "Job ID: $job_id"
log_events "Job ID: $job_id"

# Begin backup
log_events "[INFO] Starting Hosted Engine backup from $HE_HOST to $DEST_DIR"
log_trace "[INFO] Starting Hosted Engine backup from $HE_HOST to $DEST_DIR"

# WebSocket push
taskquery="SELECT vm_name, status, job_type FROM table_jobid WHERE job_id='$job_id';"
taskresult=$(sqlite3 "$jobid_db" "$taskquery")
log_trace "Task: Raw Query Result: $taskresult"

if [ -n "$taskresult" ]; then
    IFS='|' read -r vm_name status job_type <<< "$taskresult"
    message="{\"vm_name\": \"$vm_name\", \"status\": \"$status\", \"job_type\": \"$job_type\"}"
    log_trace "Task: JSON Message: $message"
    echo "$message" | websocat ws://192.168.1.127:3001 \
        && log_trace "Task: Message sent successfully" \
        || log_trace "Task: Failed to send message via websocat"
else
    log_trace "Task: No data found for job_id=$job_id"
fi

# Rest of backup (answers.conf, hosted-engine.conf, OVA, dom_md, engine-backup)...
# (You can continue from your previous working blocks, no change needed.)

# Final recording to Backup_Index.db (same like before)

# Status and exit
if [ "$backup_failed" -eq 0 ]; then
    sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Completed' WHERE job_id = $job_id;"
    log_trace "Backup completed successfully."
    log_events "Backup completed successfully."
    echo "BACKUP_COMPLETION_SIGNAL"
    exit 0
else
    sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Failed' WHERE job_id = $job_id;"
    log_trace "Backup failed."
    log_events "Backup failed."
    echo "BACKUP_FAILED_SIGNAL"
    exit 1
fi
