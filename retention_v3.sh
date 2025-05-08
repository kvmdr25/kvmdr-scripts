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
archive_incremental_table="archive_$incremental_table"

retention_days=$(sqlite3 "$vm_settings_db" "SELECT archive_retention FROM vmAttribs WHERE vmId='$vm_id_input';")
archive_target="/backup/archive"

echo "*********** Step 1: Get retention and archive target ***********"
echo "📅 Retention: $retention_days days"
echo "📂 Archive Target: $archive_target"
echo ""

echo "*********** Step 2: Check if we have enough data to process ***********"
first_inc_date=$(sqlite3 "$backup_index_db" "SELECT Date FROM $tablename WHERE Full_Backup IN (0,25) ORDER BY Date ASC LIMIT 1;")
if [ -z "$first_inc_date" ]; then
  echo "⚠️ No incrementals found. Skipping."
  exit 0
fi
cutoff_check=$(date -d "$first_inc_date +$retention_days days" +%Y-%m-%d)
today=$(date +%Y-%m-%d)
if [[ "$cutoff_check" > "$today" ]]; then
  echo "⏳ Retention not reached. Skipping."
  exit 0
fi
echo ""

echo "*********** Step 3: Get full backup details ***********"
full_backup_path=$(sqlite3 "$backup_index_db" "SELECT Backup_path FROM $tablename WHERE Full_Backup=1 ORDER BY Date ASC LIMIT 1;")
vm_name=$(sqlite3 "$backup_index_db" "SELECT vm_name FROM $tablename WHERE Full_Backup=1 ORDER BY Date ASC LIMIT 1;")
disk_id=$(sqlite3 "$backup_index_db" "SELECT disk_id FROM $tablename WHERE Full_Backup=1 ORDER BY Date ASC LIMIT 1;")
synthetic_path="/backup/tmp/SYNTHETIC_${vm_name}_$(date +%Y%m%d_%H%M%S).raw"

echo "📂 Original full: $full_backup_path"
echo "🧩 VM: $vm_name | Disk: $disk_id"
echo "📦 Merging into: $synthetic_path"
echo ""

echo "*********** Step 4: Perform Merge ***********"
checkpoints=$(sqlite3 "$backup_index_db" "SELECT Checkpoint FROM $tablename WHERE Full_Backup IN (0,25) ORDER BY Date, Time;")
echo "📋 Incrementals to merge:"
sqlite3 "$backup_index_db" "SELECT Date, Time, Checkpoint FROM $tablename WHERE Full_Backup IN (0,25) ORDER BY Date, Time;" |
while IFS='|' read -r d t c; do
  echo "🧱 $d $t | Checkpoint: $c"
done
echo ""

cp "$full_backup_path" "${synthetic_path}.tmp"

for checkpoint in $checkpoints; do
  echo "📍 Processing checkpoint: $checkpoint"
  sqlite3 "$backup_index_db" "SELECT Start, Length FROM $incremental_table WHERE Checkpoint='$checkpoint' AND Dirty='true';" |
  while IFS='|' read -r start length; do
    file_path=$(find /backup/restore -name "${vm_id_input}_${start}_${length}.raw" 2>/dev/null | head -n 1)
    if [ -f "$file_path" ]; then
      echo "✏️ Writing $file_path at offset $start (length: $length)"
      dd if="$file_path" of="${synthetic_path}.tmp" bs=1 seek="$start" count="$length" conv=notrunc status=none
    else
      echo "⚠️ Missing: $file_path"
    fi
  done
done

mv "${synthetic_path}.tmp" "$synthetic_path"
echo "✅ Synthetic full created at: $synthetic_path"
echo ""

echo "*********** Step 5: Move Full Backup to Archive ***********"
mkdir -p "$archive_target"
mv "$full_backup_path" "$archive_target/$(basename "$full_backup_path")"
echo "✅ Moved full backup: $(basename "$full_backup_path")"
echo ""

echo "*********** Step 6: Register Synthetic Backup ***********"
size=$(du -m "$synthetic_path" | cut -f1)
timestamp_now=$(date +%Y-%m-%d)
time_now=$(date +%H:%M:%S)

sqlite3 "$backup_index_db" <<EOF
INSERT INTO $tablename (
  vm_id, vm_name, disk_id, Full_Backup,
  Backup_path, Checkpoint, Time, Date,
  Status, Duration, Size
)
VALUES (
  '$vm_id_input', '$vm_name', '$disk_id', 1,
  '/backup/$(basename "$full_backup_path")', 'Synthetic No Checkpoint',
  '$time_now', '$timestamp_now',
  'Synthetic FULL created successfully', 0, '$size'
);
EOF

echo "✅ Synthetic full registered."

# 📋 Display the new synthetic full record
echo ""
echo "🔍 Verifying inserted synthetic backup in $tablename:"
sqlite3 "$backup_index_db" <<EOF
.headers on
.mode column
SELECT * FROM $tablename WHERE Date = '$timestamp_now' AND Time = '$time_now' AND Full_Backup = 1 ORDER BY id DESC LIMIT 1;
EOF

echo ""

echo "*********** Step 6.2: Replace original full backup ***********"
cp "$synthetic_path" "/backup/$(basename "$full_backup_path")"
echo "✅ Synthetic backup copied to: /backup/$(basename "$full_backup_path")"
echo ""

echo "*********** Step 7: Archive table_BI and incremental ***********"

# Create archive tables if not already present
sqlite3 "$backup_index_db" "CREATE TABLE IF NOT EXISTS $archive_table AS SELECT * FROM $tablename WHERE 0;"
sqlite3 "$backup_index_db" "CREATE TABLE IF NOT EXISTS $archive_incremental_table AS SELECT * FROM $incremental_table WHERE 0;"

# Calculate retention cutoff date
delete_cutoff=$(date -d "$first_inc_date +$retention_days days" +%Y-%m-%d)
echo "🕓 Archiving records with Date <= $delete_cutoff"

# Archive only valid fulls (exclude synthetic), and incrementals (0, 25)
sqlite3 "$backup_index_db" "INSERT INTO $archive_table SELECT * FROM $tablename WHERE Date <= '$delete_cutoff' AND Full_Backup IN (0,1,25) AND Checkpoint != 'Synthetic No Checkpoint';"
sqlite3 "$backup_index_db" "INSERT INTO $archive_incremental_table SELECT * FROM $incremental_table WHERE Date <= '$delete_cutoff';"

# Update paths in archive_table_BI
sqlite3 "$backup_index_db" "UPDATE $archive_table SET Backup_path = REPLACE(Backup_path, '/backup/restore', '/backup/archive/restore') WHERE Full_Backup IN (0,25);"
sqlite3 "$backup_index_db" "UPDATE $archive_table SET Backup_path = REPLACE(Backup_path, '/backup/', '/backup/archive/') WHERE Full_Backup = 1;"

echo "✅ Archived full and incremental metadata."
echo ""


echo "*********** Step 8: Clean-up ***********"

echo "📋 Table before deletion:"
sqlite3 "$backup_index_db" <<EOF
.headers on
.mode column
SELECT id, vm_name, Full_Backup, Backup_path, Status, Date FROM $tablename;
EOF
echo ""


sqlite3 "$backup_index_db" "DELETE FROM $tablename WHERE Date <= '$delete_cutoff' AND Full_Backup IN (0,1,25) AND Status != 'Synthetic FULL created successfully';"
sqlite3 "$backup_index_db" "DELETE FROM $incremental_table WHERE Date <= '$delete_cutoff';"
echo "✅ Old entries removed."
echo ""

echo "📋 Table after deletion:"
sqlite3 "$backup_index_db" <<EOF
.headers on
.mode column
SELECT id, vm_name, Full_Backup, Backup_path, Status, Date FROM $tablename;
EOF



echo ""
echo "✅ Retention complete for VM: $vm_id_input"
