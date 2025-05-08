#!/bin/bash

HE_HOST="$1"
CRON_TIME="$2"
timestamp=$(date +%Y%m%d%H%M%S)
backup_date="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}"
backup_time="${timestamp:8:2}:${timestamp:10:2}:${timestamp:12:2}"

BACKUP_BASE="/backup/HE/$HE_HOST"
DEST_DIR="$BACKUP_BASE/$timestamp"
LOGFILE="/var/log/kvmdr/he_backup.log"
trace_log="/kvmdr/log/$HE_HOST/trace_$timestamp.log"
log_events_file="/kvmdr/log/$HE_HOST/events_$timestamp.log"

mkdir -p "$DEST_DIR" "$BACKUP_BASE/answer" "$BACKUP_BASE/ova" "$(dirname "$trace_log")"

log_trace() {
    echo "[$(date '+%F %T')] $1" | tee -a "$trace_log"
}
log_events() {
    echo "[$(date '+%F %T')] $1" >> "$log_events_file"
}

jobid_db="/root/vmSettings.db"
backup_db="/root/Backup_Index.db"
backup_failed=0

# Schedule cron if valid
if [[ "$CRON_TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    cron_hour=$(echo "$CRON_TIME" | cut -d: -f1)
    cron_minute=$(echo "$CRON_TIME" | cut -d: -f2)
    cronline="$cron_minute $cron_hour * * * /root/HE_backup_v5.sh $HE_HOST >> $LOGFILE 2>&1"

    crontab -l 2>/dev/null | grep -v "HE_backup_v5.sh $HE_HOST" | { cat; echo "$cronline"; } | crontab -
    log_trace "[INFO] Cron job scheduled at $CRON_TIME for $HE_HOST"
    log_events "[INFO] Cron job scheduled at $CRON_TIME for $HE_HOST"
fi

# HE Protection check
he_enabled=$(sqlite3 "$jobid_db" "SELECT he_protection_enabled FROM Source WHERE host_ip='$HE_HOST' UNION SELECT he_protection_enabled FROM Target WHERE host_ip='$HE_HOST';")
if [[ "$he_enabled" != "1" ]]; then
    log_trace "[ERROR] HE Protection not enabled for $HE_HOST"
    log_events "[ERROR] HE Protection not enabled for $HE_HOST"
    exit 1
fi

# Register job
sqlite3 "$jobid_db" <<EOF
CREATE TABLE IF NOT EXISTS table_jobid (
  job_id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_type TEXT,
  vm_id TEXT,
  timestamp TEXT,
  status TEXT,
  logs_path TEXT,
  vm_name TEXT
);
EOF

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

job_type="HE Backup"
sqlite3 "$jobid_db" "INSERT INTO table_jobid (job_type, vm_id, timestamp, status, logs_path, vm_name) VALUES ('$job_type', '$HE_HOST', '$timestamp', 'Running', '$log_events_file', '$HE_HOST');"
job_id=$(sqlite3 "$jobid_db" "SELECT job_id FROM table_jobid WHERE vm_id='$HE_HOST' AND timestamp='$timestamp' LIMIT 1;")

log_trace "[INFO] Starting backup for $HE_HOST"
log_trace "[INFO] Job ID: $job_id"
log_events "[INFO] Starting backup for $HE_HOST"
log_events "[INFO] Job ID: $job_id"

# 1. answers.conf
remote_answers="/etc/ovirt-hosted-engine/answers.conf"
local_answers="$BACKUP_BASE/answer/answers.conf"
if [ ! -f "$local_answers" ]; then
    scp root@"$HE_HOST":"$remote_answers" "$local_answers" && log_events "[INFO] answers.conf copied" || log_events "[WARN] answers.conf missing"
else
    log_events "[INFO] Skipping answers.conf — already backed up"
fi

# 2. hosted-engine.conf
remote_heconf="/etc/ovirt-hosted-engine/hosted-engine.conf"
local_heconf="$BACKUP_BASE/answer/hosted-engine.conf"
if [ ! -f "$local_heconf" ]; then
    scp root@"$HE_HOST":"$remote_heconf" "$local_heconf" && log_events "[INFO] hosted-engine.conf copied" || log_events "[WARN] hosted-engine.conf missing"
else
    log_events "[INFO] Skipping hosted-engine.conf — already backed up"
fi

# 3. OVA
ova_dir="/usr/share/ovirt-engine-appliance"
ova_file=$(ssh root@"$HE_HOST" "ls -1t $ova_dir/*.ova 2>/dev/null | head -n1")
if [ -n "$ova_file" ]; then
    ova_name=$(basename "$ova_file")
    local_ova="$BACKUP_BASE/ova/$ova_name"
    if [ ! -f "$local_ova" ]; then
        scp root@"$HE_HOST":"$ova_file" "$local_ova" && log_events "[INFO] OVA copied: $ova_name" || log_events "[WARN] OVA copy failed"
    else
        log_events "[INFO] Skipping OVA — already backed up: $ova_name"
    fi
else
    log_events "[WARN] No OVA found in $ova_dir"
fi

# 4. dom_md — only metadata
dom_md_remote=$(ssh root@"$HE_HOST" "find /rhev/data-center/mnt -type d -name dom_md | head -n1")
if [ -n "$dom_md_remote" ]; then
    mkdir -p "$DEST_DIR/dom_md"
    rsync -avz --rsync-path="sudo rsync" --no-perms --no-owner --no-group \
      --omit-dir-times --ignore-errors \
      --include="metadata" --exclude="*" \
      root@"$HE_HOST":"$dom_md_remote/" "$DEST_DIR/dom_md" && \
      log_events "[INFO] metadata copied from dom_md" || \
      log_events "[WARN] Failed to copy dom_md"
else
    log_events "[WARN] No dom_md found"
fi

# Final backup entry
sqlite3 "$backup_db" "INSERT INTO he_backups (host, backup_date, backup_time, engine_backup_file, dom_md_path, ova_file, answers_conf_path, hosted_engine_conf_path) VALUES ('$HE_HOST', '$backup_date', '$backup_time', '', '$DEST_DIR/dom_md', '$local_ova', '$local_answers', '$local_heconf');"

# Mark job completed
sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Completed' WHERE job_id = $job_id;"
log_events "[INFO] Backup completed for $HE_HOST"

# Confirm
echo "BACKUP_COMPLETION_SIGNAL"
exit 0
