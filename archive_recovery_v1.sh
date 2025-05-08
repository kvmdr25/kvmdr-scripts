#!/bin/bash

set -e

# Capture start time
start_time=$(date +%s)

echo " "  
echo "#########################"
echo " KVMDR Replicator MVP"
echo " Release : Summer '24"
echo " Codename: M2_Kent"
echo "#########################"
echo " "
echo "<--Branch for Restore with RR---->"
echo "__________________________________"
echo " "

# Arguments and initial setup
vm_id_input="$1"
date_input="$2"
time_input="$3"

if [ -z "$vm_id_input" ] || [ -z "$date_input" ] || [ -z "$time_input" ]; then
  echo "Error: Missing arguments. Usage: $0 <vm_id> <date> <time>"
  exit 1
fi

original_vmid="$vm_id_input"   

sanitized_vm_id=$(echo "$vm_id_input" | sed 's/[^a-zA-Z0-9]//g')
sanitized_tablename="table_BI_$sanitized_vm_id"
timestamp=$(date +%Y%m%d%H%M%S)
trace_log="/kvmdr/log/restore/$vm_id_input/trace_$timestamp.log"
log_events="/kvmdr/log/restore/$vm_id_input/events_$timestamp.log"
bearer_Token=""
url_Engine="https://dr.local/ovirt-engine"
url_getToken="$url_Engine/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"
backup_index_db="Backup_Index.db"
incremental_table="incremental_$sanitized_vm_id"
restore_session_table="restore_session_$sanitized_vm_id"
compression="off"  #(candidate for Recovery)
turbo="on"   #(candidate for Recovery)
reverseReplicationStatus="on"  #(candidate for Recovery )
OS_type="alpine"
#OS_type="redhat"  # Hardcoded OS type (candidate for setting DB)
jobid_db="/root/vmSettings.db"
job_type="Recovery"

echo " "                                                                                                                            
echo "Timestamp: $timestamp"  # Ensure this is part of the script's output                                                          
echo " "                                                                                                                            
                                                                                                                                    
# Write the timestamp to a file named timestamp_<vmid>.txt                                                                          
echo "${timestamp}" > "/tmp/timestamp_recovery${vm_id_input}.txt"    


# Function to remove a cron job related to the given vm_id_input
remove_cron_job() {
    local vm_id="$1"
    crontab -l | grep -v "$vm_id" | crontab -
    echo "Cron job related to VM ID $vm_id has been removed."
}

# Call the function to remove the cron job
remove_cron_job "$vm_id_input"

# Status file setup
status_file="/backup/status/${vm_id_input}/restore_upload_status.txt"
mkdir -p "$(dirname "$status_file")"
if [ -f "$status_file" ]; then
  rm "$status_file"
fi

# Hardcoded network configuration
new_ip="192.168.1.77"      # New IP address to configure
new_netmask="255.255.255.0" # New netmask to configure
new_gateway="192.168.1.254" # New gateway to configure

# Start Logging
mkdir -p "$(dirname "$trace_log")"
mkdir -p "$(dirname "$log_events")"

log_trace() {
  echo "$(date '+%Y-%M-%d %H:%M:%S') - $1" >> "$trace_log"
}

log_events() {
  echo "$(date '+%Y-%M-%d %H:%M:%S') - $1" >> "$log_events"
}

log_trace "=====================Starting the Log====================="
log_events "=====================Starting the Log====================="

log_trace " Recovering NOW "
log_events " Recovering NOW "

log_trace " Registering Job ID "
log_events " Registering Job ID "

# Starting jobid session
# Insert the new job into the database
sqlite3 "$jobid_db" "INSERT INTO table_jobid (job_type, vm_id, timestamp, status, logs_path) VALUES ('$job_type', '$vm_id_input', '$timestamp', 'Running', '$log_events');"

#update the table in the end for the status

# Retrieve the last assigned job_id
# Query the job_id using vm_id, job_type, and timestamp
job_id=$(sqlite3 "$jobid_db" "SELECT job_id FROM table_jobid WHERE vm_id = '$vm_id_input' AND job_type = '$job_type' AND timestamp = '$timestamp';")


echo " "
echo " Job ID: $job_id"
echo " "


# Log the retrieved job_id
log_trace " Job ID:  $job_id "
log_events " Job ID: $job_id "

# Fetch original_vmid and make it global
original_vm_id=$vm_id_input
sanitized_original_vmid=$(echo "$original_vm_id" | sed 's/[^a-zA-Z0-9]//g')

log_trace " Fetch original_vmid and make it global "
log_events " Fetch original_vmid and make it global "


cleanup_loop_devices() {
  echo "Cleaning up existing loop devices..."
  losetup -D || true
  for partition in /dev/mapper/loop0p*; do
    if mount | grep "$partition" > /dev/null; then
      umount "$partition" || true
    fi
  done
  kpartx -d /dev/loop0 || true
  losetup -d /dev/loop0 || true
  dmsetup remove_all
}

clean() {
  echo "Listing files in /backup/tmp..."
  ls -lh /backup/tmp
  echo " "

  echo "Stat files before deletion:"
  stat "$merged_backup_file"
  stat "$qcow2_file"
  echo " "

  echo "Cleaning up temporary files..."
  rm -f "$merged_backup_file"
  rm -f "$qcow2_file"
  echo "Temporary files deleted."
  echo " "
}

remove_duplicate_devices() {
  echo "Removing duplicate devices..."
  for pv in $(pvs --noheadings -o pv_name 2>/dev/null); do
    vgreduce --removemissing "$pv" || true
  done
  dmsetup remove_all || true
}

modify_network_configuration() {
  echo "Mounting the disk to modify network configuration..."

  if [ "$OS_type" == "redhat" ]; then
    # Clean up any existing loop devices before setting up the new one
    cleanup_loop_devices
    
    losetup /dev/loop0 "$merged_backup_file"
    modprobe loop

    # Create device mappings
    echo "Creating partition mappings with kpartx..."
    kpartx -a /dev/loop0

    # Remove duplicate devices
    # remove_duplicate_devices

    # Scan for LVM volume groups
    echo "Scanning for LVM volume groups..."
    vgscan

    # Activate the LVM volume groups
    echo "Activating LVM volume groups..."
    vgchange -ay

    # List logical volumes to verify activation
    echo "Listing logical volumes..."
    lvs

    # Attempt to mount the root logical volume
    echo "Attempting to mount the root logical volume..."
    mount /dev/rhel/root /backup/mnt

    if [ $? -ne 0 ]; then
      echo "Error: Failed to mount the root logical volume."
      exit 1
    fi

    # Check if the root filesystem is mounted and modify network configuration
    echo "Checking for network configuration files..."
    if [ -f /backup/mnt/etc/NetworkManager/system-connections/enp1s0.nmconnection ]; then
      echo "Network configuration file found: /backup/mnt/etc/NetworkManager/system-connections/enp1s0.nmconnection"

      # Backup the existing network configuration file
      echo "Backing up the existing network configuration file..."
      cp /backup/mnt/etc/NetworkManager/system-connections/enp1s0.nmconnection /backup/mnt/etc/NetworkManager/system-connections/enp1s0.nmconnection.bak
      
      CONFIG_FILE="/backup/mnt/etc/NetworkManager/system-connections/enp1s0.nmconnection"
      # Modify the network configuration file
      echo "Modifying the network configuration file..."
      echo " "
      sed -i '/\[ipv4\]/,/^$/ { /^method=auto$/d; }' $CONFIG_FILE
      sed -i '/\[ipv4\]/!b;n;a method=manual' $CONFIG_FILE
      sed -i '/\[ipv4\]/!b;n;n;a addresses='"$new_ip"'/24;'"$new_gateway"'' $CONFIG_FILE
      sed -i '/\[ipv4\]/!b;n;n;n;a dns=8.8.8.8;8.8.4.4;\nignore-auto-dns=true' $CONFIG_FILE

      echo " " 

      # Verify the changes
      echo "Verifying the changes in the network configuration file..."
      cat /backup/mnt/etc/NetworkManager/system-connections/enp1s0.nmconnection

    else
      echo "Error: Network configuration file not found."
      umount /backup/mnt
      exit 1
    fi

    # Unmount and clean up
    echo "Unmounting and cleaning up..."
    umount /backup/mnt || true
    kpartx -d /dev/loop0 || true
    losetup -d /dev/loop0 || true

    echo "Network configuration updated successfully."

  elif [ "$OS_type" == "alpine" ]; then
    # Clean up any existing loop devices before setting up the new one
    cleanup_loop_devices

    losetup -Pf "$merged_backup_file"

    # Create device mappings
    echo "Creating partition mappings with kpartx..."
    kpartx -av /dev/loop0

    # Identify and mount root partition
    root_partition_found=false
    for partition in /dev/mapper/loop0p*; do
      echo "Checking partition $partition..."
      fs_type=$(blkid -o value -s TYPE "$partition")
      echo "Filesystem type of $partition is $fs_type"
      if [ "$fs_type" == "vfat" ]; then
        mount -t vfat "$partition" /backup/mnt || continue
      elif [ "$fs_type" == "swap" ]; then
        echo "$partition is a swap partition, skipping..."
        continue
      elif [ "$fs_type" == "ext4" ]; then
        mount -t ext4 "$partition" /backup/mnt || continue
      else
        mount -t auto "$partition" /backup/mnt || continue
      fi

      if [ -d /backup/mnt/etc ]; then
        echo "Found root partition: $partition"
        root_partition_found=true
        break
      else
        umount /backup/mnt
      fi
    done

    if [ "$root_partition_found" = false ]; then
      echo "Error: Root partition not found"
      exit 1
    fi

    # Check file permissions before modification
    echo "File permissions before modification:"
    ls -l /backup/mnt/etc/network/interfaces

    # Display the content of the file before modification
    echo "Content of /etc/network/interfaces before modification:"
    cat /backup/mnt/etc/network/interfaces

    # Modify network configuration
    echo "Backing up and writing new network configuration..."
    cp /backup/mnt/etc/network/interfaces /backup/mnt/etc/network/interfaces.bak
    echo "auto eth0
iface eth0 inet static
  address $new_ip
  netmask $new_netmask
  gateway $new_gateway" > /backup/mnt/etc/network/interfaces

    # Verify the change
    echo "Updated network configuration:"
    cat /backup/mnt/etc/network/interfaces

    # Unmount and clean up
    echo "Unmounting and cleaning up..."
    umount /backup/mnt || true
    kpartx -d /dev/loop0 || true
    losetup -d /dev/loop0 || true

    echo "Network configuration updated successfully."
  else
    echo "Unsupported OS type: $OS_type"
    exit 1
  fi
}

reverse_replication() {
  echo "Starting Reverse Replication process..."

log_trace "  Starting Reverse Replication process..."
log_events " Starting Reverse Replication process... "


  # Define the new backup file path
  new_backup_file="/backup/Full_backup_${vm_name}_Recovered_${date_input}_${time_input}.raw"

  # Copy and rename the merged backup file
  cp "$merged_backup_file" "$new_backup_file"

# Get the size of the new backup file
  new_backup_size=$(stat -c%s "$new_backup_file")
  new_backup_size_mb=$(awk "BEGIN {printf \"%.2f\", ${new_backup_size}/(1024*1024)}")

  # Sanitize restored_vm_id
  sanitized_restored_vm_id=$(echo "$restored_vm_id" | sed 's/[^a-zA-Z0-9_]//g')

  # Making sure correct checkpoint copied for first Incremental in new table
  echo "Finding Checkpoint mark for Restore Date: $date_input  and Time: $time_input"
  checkpoint=$(sqlite3 "$backup_index_db" "SELECT Checkpoint FROM $sanitized_tablename WHERE Date='$date_input' AND Time<='$time_input' ORDER BY Date DESC, Time DESC LIMIT 1;")
  echo " "
  echo "SETTING CHECKPOINT for INCREMENTAL INITIAL RUN : $checkpoint"
  echo " "

  # Execute the reverse replication SQL commands
  sqlite3 "$backup_index_db" <<EOF
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS table_BI_$sanitized_restored_vm_id (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_id TEXT,
    vm_name TEXT,
    disk_id TEXT,
    Full_Backup INTEGER,
    Backup_path TEXT,
    Checkpoint TEXT,
    Time TEXT,
    Date TEXT,
    Status TEXT,
    Duration TEXT,
    Size TEXT
);


#INSERT INTO table_BI_$sanitized_restored_vm_id (Full_Backup, Checkpoint, Date, Time, Backup_path, VM_Name, VM_ID, Disk_ID, Status) VALUES (1, '$checkpoint', '$date_input', '$time_input', '$new_backup_file', '$restored_vm_name', '$restored_vm_id', '$new_disk_id', 'Full Backup Ready for RR');
#INSERT INTO table_BI_$sanitized_vm_id (Full_Backup, Checkpoint, Date, Time, Backup_path, VM_ID, Disk_ID, Status, Duration, Size) VALUES (1010, '$checkpoint', '$date_input', '$time_input', '$new_backup_file', '$restored_vm_id', '$new_disk_id', 'Waiting for Failback', '0', '0.0');
INSERT INTO table_BI_$sanitized_restored_vm_id (Full_Backup, Checkpoint, Date, Time, Backup_path, VM_Name, VM_ID, Disk_ID, Status, Duration, Size) VALUES (1, '$checkpoint', '$date_input', '$time_input', '$new_backup_file', '$restored_vm_name', '$restored_vm_id', '$new_disk_id', 'Full Backup Ready for RR', '0', '$new_backup_size_mb');
INSERT INTO table_BI_$sanitized_vm_id (Full_Backup, Checkpoint, Date, Time, Backup_path, VM_ID, Disk_ID, Status, Duration, Size) VALUES (1010, '$checkpoint', '$date_input', '$time_input', '$new_backup_file', '$restored_vm_id', '$new_disk_id', 'Waiting for Failback', '0', '$new_backup_size_mb');

COMMIT;
EOF

  echo "Reverse Replication process completed."

log_trace "  Reverse Replication process completed."
log_events "  Reverse Replication process completed."

  # Display the contents of both tables
  echo "#######################################"
  echo "# Table: table_BI_$sanitized_restored_vm_id #"
  echo "#######################################"
  sqlite3 "$backup_index_db" ".headers on" ".mode column" "SELECT * FROM table_BI_$sanitized_restored_vm_id;"

  echo "#######################################"
  echo "# Table: table_BI_$sanitized_vm_id #"
  echo "#######################################"
  sqlite3 "$backup_index_db" ".headers on" ".mode column" "SELECT * FROM table_BI_$sanitized_vm_id;"
}

# The new function migrate_checkpoint
migrate_checkpoint() {
  echo "Starting checkpoint migration..."

log_trace "  Starting checkpoint migration...."
log_events " Starting checkpoint migration..."

  # Variables
  SOURCE_DB_HOST="engine.local"
  SOURCE_DB_NAME="engine"
  SOURCE_DB_USER="root"  # root user for SSH
  SOURCE_DB_ENGINE_USER="engine"  # engine user for PostgreSQL
  SOURCE_DB_PASSWORD=$(ssh root@engine.local "grep 'ENGINE_DB_PASSWORD' /etc/ovirt-engine/engine.conf.d/10-setup-database.conf | cut -d'=' -f2 | tr -d '\"'")
  SOURCE_VM_ID="${vm_id_input}"  # Source VM ID

  DR_DB_HOST="dr.local"
  DR_DB_NAME="engine"
  DR_DB_USER="root"  # root user for SSH
  DR_DB_ENGINE_USER="engine"  # engine user for PostgreSQL
  DR_DB_PASSWORD=$(ssh root@dr.local "grep 'ENGINE_DB_PASSWORD' /etc/ovirt-engine/engine.conf.d/10-setup-database.conf | cut -d'=' -f2 | tr -d '\"'")
  DR_VM_ID="${restored_vm_id}"  # Corrected DR VM ID
  DR_API_URL="https://dr.local/ovirt-engine/api"
  DR_API_USER="admin@internal"
  DR_API_PASSWORD="password"  # DR API password

  CSV_FILE="/tmp/vm_checkpoints.csv"
  SQL_FILE="/tmp/vm_checkpoints_inserts.sql"

  echo "Source VM ID: ${SOURCE_VM_ID}"
  echo "DR VM ID: ${DR_VM_ID}"

  # Step 1: Extract checkpoint data from the source server
  echo "Extracting checkpoint data from the source server..."
  ssh ${SOURCE_DB_USER}@${SOURCE_DB_HOST} <<EOF
export PGPASSWORD=${SOURCE_DB_PASSWORD}
export PATH=\$PATH:/usr/pgsql-13/bin  # Update PATH if necessary
psql -U ${SOURCE_DB_ENGINE_USER} -h localhost -d ${SOURCE_DB_NAME} -c "\\copy (SELECT * FROM vm_checkpoints WHERE vm_id = '${SOURCE_VM_ID}') TO '${CSV_FILE}' CSV HEADER;"
EOF

  # Step 2: Transfer the CSV file to kvmdr
  echo "Transferring CSV file to kvmdr..."
  scp ${SOURCE_DB_USER}@${SOURCE_DB_HOST}:${CSV_FILE} ${CSV_FILE}

  # Step 3: Generate SQL insert statements on kvmdr
  echo "Generating SQL insert statements on kvmdr..."
  cat << EOL > /tmp/create_sql_inserts.sh
#!/bin/bash
csv_file="/tmp/vm_checkpoints.csv"
sql_file="/tmp/vm_checkpoints_inserts.sql"
new_vm_id="${DR_VM_ID}"

echo "BEGIN;" > \$sql_file

while IFS=, read -r checkpoint_id parent_id vm_id _create_date state description
do
  if [ "\$checkpoint_id" != "checkpoint_id" ]; then  # Skip header
    if [ -z "\$parent_id" ]; then
      parent_id="NULL"
    else
      parent_id="'\$parent_id'"
    fi
    echo "INSERT INTO vm_checkpoints (checkpoint_id, parent_id, vm_id, _create_date, state, description) VALUES ('\$checkpoint_id', \$parent_id, '\$new_vm_id', '\$_create_date', '\$state', '\$description');" >> \$sql_file
  fi
done < \$csv_file

echo "COMMIT;" >> \$sql_file
EOL

  chmod +x /tmp/create_sql_inserts.sh
  /tmp/create_sql_inserts.sh

  # Step 4: Transfer the SQL file to the DR server
  echo "Transferring SQL file to the DR server..."
  scp ${SQL_FILE} ${DR_DB_USER}@${DR_DB_HOST}:${SQL_FILE}

  # Step 5: Insert checkpoint data into the DR server's database
  echo "Inserting checkpoint data into the DR server's database..."
  ssh ${DR_DB_USER}@${DR_DB_HOST} <<EOF
export PGPASSWORD=${DR_DB_PASSWORD}
psql -U ${DR_DB_ENGINE_USER} -h localhost -d ${DR_DB_NAME} -f ${SQL_FILE}
EOF

  # Step 6: Verify checkpoints on the DR server using the oVirt API
  echo "Verifying checkpoints on the DR server..."

# Make sure the bearer token is available
if [ -z "$bearer_Token" ]; then
  echo "Error: Bearer token is missing."
  exit 1
fi

RESPONSE=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$DR_API_URL/vms/$DR_VM_ID/checkpoints")

# Check if the response is valid
if echo "$RESPONSE" | grep -q "<error>"; then
  echo "Error: API request failed. Response: $RESPONSE"
  exit 1
fi

echo "API Response: $RESPONSE"
  echo " "
  echo "Checkpoint Migration Process completed successfully!"
  echo " "
}

# New function to delete source checkpoints
delete_source_checkpoint() {
  echo " "
  echo "Starting deletion of source checkpoints..."
  echo " "

log_trace " Starting deletion of source checkpoints... "
log_events " Starting deletion of source checkpoints..."


  url_Engine="https://engine.local/ovirt-engine"
  url_getToken="$url_Engine/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"

  # Fetch oVirt API token
  echo "Fetching oVirt API token..."
  bearer_Token=$(curl -s -k --header Accept:application/json "$url_getToken" | jq -r '.access_token')
  if [ -z "$bearer_Token" ]; then
    echo "Error: Failed to fetch oVirt API token."
    exit 1
  fi
  echo "Token fetched"

  # Define variables
  OVIRT_ENGINE_URL="https://engine.local"
  VM_ID=$vm_id_input
  CHECKPOINTS_URL="$OVIRT_ENGINE_URL/ovirt-engine/api/vms/$VM_ID/checkpoints"

  # Get list of checkpoints and print the raw XML response for debugging
  RESPONSE=$(curl -s -k -H "Authorization: Bearer $bearer_Token" -H "Content-Type: application/json" "$CHECKPOINTS_URL")
  echo "Response from server: $RESPONSE"

  # Validate if the response is valid XML and extract checkpoint IDs
  CHECKPOINTS=$(echo "$RESPONSE" | xmlstarlet sel -t -v "//checkpoint/@id")

  # Check if there are any checkpoints to delete
  if [ -z "$CHECKPOINTS" ]; then
      echo "No checkpoints found."
      exit 0
  fi

  echo "Checkpoints found: $CHECKPOINTS"

  # Delete each checkpoint
  for CHECKPOINT_ID in $CHECKPOINTS; do
      echo "Deleting checkpoint $CHECKPOINT_ID..."
      DELETE_URL="$CHECKPOINTS_URL/$CHECKPOINT_ID"
      DELETE_RESPONSE=$(curl -s -k -X DELETE \
           -H "Content-Type: application/json" \
           -H "Authorization: Bearer $bearer_Token" \
           "$DELETE_URL")
      echo "Response from deleting checkpoint $CHECKPOINT_ID: $DELETE_RESPONSE"
  done

  echo "All checkpoints deleted."

log_trace " All checkpoints deleted"
log_events "All checkpoints deleted"

}

init_restore() {
  echo "#######################################"
  echo "# Starting Restore                    #"
  echo "#######################################"

log_trace " Starting Restore"
log_events "Starting Restore "

  # Fetch oVirt API token
  echo "Fetching oVirt API token..."
  bearer_Token=$(curl -s -k --header Accept:application/json "$url_getToken" | jq -r '.access_token')
  if [ -z "$bearer_Token" ]; then
    echo "Error: Failed to fetch oVirt API token."
    exit 1
  fi
  echo "Token fetched"

  # Query for the VM name
  echo "Querying VM name from Backup_Index database..."
  vm_name=$(sqlite3 "$backup_index_db" "SELECT vm_name FROM $sanitized_tablename LIMIT 1;")
  if [ -z "$vm_name" ]; then
    echo "Error: Failed to fetch VM name."
    exit 1
  fi
  echo "VM name: $vm_name"

  echo "Executing SQL Query to fetch full backup path..."
  full_backup_file=$(sqlite3 "$backup_index_db" "SELECT Backup_path FROM $sanitized_tablename WHERE Full_Backup=1 LIMIT 1;")
  if [ -z "$full_backup_file" ]; then
    echo "Error: No full backup file found!"
    exit 1
  fi
  echo "Full backup file found: $full_backup_file"

  # Check if Full_Backup is set to 1
  full_backup=$(sqlite3 "$backup_index_db" "SELECT Full_Backup FROM $sanitized_tablename WHERE Backup_path='$full_backup_file' LIMIT 1;")
  if [ "$full_backup" == "1" ]; then
    echo "Full backup detected. Copying the backup file..."

    temp_dir="/backup/tmp"
    mkdir -p "$temp_dir"
    merged_backup_file="$temp_dir/Merged_backup_${sanitized_vm_id}_$(date +%Y%m%d_%H%M%S).raw"
    qcow2_file="$temp_dir/Merged_backup_${sanitized_vm_id}_$(date +%Y%m%d_%H%M%S).qcow2"

log_trace " Copying the full backup file to the temporary directory..." 
log_events " Copying the full backup file to the temporary directory... "


    # Copy the full backup file to the temporary directory
    echo "Copying the full backup file to the temporary directory..."
    cp "$full_backup_file" "$merged_backup_file"
    if [ $? -ne 0 ]; then
      echo "Error: Failed to copy the full backup file."
      exit 1
    fi
  fi

  echo "Creating a temporary table for the restore session..."
  sqlite3 "$backup_index_db" "CREATE TABLE IF NOT EXISTS $restore_session_table (Date TEXT, Time TEXT, Checkpoint TEXT, FilePath TEXT);"

  echo "Finding Checkpoints for the given date and time..."
  checkpoints=$(sqlite3 "$backup_index_db" "SELECT date, time, Checkpoint, Backup_path FROM $sanitized_tablename WHERE datetime(Date || ' ' || Time) <= datetime('$date_input $time_input') AND (Full_Backup=0 OR Full_Backup=25) ORDER BY datetime(Date || ' ' || Time) ASC;")

  if [ -z "$checkpoints" ]; then
    echo "No checkpoints found for the given date and time. Proceeding without checkpoints..."
  else
    echo "#############################################"
    echo "#  List of Incrementals sorted by Date, Time and Checkpoint  #"
    echo "#############################################"
    total_length=0
    total_zero_length=0
    total_dirty_length=0
    while IFS="|" read -r date time checkpoint_id incremental_files; do
      echo "Date: $date"
      echo "Time: $time"
      echo "Checkpoint: $checkpoint_id"
      echo "Files:"
      for file in $(echo "$incremental_files" | tr ',' '\n'); do
        echo "  - $file"
        sqlite3 "$backup_index_db" "INSERT INTO $restore_session_table (Date, Time, Checkpoint, FilePath) VALUES ('$date', '$time', '$checkpoint_id', '$file');"
      done

      # Calculate the total length for the current checkpoint
      checkpoint_length=$(sqlite3 "$backup_index_db" "SELECT SUM(Length) FROM $incremental_table WHERE Checkpoint='$checkpoint_id';")
      total_length=$((total_length + checkpoint_length))

      # Calculate the total zero length for the current checkpoint
      zero_length=$(sqlite3 "$backup_index_db" "SELECT SUM(Length) FROM $incremental_table WHERE Checkpoint='$checkpoint_id' AND Zero='true';")
      total_zero_length=$((total_zero_length + zero_length))

      # Calculate the total dirty length for the current checkpoint
      dirty_length=$(sqlite3 "$backup_index_db" "SELECT SUM(Length) FROM $incremental_table WHERE Checkpoint='$checkpoint_id' AND Dirty='true';")
      total_dirty_length=$((total_dirty_length + dirty_length))
    done <<< "$checkpoints"

    echo "Total length of all extents: $total_length bytes"
    echo "Total zero length: $total_zero_length bytes"
    echo "Total dirty length: $total_dirty_length bytes"
    IFS=$'\n'

    # Echo the restore table before processing
    echo "#######################################"
    echo "# Restore Session Table              #"
    echo "#######################################"
    sqlite3 "$backup_index_db" "SELECT * FROM $restore_session_table;"

log_trace " Processing each incremental backup"
log_events " Processing each incremental backup "


    # Process each incremental backup
    checkpoints=$(sqlite3 "$backup_index_db" "SELECT DISTINCT Checkpoint FROM $restore_session_table ORDER BY Date, Time;")
    for checkpoint_id in $checkpoints; do
      echo "Processing checkpoint $checkpoint_id"
      incremental_files=$(sqlite3 "$backup_index_db" "SELECT FilePath FROM $restore_session_table WHERE Checkpoint='$checkpoint_id';")
      echo "Files for checkpoint $checkpoint_id:"
      echo "$incremental_files"

      echo "Reading and applying extent metadata from database for checkpoint $checkpoint_id..."

      # Read the incremental metadata from the database and apply the changes
      sql_query="SELECT Start, Length, Dirty, Zero FROM $incremental_table WHERE Checkpoint='$checkpoint_id' ORDER BY Date ASC, Time ASC;"
      sqlite3 "$backup_index_db" "$sql_query" | while IFS='|' read -r start length dirty zero; do
        # Trim whitespace from each field
        start=$(echo "$start" | xargs)
        length=$(echo "$length" | xargs)
        dirty=$(echo "$dirty" | xargs)
        zero=$(echo "$zero" | xargs)

        # Skip lines that are empty or contain only pipes
        if [ -z "$start" ] || [ -z "$length" ]; then
            echo "Skipping invalid extent with missing start or length."
            continue
        fi

        # Debugging: Print each field after trimming to ensure correct parsing
        echo "start: '$start'"
        echo "length: '$length'"
        echo "dirty: '$dirty'"
        echo "zero: '$zero'"

        if [ "$zero" == "true" ]; then
            echo "Zeroing extent at offset $start with length $length"
            dd if=/dev/zero of="$merged_backup_file" bs=64K seek=$(($start / 65536)) count=$(($length / 65536)) conv=notrunc status=progress
        elif [ "$dirty" == "true" ]; then
            for file in $(echo "$incremental_files" | tr ',' ' '); do
              incremental_file=$(echo "$file" | xargs) # Trim whitespace from file path
              if [[ "$incremental_file" == *"${start}_${length}.raw" ]]; then
                if [ -f "$incremental_file" ]; then
                    echo "Applying incremental changes from $incremental_file at offset $start with length $length"
                    dd if="$incremental_file" of="$merged_backup_file" bs=64K seek=$(($start / 65536)) conv=notrunc status=progress
                else
                    echo "Incremental file not found: $incremental_file"
                fi
              fi
            done
        fi
      done
    done
    unset IFS

    # Display the combined list of incremental files and their total size
    echo "#######################################"
    echo "#  Combined Incremental Files Details #"
    echo "#######################################"
    incremental_file_paths=$(sqlite3 "$backup_index_db" "SELECT FilePath FROM $restore_session_table;" | tr '\n' ' ')
    echo "$incremental_file_paths" | tr ' ' '\n'
    total_size=$(du -ch $(echo "$incremental_file_paths" | tr ' ' '\n' | grep -v "$full_backup_file") | grep total$ | awk '{print $1}')
    total_size_bytes=$(du -cb $(echo "$incremental_file_paths" | tr ' ' '\n' | grep -v "$full_backup_file") | grep total$ | awk '{print $1}')
    total_size_mb=$(awk "BEGIN {printf \"%.2f\", ${total_size_bytes}/(1024*1024)}")
    echo "Total size of all incremental files (excluding full backup): ${total_size_mb} MB"

    # Calculate and display deduplication ratio
    total_incremental_data_mb=$(awk "BEGIN {printf \"%.2f\", (${total_zero_length} + ${total_dirty_length}) / (1024*1024)}")
    if [ $total_length -ne 0 ]; then
      deduplication_ratio=$(awk "BEGIN {printf \"%.2f\", ($total_zero_length + $total_dirty_length) / $total_size_bytes * 100}")
    else
      deduplication_ratio="N/A"
    fi
    echo "Total size of all incremental data: ${total_incremental_data_mb} MB"
    echo "Total size of incremental files (after deduplication): ${total_size_mb} MB"
    echo "Deduplication Savings Ratio: ${deduplication_ratio}%"
  fi

# Modify the network configuration before converting to QCOW2
  modify_network_configuration
  
log_trace " Modify the network configuration before converting to QCOW2"
log_events " Modify the network configuration before converting to QCOW2 "


  # Convert the merged raw file to QCOW2 format
  echo "Converting the merged raw backup file to QCOW2 format..."

log_trace " Converting the merged raw backup file to QCOW2 format..."
log_events " Converting the merged raw backup file to QCOW2 format... "



  # Set the status file for conversion progress
  status_file_convert="/backup/status/${vm_id_input}/restore_convert_status.txt"
  mkdir -p "$(dirname "$status_file_convert")"
  if [ -f "$status_file_convert" ]; then
    rm "$status_file_convert"
  fi

  # Measure and log the time taken for the conversion
  start_conversion_time=$(date +%s)

  # Perform the conversion and log progress
  if [ "$compression" == "on" ]; then
    echo "Compression is enabled. Turbo will be on."
    echo "Compression is enabled. Converting using dedicated CPU cores and high I/O priority."
    { time taskset -c 0-3 ionice -c 2 -n 0 qemu-img convert -p -f raw -O qcow2 -o cluster_size=2M -c "$merged_backup_file" "$qcow2_file" | tee "$status_file_convert"; } 2>&1 | tee -a "$status_file_convert"
  elif [ "$compression" == "off" ] && [ "$turbo" == "off" ]; then
    echo "Compression is not enabled. Turbo is off."
    echo "Compression is not enabled. Converting without dedicated CPU cores or high I/O priority."
    { time qemu-img convert -p -f raw -O qcow2 -o cluster_size=2M "$merged_backup_file" "$qcow2_file" | tee "$status_file_convert"; } 2>&1 | tee -a "$status_file_convert"
  elif [ "$compression" == "off" ] && [ "$turbo" == "on" ]; then
    echo "Compression is not enabled. Turbo is on."
    echo "Compression is not enabled. Converting using dedicated CPU cores and high I/O priority."
    { time taskset -c 0-3 ionice -c 2 -n 0 qemu-img convert -p -f raw -O qcow2 -o cluster_size=2M "$merged_backup_file" "$qcow2_file" | tee "$status_file_convert"; } 2>&1 | tee -a "$status_file_convert"
  fi

  end_conversion_time=$(date +%s)
  conversion_time=$((end_conversion_time - start_conversion_time))

  # Log time taken for conversion
  echo "Time taken for conversion: $conversion_time seconds" | tee -a "$status_file_convert"

  echo "QCOW2 conversion completed: $qcow2_file"

  # Print file sizes and paths
  merged_backup_size=$(stat -c%s "$merged_backup_file")
  qcow2_backup_size=$(stat -c%s "$qcow2_file")
  merged_backup_size_mb=$(awk "BEGIN {printf \"%.2f\", ${merged_backup_size}/(1024*1024)}")
  qcow2_backup_size_mb=$(awk "BEGIN {printf \"%.2f\", ${qcow2_backup_size}/(1024*1024)}")
  echo "Full backup file: $full_backup_file"
  echo "Merged backup file: $merged_backup_file"
  echo "QCOW2 backup file: $qcow2_file"
  echo "Merged backup file size: ${merged_backup_size_mb} MB"
  echo "QCOW2 backup file size: ${qcow2_backup_size_mb} MB"

  # Calculate and display compression saving ratio and savings in GB
  compression_saving_ratio=$(awk "BEGIN {printf \"%.2f\", (${merged_backup_size}/${qcow2_backup_size})*100}")
  compression_savings_gb=$(awk "BEGIN {printf \"%.2f\", (${merged_backup_size} - ${qcow2_backup_size}) / (1024*1024*1024)}")
  echo "Compression Saving Ratio: ${compression_saving_ratio}%"
  echo "Compression Savings: ${compression_savings_gb} GB"

log_trace " Create a new disk in the storage domain hosted_storage with the correct virtual size"
log_events "  Create a new disk in the storage domain hosted_storage with the correct virtual size"

  # Create a new disk in the storage domain hosted_storage with the correct virtual size
  echo "Creating a new disk in the storage domain hosted_storage..."
  virtual_size=$(qemu-img info --output=json "$qcow2_file" | jq -r '.["virtual-size"]')
  new_disk_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<disk>
              <name>restore_disk</name>
              <format>cow</format>
              <provisioned_size>$virtual_size</provisioned_size>
              <sparse>true</sparse>
              <bootable>true</bootable>
              <storage_domains>
                <storage_domain>
                  <name>hosted_storage</name>
                </storage_domain>
              </storage_domains>
           </disk>" \
       "$url_Engine/api/disks")
  echo "Disk creation response: $new_disk_response"
  new_disk_id=$(echo "$new_disk_response" | xmlstarlet sel -t -v "//disk/@id")
  echo "Created new disk with ID: $new_disk_id"
  log_trace "Created new disk with ID: $new_disk_id"

  # Wait until disk status is OK
  while true; do
    disk_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/disks/$new_disk_id" | xmlstarlet sel -t -v "//disk/status")
    echo "Disk status: $disk_status"
    if [[ "${disk_status,,}" == "ok" ]]; then
      break
    fi
    echo "Waiting for disk to be ready..."
    sleep 5
  done

log_trace " Enable incremental backup for the newly uploaded QCOW2 disk"
log_events " Enable incremental backup for the newly uploaded QCOW2 disk"

  # Enable incremental backup for the newly uploaded QCOW2 disk
  echo "Enabling incremental backup for the new QCOW2 disk..."
  enable_backup_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<disk>
              <backup>incremental</backup>
           </disk>" \
       "$url_Engine/api/disks/$new_disk_id")
  echo "Incremental backup enable response: $enable_backup_response"

  # Ensure the disk is unlocked before starting the image transfer
  while true; do
    disk_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/disks/$new_disk_id" | xmlstarlet sel -t -v "//disk/status")
    echo "Disk status: $disk_status"
    if [[ "${disk_status,,}" != "locked" ]]; then
      break
    fi
    echo "Waiting for disk to be unlocked..."
    sleep 5
  done

  # Create a new VM with the original VM name and _Recovered suffix
  restored_vm_name="${vm_name}_Recovered_$timestamp"
  echo "Creating a new VM with name $restored_vm_name..."
  create_vm_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<vm>
              <name>$restored_vm_name</name>
              <cluster>
                <name>Default</name>
              </cluster>
              <template>
                <name>Blank</name>
              </template>
              <os>
                <type>other</type>
              </os>
              <cpu>
                <topology>
                  <cores>2</cores>
                  <sockets>1</sockets>
                </topology>
              </cpu>
              <memory>4294967296</memory>
              <high_availability>
                <enabled>false</enabled>
              </high_availability>
              <stateless>false</stateless>
              <display>
                <type>vnc</type>
              </display>
              <storage_error_resume_behaviour>auto_resume</storage_error_resume_behaviour>
           </vm>" \
       "$url_Engine/api/vms")
  echo "VM creation response: $create_vm_response"
  restored_vm_id=$(echo "$create_vm_response" | xmlstarlet sel -t -v "//vm/@id")
  echo "Created new VM with ID: $restored_vm_id"

  # Wait until the VM is down
  while true; do
    vm_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$restored_vm_id" | xmlstarlet sel -t -v "//vm/status")
    echo "VM status: $vm_status"
    if [[ "${vm_status,,}" == "down" ]]; then
      break
    fi
    echo "Waiting for VM to be in down state..."
    sleep 5
  done

log_trace "  Create an image transfer to upload the QCOW2 file"
log_events "  Create an image transfer to upload the QCOW2 file"

  # Create an image transfer to upload the QCOW2 file
  echo "Creating an image transfer to upload the QCOW2 file..."
  image_transfer_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<image_transfer>
              <disk id='$new_disk_id' />
              <direction>upload</direction>
              <format>cow</format>
           </image_transfer>" \
       "$url_Engine/api/imagetransfers")
  echo "Image transfer creation response: $image_transfer_response"

  transfer_id=$(echo "$image_transfer_response" | xmlstarlet sel -t -v "//image_transfer/@id")
  transfer_proxy_url=$(echo "$image_transfer_response" | xmlstarlet sel -t -v "//image_transfer/proxy_url")
  echo "Created image transfer with ID: $transfer_id"
  echo "Transfer proxy URL: $transfer_proxy_url"

  # Upload QCOW2 file using ImageIO API
  echo "Uploading QCOW2 file to the new disk..."
  status_file="/backup/status/$vm_id_input/restore_upload_status.txt"
  mkdir -p "$(dirname "$status_file")"
  if [ -f "$status_file" ]; then
    rm "$status_file"
  fi

 # Start the progress logging in the background
  {
    while :; do
      echo "$(date +'%Y-%m-%d %H:%M:%S') - Upload in progress..." >> "$status_file"
      sleep 5
    done
  } &
  progress_pid=$!

  # Perform the upload and log the progress
  {
    curl -k --progress-bar --upload-file "$qcow2_file" "$transfer_proxy_url"
  } 2>&1 | tee -a "$status_file"

  # Explicitly kill the background logging loop after upload completes
  kill $progress_pid
  trap - EXIT

  echo " "
  echo "Upload response logged to: $status_file" | tee -a "$status_file"
  echo " "

log_trace "Finalize Image Transfer"
log_events " Finalize Image Transfer"


  # Finalize Image Transfer
  echo "Finalizing the image transfer..."
  finalize_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<action />" \
       "$url_Engine/api/imagetransfers/$transfer_id/finalize")
  echo "Finalize response: $finalize_response"

  # Ensure Disk is Ready for Attachment
  echo "Ensuring the disk is fully ready before attachment..."
  while true; do
    disk_transfer_phase=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" \
      "$url_Engine/api/imagetransfers/$transfer_id" | xmlstarlet sel -t -v "//image_transfer/phase")
    echo "Disk transfer phase: $disk_transfer_phase"
    if [[ "${disk_transfer_phase,,}" == "finished_success" ]]; then
      break
    fi
    echo "Waiting for disk transfer to finish..."
    sleep 5
  done

  # Ensure disk is not locked before attaching
  echo "Checking disk status before attachment..."
  while true; do
    disk_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/disks/$new_disk_id" | xmlstarlet sel -t -v "//disk/status")
    echo "Disk status: $disk_status"
    if [[ "${disk_status,,}" == "ok" ]]; then
      break
    fi
    echo "Waiting for disk to be ready for attachment..."
    sleep 5
  done

  # Attach the disk to the VM
  echo "Attaching the new disk to the new VM..."
  disk_attachment_data="<disk_attachment>
                          <bootable>true</bootable>
                          <interface>virtio_scsi</interface>
                          <active>true</active>
                          <disk id='$new_disk_id' />
                        </disk_attachment>"

  attach_disk_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
    -d "$disk_attachment_data" "$url_Engine/api/vms/$restored_vm_id/diskattachments")
  echo "Disk attachment response: $attach_disk_response"
  log_trace "Attached disk $new_disk_id to VM $restored_vm_id"

  # Get vNIC profile ID for 'ovirtmgmt'
  echo "Fetching vNIC profile ID for 'ovirtmgmt'..."
  vnic_profile_id=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" \
       "$url_Engine/api/vnicprofiles" | xmlstarlet sel -t -m "//vnic_profile[name='ovirtmgmt']" -v "@id")
  if [ -z "$vnic_profile_id" ]; then
    echo "Error: vNIC profile 'ovirtmgmt' not found."
    exit 1
  fi
  echo "vNIC profile ID for 'ovirtmgmt': $vnic_profile_id"

  # Add Network Interface to the VM with vNIC profile 'ovirtmgmt'
  echo "Adding network interface to the new VM with vNIC profile 'ovirtmgmt'..."
  nic_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<nic>
              <name>nic1</name>
              <vnic_profile id='$vnic_profile_id'/>
              <interface>virtio</interface>
           </nic>" \
       "$url_Engine/api/vms/$restored_vm_id/nics")
  echo "Network interface creation response: $nic_response"
  nic_id=$(echo "$nic_response" | xmlstarlet sel -t -v "//nic/@id")
  echo "Added network interface with ID: $nic_id to VM: $restored_vm_id"

log_trace "Activate the Network Interface  "
log_events "Activate the Network Interface"


  # Activate the Network Interface
  echo "Activating the network interface..."
  activate_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<action />" \
       "$url_Engine/api/vms/$restored_vm_id/nics/$nic_id/activate")
  echo "Network interface activation response: $activate_response"
  log_trace "Network interface activation response: $activate_response"

  # Perform reverse replication if needed
  if [ "$reverseReplicationStatus" == "on" ]; then
    reverse_replication
  else
    echo "No Reverse Replication Requirement, proceed with new Full backup"
  fi

 
log_trace "Migrate Checkpoint  "
log_events "Migrate Checkpoint "

 # Insert migrate_checkpoint function call here
  migrate_checkpoint

log_trace "Delete Source Checkpoint  "
log_events "Delete Source Checkpoint "

# After  migrate_checkpoint call, add the delete_source_checkpoint function call
# delete_source_checkpoint 

log_trace " Clean up temporary files "
log_events " Clean up temporary files "

  # Clean up temporary files
  clean

  # Final step: Logging completion
  log_events "Restore process completed successfully for VM ID $vm_id_input and incremental backup enabled."
  echo "Restore process completed successfully!"
  dmsetup remove_all
}

# The new function for renaming recovered VM

rename_recovered_vm() {
    restored_vm_id="$1"
    echo " "
    echo " Restored VM ID:  $restored_vm_id"  
    echo " "

 
    # Define variables
    url_Engine_original="https://engine.local/ovirt-engine"
    url_getToken_original="$url_Engine_original/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"

    # Fetch oVirt API token for original VM
    echo "Fetching oVirt API token for original VM..."
    bearer_Token_original=$(curl -s -k --header Accept:application/json "$url_getToken_original" | jq -r '.access_token')

    if [ -z "$bearer_Token_original" ]; then
        echo "Error: Failed to fetch oVirt API token for original VM."
        exit 1
    fi
    echo "Token fetched for original VM."

    # Get the vm_name for original_vmid using oVirt API
    echo "Getting VM name for original_vmid: $original_vmid"
    response=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token_original" "$url_Engine_original/api/vms/$original_vmid")
    vm_name=$(echo $response | jq -r '.name')
    if [[ -z "$vm_name" || "$vm_name" == "null" ]]; then
        echo "Error: Failed to get VM name for original_vmid: $original_vmid"
        exit 1
    fi
    echo "Original VM Name: $vm_name"

    # Shutdown the original_vmid
    echo "Sending shutdown command to original VM: $original_vmid"
    shutdown_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token_original" -d "<action/>" "$url_Engine_original/api/vms/$original_vmid/shutdown")

    # Echo the full shutdown response for troubleshooting
    echo "Shutdown response: $shutdown_response"

    # Check if the shutdown command was successful
    if [[ "$shutdown_response" == *"<fault>"* ]]; then
        echo "Error: Failed to send shutdown command to the original VM."
        exit 1
    fi

    # Wait for the VM to shut down by checking its status
    echo "Waiting for the VM to shut down..."
    while true; do
        status_response=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token_original" "$url_Engine_original/api/vms/$original_vmid")
        
        # Echo the status response for troubleshooting
        echo "Status response: $status_response"

        vm_status=$(echo $status_response | jq -r '.status')
        if [[ "$vm_status" == "down" ]]; then
            break
        fi
        echo "VM status is $vm_status, waiting for it to shut down..."
        sleep 5
    done
    echo "VM is shut down."

    # Rename the original VM to vm_name_old after shutdown
    echo "Renaming original VM to ${vm_name}_old"
    rename_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token_original" -d "<vm><name>${vm_name}_old</name></vm>" "$url_Engine_original/api/vms/$original_vmid")
    if [[ "$rename_response" == *"<fault>"* ]]; then
        echo "Error: Failed to rename the original VM."
        exit 1
    fi
    echo "Original VM renamed to ${vm_name}_old."


    #echo " Giving 60s for Incremental Snapshots to complete"
    #/root/spinner1.sh 60

    # Get the vm_name for restored_vmid using oVirt API
    echo "Getting VM name for restored_vmid: $restored_vm_id"
    response1=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$restored_vm_id")
    echo "$response1"
    restored_vm_name=$(echo $response1 | jq -r '.name')
    if [[ -z "$restored_vm_name" || "$restored_vm_name" == "null" ]]; then
        echo "Error: Failed to get VM name for restored_vmid: $restored_vm_id"
        exit 1
    fi
    echo "Restored VM Name: $restored_vm_name"
   
    # Change the vm_name of Recovered Failover VM
    echo "Changing name of Recovered Failover VM to $vm_name"
    rename_new_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" -d "<vm><name>$vm_name</name></vm>" "$url_Engine/api/vms/$restored_vm_id")
    echo "Recovered VM name set to: $vm_name"
    
    # Check if the renaming was successful
    if [[ "$rename_new_response" == *"<fault>"* ]]; then
        echo "Error: Failed to rename the recovered VM."
        exit 1
    fi

    echo "VM $vm_name successfully Recovered (Failover)"


    # Loop to wait until the snapshot operation is complete
    echo "Waiting for the Incremental backup  snapshot operation to complete before starting the VM..."
    while true; do
    # Fetch the snapshot status for the VM
    snapshot_in_progress=$(curl -s -k -H "Accept: application/json" \
        -H "Authorization: Bearer $bearer_Token" \
        "$url_Engine/api/vms/$restored_vm_id/snapshots" | \
        jq -r '.snapshot[] | select(.snapshot_status != "ok") | .snapshot_status')

    # If there are no snapshots in progress, break the loop
    if [[ -z "$snapshot_in_progress" ]]; then
        echo "All snapshot operations are complete."
        break
    fi
    
    echo "Snapshot operation still in progress, status: $snapshot_in_progress. Waiting..."
    sleep 10
done


    # Start the recovered VM
    echo "Starting the recovered VM with name $vm_name and ID: $restored_vm_id..."
    start_vm_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" -d "<action/>" "$url_Engine/api/vms/$restored_vm_id/start")
    echo "Start VM response: $start_vm_response"

    # Check if the start operation was successful
    if [[ "$start_vm_response" == *"<fault>"* ]]; then
        echo "Error: Failed to start the recovered VM."
        exit 1
    fi

    echo "Recovered VM with name $vm_name and ID: $restored_vm_id started successfully."
}




create_FO_FB_table() {
  # Create the table with the new schema
  sqlite3 "$backup_index_db" <<EOF
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS sourceFO_$sanitized_restored_vm_id (
    source_vmid TEXT,
    source_vmname TEXT,
    source_engine TEXT,
    source_ip TEXT,
    source_os TEXT,
    FO_vmid TEXT,
    FO_vmname TEXT,
    FO_engine TEXT,
    FO_ip TEXT,
    FO_os TEXT
);
COMMIT;
EOF

  echo "Table sourceFO_$sanitized_restored_vm_id created to be used for Failback."

  # Fetch VM ID and name from table_BI_$sanitized_restored_vm_id
  echo "Fetching Restored VM ID and name from table_BI_$sanitized_restored_vm_id..."
  vm_info=$(sqlite3 "$backup_index_db" "SELECT vm_id, vm_name FROM table_BI_$sanitized_restored_vm_id LIMIT 1;")
  FO_vmid=$(echo "$vm_info" | cut -d'|' -f1)
  FO_vmname=$(echo "$vm_info" | cut -d'|' -f2)
  FO_engine=$url_engine

  vm_details=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$FO_vmid")

   # Extracting the distribution field
   FO_os=$(echo "$vm_details" | jq -r '.guest_operating_system.distribution')

 
  # Fetch NICs
  nics=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$FO_vmid/nics")
  echo "NICs Details: $nics"  # Debugging information to see the actual content

  # Extract NIC ID
  nic_id=$(echo "$nics" | jq -r '.nic[0].id // empty')

  # Fetch reported devices to get IP address
  if [ "$nic_id" != "empty" ]; then
    reported_devices=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$FO_vmid/nics/$nic_id/reporteddevices")
    echo "Reported Devices: $reported_devices"  # Debugging information to see the actual content
    FO_ip=$(echo "$reported_devices" | jq -r '.reported_device[0].ips.ip[0].address // empty')
  else
    FO_ip="N/A"
  fi

  # Provide default values if fields are empty
  FO_ip=${FO_ip:-"N/A"}
  FO_os=${FO_os:-"N/A"}

  # Verifying details before inserting & debugging
  echo "Parsed Restored VM Details: VMID=$FO_vmid, VMName=$FO_vmname, Source Engine=$FO_engine, IP=$FO_ip, OS=$FO_os"  
  echo " "

  echo "Fetching details for Source VM ID: $vm_id_input..."

  # Fetch VM ID and name from table_BI_$sanitized_vm_id
  echo "Fetching Source VM ID and name from table_BI_$sanitized_vm_id..."
  vm_info=$(sqlite3 "$backup_index_db" "SELECT vm_id, vm_name FROM table_BI_$sanitized_vm_id LIMIT 1;")
  source_vmid=$(echo "$vm_info" | cut -d'|' -f1)
  source_vmname=$(echo "$vm_info" | cut -d'|' -f2)
  source_engine="https://engine.local"  # suppose to be from SettingDB but for the moment hardcoded

  vm_source_details=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$source_vmid")

   # Extracting the distribution field
   source_os=$(echo "$vm_source_details" | jq -r '.guest_operating_system.distribution')

 
  # Fetch NICs
  source_nics=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$source_vmid/nics")
  echo "NICs Details: $source_nics"  # Debugging information to see the actual content

  # Extract NIC ID
  source_nic_id=$(echo "$source_nics" | jq -r '.nic[0].id // empty')

  # Fetch reported devices to get IP address
  if [ "$source_nic_id" != "empty" ]; then
    source_reported_devices=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$source_vmid/nics/$source_nic_id/reporteddevices")
    echo "Reported Devices: $source_reported_devices"  # Debugging information to see the actual content
    source_ip=$(echo "$source_reported_devices" | jq -r '.reported_device[0].ips.ip[0].address // empty')
  else
    source_ip="N/A"
  fi

  # Provide default values if fields are empty
  source_ip=${source_ip:-"N/A"}
  source_os=${source_os:-"N/A"}

  # Insert into the table
  sqlite3 "$backup_index_db" <<EOF
BEGIN TRANSACTION;
INSERT INTO sourceFO_$sanitized_restored_vm_id (source_vmid, source_vmname, source_engine, source_ip, source_os, FO_vmid, FO_vmname, FO_engine, FO_ip, FO_os) VALUES ('$source_vmid', '$source_vmname', '$source_engine', '$source_ip', '$source_os', '$FO_vmid', '$FO_vmname', '$FO_engine', '$FO_ip', '$FO_os');
COMMIT;
EOF

  echo "VM information inserted into sourceFO_$sanitized_restored_vm_id."

  # Display the table with headers on and mode column
  echo "Displaying the contents of sourceFO_$sanitized_restored_vm_id..."
  sqlite3 "$backup_index_db" <<EOF
.headers on
.mode column
SELECT * FROM sourceFO_$sanitized_restored_vm_id;
EOF
}

log_trace "Start the restore process "
log_events "Start the restore process"

# Start the restore process
init_restore "$vm_id_input" "$date_input" "$time_input"

log_trace "Run Incremental"
log_events "Run Incremental"

#Run Incremental
#/root/incremental_fofbdr_v21.sh $restored_vm_id recover-now $vm_id_input

# Rename recovered VM
rename_recovered_vm "$restored_vm_id"

# Capture end time
end_time=$(date +%s)

# Calculate elapsed time
elapsed_time=$((end_time - start_time))

# Log the duration
echo "Duration of the script: $elapsed_time seconds"
log_trace "Duration of the script: $elapsed_time seconds"
log_events "Duration of the script: $elapsed_time seconds"

# Write the duration to a file
duration_status_file="/backup/status/${vm_id_input}/restore_duration_status.txt"
mkdir -p "$(dirname "$duration_status_file")"
echo "$elapsed_time" > "$duration_status_file"
echo "Elapsed time written to: $duration_status_file"
log_trace "Elapsed time written to: $duration_status_file"
log_events "Elapsed time written to: $duration_status_file"


# After  migrate_checkpoint call, add the delete_source_checkpoint function call
# delete_source_checkpoint 

# Add a crontab entry to run incrementalSource based on original vm id retention
# Fetch the RPO value from the database for the given vm_id_input
rpo=$(sqlite3 /root/vmSettings.db "SELECT RPO FROM vmAttribs WHERE vmId = '$vm_id_input'")
echo "RPO: $rpo"

# Validate RPO
if [[ -z "$rpo" || ! "$rpo" =~ ^[0-9]+$ ]]; then
  echo "Error: Invalid RPO for vm_id $vm_id_input"
  exit 1
fi

#echo " Adding scheduler for Incremental Backup"
#(crontab -l ; echo "*/$rpo * * * * /root/incrementalTarget_v21.sh $restored_vm_id") | crontab -


# Create and populate the sourceFO table
create_FO_FB_table

  # Drop the restore session table
  echo "Dropping the restore session table..."
  sqlite3 "$backup_index_db" "DROP TABLE IF EXISTS $restore_session_table;"
  echo "Restore session table dropped."

sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Completed' WHERE job_id = '$job_id';"  

log_trace " Recovery for $vm_name with VM ID: $vm_id_input  COMPLETED "
log_events " Recover for $vm_name with VM ID: $vm_id_input  COMPLETED "

log_trace " ======================================================================= "
log_events " ======================================================================= "
