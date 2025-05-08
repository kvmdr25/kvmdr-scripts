#!/bin/bash
set -e

vm_id_input="$1"
if [ -z "$vm_id_input" ]; then
  echo "❌ Usage: $0 <vm_id>"
  exit 1
fi

backup_index_db="/root/Backup_Index.db"
vm_settings_db="/root/vmSettings.db"
sanitized_vm_id=$(echo "$vm_id_input" | sed 's/[^a-zA-Z0-9]//g')
tablename="table_BI_$sanitized_vm_id"
incremental_table="incremental_$sanitized_vm_id"
archive_table="archive_table_BI_$sanitized_vm_id"

# Define log directory and file with timestamp
timestamp=$(date +%Y%m%d_%H%M%S)
log_dir="/kvmdr/log/archive/$vm_id_input"
mkdir -p "$log_dir"
log_file="$log_dir/retention_$timestamp.log"

# Start logging
echo "Starting retention for VM: $vm_id_input" | tee -a "$log_file"
echo "Table: $tablename" | tee -a "$log_file"

# Step 1: Get retention and archive target
retention_days=$(sqlite3 "$vm_settings_db" "SELECT retentionPeriod FROM vmAttribs WHERE vmId='$vm_id_input';")
archive_target=$(sqlite3 "$vm_settings_db" "SELECT archive_target FROM vmAttribs WHERE vmId='$vm_id_input';")
if [ -z "$retention_days" ] || [ -z "$archive_target" ]; then
  echo "❌ Missing retention_days or archive_target" | tee -a "$log_file"
  exit 1
fi
echo "📅 Retention: $retention_days days" | tee -a "$log_file"
echo "📂 Archive Target: $archive_target" | tee -a "$log_file"

# Step 2: Check if we have enough data to process
first_inc_date=$(sqlite3 "$backup_index_db" "SELECT Date FROM $tablename WHERE Full_Backup IN (0, 25) ORDER BY Date ASC LIMIT 1;")
if [ -z "$first_inc_date" ]; then
  echo "⚠️ No incrementals found for this VM." | tee -a "$log_file"
  echo "ℹ️ Retention of $retention_days days will begin after the first incremental is created." | tee -a "$log_file"
  exit 0
fi

cutoff_check=$(date -d "$first_inc_date +$retention_days days" +%Y-%m-%d)
today=$(date +%Y-%m-%d)

echo "Checking if retention period is reached..." | tee -a "$log_file"
if [[ "$cutoff_check" > "$today" ]]; then
  days_remaining=$(( ( $(date -d "$cutoff_check" +%s) - $(date -d "$today" +%s) ) / 86400 ))
  echo "📋 Incrementals found:" | tee -a "$log_file"
  sqlite3 "$backup_index_db" "SELECT Date, Time, Checkpoint FROM $tablename WHERE Full_Backup IN (0, 25) ORDER BY Date, Time;" |
  while IFS='|' read -r d t c; do
    echo "🧱 $d $t | Checkpoint: $c" | tee -a "$log_file"
  done
  echo "⏳ Retention not reached. $days_remaining day(s) remaining (until $cutoff_check)." | tee -a "$log_file"
  exit 0
fi

# Step 3: Get full backup details
original_full_date=$(sqlite3 "$backup_index_db" "SELECT Date FROM $tablename WHERE Full_Backup=1 ORDER BY Date ASC LIMIT 1;")
full_backup_path=$(sqlite3 "$backup_index_db" "SELECT Backup_path FROM $tablename WHERE Full_Backup=1 ORDER BY Date ASC LIMIT 1;")
vm_name=$(sqlite3 "$backup_index_db" "SELECT vm_name FROM $tablename LIMIT 1;")
disk_id=$(sqlite3 "$backup_index_db" "SELECT disk_id FROM $tablename LIMIT 1;")
timestamp=$(date +%Y%m%d_%H%M%S)
synthetic_path="/backup/tmp/SYNTHETIC_${vm_name}_${timestamp}.raw"

echo "📂 Original full: $full_backup_path" | tee -a "$log_file"
echo "🧩 VM: $vm_name | Disk: $disk_id" | tee -a "$log_file"
echo "📦 Merging into: $synthetic_path" | tee -a "$log_file"

# Step 4: List incrementals
echo "📋 Incrementals to merge:" | tee -a "$log_file"
sqlite3 "$backup_index_db" "SELECT Date, Time, Checkpoint FROM $tablename WHERE Full_Backup=0 ORDER BY Date, Time;" |
while IFS='|' read -r d t c; do
  echo "🧱 $d $t | Checkpoint: $c" | tee -a "$log_file"
done

readarray -t checkpoint_array < <(sqlite3 "$backup_index_db" "SELECT Checkpoint FROM $tablename WHERE Full_Backup=0 ORDER BY Date, Time;")
if [ ${#checkpoint_array[@]} -eq 0 ]; then
  echo "❌ No incrementals to merge" | tee -a "$log_file"
  exit 1
fi

# Step 5: Create archive table
sqlite3 "$backup_index_db" "CREATE TABLE IF NOT EXISTS $archive_table AS SELECT * FROM $tablename WHERE 0;"
echo "📁 Archive table ready: $archive_table" | tee -a "$log_file"

# Step 6: Archive old data
delete_cutoff=$(date -d "$first_inc_date +$retention_days days" +%Y-%m-%d)
echo "🕓 Archiving records with Date <= $delete_cutoff" | tee -a "$log_file"
sqlite3 "$backup_index_db" "INSERT INTO $archive_table SELECT * FROM $tablename WHERE Date <= '$delete_cutoff' AND Full_Backup IN (0,1);" | tee -a "$log_file"

# Step 7: Perform merge
echo "🔧 Starting synthetic full creation..." | tee -a "$log_file"
cp "$full_backup_path" "${synthetic_path}.tmp"
for checkpoint in "${checkpoint_array[@]}"; do
  echo "📍 Processing checkpoint: $checkpoint" | tee -a "$log_file"
  sqlite3 "$backup_index_db" "SELECT Start, Length FROM $incremental_table WHERE Checkpoint='$checkpoint' AND Dirty='true';" |
  while IFS='|' read -r start length; do
    file_path=$(find /backup/restore/$vm_id_input -name "${vm_id_input}_${start}_${length}.raw" 2>/dev/null | head -n 1)
    if [ -f "$file_path" ]; then
      echo "✏️ Writing $file_path at offset $start (length: $length)" | tee -a "$log_file"
      dd if="$file_path" of="${synthetic_path}.tmp" bs=1 seek="$start" count="$length" conv=notrunc status=none
    else
      echo "⚠️ Missing file: ${vm_id_input}_${start}_${length}.raw" | tee -a "$log_file"
    fi
  done
done
mv "${synthetic_path}.tmp" "$synthetic_path"
echo "✅ Synthetic full successfully created at: $synthetic_path" | tee -a "$log_file"

# Step 8: Register synthetic full
size=$(du -m "$synthetic_path" | cut -f1)
sqlite3 "$backup_index_db" <<EOF
INSERT INTO $tablename (
  vm_id, vm_name, disk_id, Full_Backup,
  Backup_path, Checkpoint, Time, Date,
  Status, Duration, Size
)
VALUES (
  '$vm_id_input', '$vm_name', '$disk_id', 1,
  '$synthetic_path', 'Synthetic No Checkpoint',
  '$(date +%H:%M:%S)', '$(date +%Y-%m-%d)',
  'Synthetic FULL created successfully', 0, '$size'
);
EOF

echo "✅ Synthetic full registered in DB." | tee -a "$log_file"

# Step 9: Move archived raw files
echo "📦 Moving raw files to archive target: $archive_target" | tee -a "$log_file"
target_directory="$archive_target/restore/$vm_id_input"
mkdir -p "$target_directory"  # Ensure the target directory exists
sqlite3 "$backup_index_db" "SELECT Backup_path, Date, Time FROM $archive_table WHERE Date <= '$delete_cutoff';" |
while IFS='|' read -r file d t; do
  if [ -f "$file" ]; then
    new_file_path="$target_directory/$(basename $file)"
    echo "📂 Moving $file → $new_file_path" | tee -a "$log_file"
    mv "$file" "$new_file_path"
    echo "✅ Moved $file to $new_file_path" | tee -a "$log_file"
    sqlite3 "$backup_index_db" "UPDATE $archive_table SET Backup_path = '$new_file_path' WHERE Date = '$d' AND Time = '$t';"
  else
    echo "⚠️ File not found: $file" | tee -a "$log_file"
  fi
done

# Step 10: Delete old records (excluding new synthetic)
echo "🧼 Removing DB records <= $delete_cutoff" | tee -a "$log_file"
sqlite3 "$backup_index_db" "DELETE FROM $tablename WHERE Date <= '$delete_cutoff' AND Backup_path != '$synthetic_path';"

echo "✅ Retention complete for VM: $vm_id_input" | tee -a "$log_file"
