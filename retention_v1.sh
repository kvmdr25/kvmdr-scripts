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

echo "📌 Starting retention for: $vm_id_input"
echo "🗃️ Table: $tablename"
echo " "

# Step 1: Get retention period
retention_days=$(sqlite3 "$vm_settings_db" "SELECT retentionPeriod FROM vmAttribs WHERE vmId='$vm_id_input';")
if [ -z "$retention_days" ]; then
  echo "❌ retentionPeriod not found in vmSettings.db"
  exit 1
fi
echo "📅 Retention: $retention_days days"

# Step 2: Check if we have enough data to process
first_inc_date=$(sqlite3 "$backup_index_db" "SELECT Date FROM $tablename WHERE Full_Backup IN (0, 25) ORDER BY Date ASC LIMIT 1;")

cutoff_check=$(date -d "$first_inc_date +$retention_days days" +%Y-%m-%d)
today=$(date +%Y-%m-%d)

if [[ "$cutoff_check" > "$today" ]]; then
  days_remaining=$(( ( $(date -d "$cutoff_check" +%s) - $(date -d "$today" +%s) ) / 86400 ))
  echo "📋 Incrementals found:"
  sqlite3 "$backup_index_db" "SELECT Date, Time, Checkpoint FROM $tablename WHERE Full_Backup IN (0, 25) ORDER BY Date, Time;" |
  while IFS='|' read -r d t c; do
    echo "🧱 $d $t | Checkpoint: $c"
  done
  echo "⏳ Retention not reached. $days_remaining day(s) remaining (until $cutoff_check)."
  exit 0
fi


# Step 3: Get full backup details
original_full_date=$(sqlite3 "$backup_index_db" "SELECT Date FROM $tablename WHERE Full_Backup=1 ORDER BY Date ASC LIMIT 1;")
full_backup_path=$(sqlite3 "$backup_index_db" "SELECT Backup_path FROM $tablename WHERE Full_Backup=1 ORDER BY Date ASC LIMIT 1;")
vm_name=$(sqlite3 "$backup_index_db" "SELECT vm_name FROM $tablename LIMIT 1;")
disk_id=$(sqlite3 "$backup_index_db" "SELECT disk_id FROM $tablename LIMIT 1;")
timestamp=$(date +%Y%m%d_%H%M%S)
synthetic_path="/backup/tmp/SYNTHETIC_${vm_name}_${timestamp}.raw"

echo "📂 Original full: $full_backup_path"
echo "🧩 VM: $vm_name | Disk: $disk_id"
echo "📦 Merging into: $synthetic_path"
echo " "

# Step 4: Debug list of incrementals
echo "📋 Incrementals to merge:"
sqlite3 "$backup_index_db" "SELECT Date, Time, Checkpoint FROM $tablename WHERE Full_Backup=0 ORDER BY Date, Time;" |
while IFS='|' read -r d t c; do
  echo "🧱 $d $t | Checkpoint: $c"
done

readarray -t checkpoint_array < <(sqlite3 "$backup_index_db" "SELECT Checkpoint FROM $tablename WHERE Full_Backup=0 ORDER BY Date, Time;")
if [ ${#checkpoint_array[@]} -eq 0 ]; then
  echo "❌ No incrementals to merge"
  exit 1
fi

# Step 5: Perform merge directly here
echo "🔧 Starting synthetic full creation..."

cp "$full_backup_path" "${synthetic_path}.tmp"

for checkpoint in "${checkpoint_array[@]}"; do
  echo "📍 Processing checkpoint: $checkpoint"
  
  sqlite3 "$backup_index_db" "SELECT Start, Length FROM $incremental_table WHERE Checkpoint='$checkpoint' AND Dirty='true';" |
  while IFS='|' read -r start length; do
    file_path=$(find /backup/restore -name "${vm_id_input}_${start}_${length}.raw" 2>/dev/null | head -n 1)
    
    if [ -f "$file_path" ]; then
      echo "✏️ Writing $file_path at offset $start (length: $length)"
      dd if="$file_path" of="${synthetic_path}.tmp" bs=1 seek="$start" count="$length" conv=notrunc status=none
    else
      echo "⚠️ Missing file: ${vm_id_input}_${start}_${length}.raw"
    fi
  done
done

mv "${synthetic_path}.tmp" "$synthetic_path"
echo "✅ Synthetic full successfully created at: $synthetic_path"

# Step 6: Register synthetic full
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

echo "✅ Synthetic full registered in DB. 🔍 Details:"
sqlite3 "$backup_index_db" <<EOF
.headers on
.mode column
SELECT * FROM $tablename
WHERE Backup_path = '$synthetic_path';
EOF

# Step 7: Create archive table
sqlite3 "$backup_index_db" "CREATE TABLE IF NOT EXISTS $archive_table AS SELECT * FROM $tablename WHERE 0;"
echo "📁 Archive table ready: $archive_table"

# Step 8: Archive old data
delete_cutoff=$(date -d "$first_inc_date +$retention_days days" +%Y-%m-%d)
echo "🕓 Archiving records with Date <= $delete_cutoff"
sqlite3 "$backup_index_db" "INSERT INTO $archive_table SELECT * FROM $tablename WHERE Date <= '$delete_cutoff' AND Full_Backup IN (0,1);"

# Step 9: Delete raw files
echo "🧹 Deleting raw files <= $delete_cutoff"
old_files=$(sqlite3 "$backup_index_db" "SELECT Backup_path FROM $tablename WHERE Date <= '$delete_cutoff' AND Full_Backup IN (0,1);")
for file in $old_files; do
  if [ -f "$file" ]; then
    echo "🗑️ Removing $file"
    rm -f "$file"
  else
    echo "⚠️ File not found: $file"
  fi
done

# Step 10: Delete records
echo "🧼 Removing DB records <= $delete_cutoff"
sqlite3 "$backup_index_db" "DELETE FROM $tablename WHERE Date <= '$delete_cutoff' AND Full_Backup IN (0,1);"

# Step 11: Clean synthetic image
echo "🧽 Cleaning up temp image: $synthetic_path"
if [ -f "$synthetic_path" ]; then
  rm -f "$synthetic_path"
  echo "🗑️ Removed: $synthetic_path"
else
  echo "⚠️ Not found: $synthetic_path"
fi

echo "✅ Retention complete for VM: $vm_id_input"
