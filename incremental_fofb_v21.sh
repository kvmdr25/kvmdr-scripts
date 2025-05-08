#!/bin/bash
set -e

# Capture start time
start_time=$(date +%s)

echo " "  
echo "#########################"
echo " KVMDR Replicator MVP"
echo " Release : Summer '24"
echo " Codename: M2_Kent   "
echo "#########################"
echo " "
echo "<----Branch for INCREMENTAL Backup---- >"
echo "_______________________________________"
echo " "

# Environment Variables
vm_id_input="$1"
sanitized_vm_id=$(echo "$vm_id_input" | sed 's/[^a-zA-Z0-9]//g')
sanitized_tablename="table_BI_$sanitized_vm_id"
db_file="backup_session_$sanitized_vm_id.db"
timestamp=$(date +%Y%m%d_%H%M%S)
trace_log="/kvmdr/log/$vm_id_input/trace_$timestamp.log"
log_events="/kvmdr/log/$vm_id_input/events_$timestamp.log"
bearer_Token=""
vm_name=""
vm_status=""
disk_ids=""
backup_id=""
transfer_id=""
backup_checkpoint=""
backupfile_Path=""
replication_status="Much Ado About Nothing"
url_Engine="https://engine.local/ovirt-engine"
url_getToken="$url_Engine/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"
backup_index_db="Backup_Index.db"
Full_Backup=25

# Start Logging 
mkdir -p "$(dirname "$trace_log")"
mkdir -p "$(dirname "$log_events")"

log_trace() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$trace_log"
}

log_events() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$log_events"
}

# Main script logic
echo "Arguments passed to main: $vm_id_input"

# Fetch a new oVirt API token using curl
echo "Fetching oVirt API token..."
log_trace "Fetching oVirt API token..."
log_events "Fetching oVirt API token..."

# Fetch the token using curl and parse it with jq
bearer_Token=$(curl -s -k --header Accept:application/json "$url_getToken" | jq -r '.access_token')

# Hash the token
hashed_token=$(echo -n "$bearer_Token" | sha256sum | awk '{print $1}')
echo "Token fetched (hashed): $hashed_token"
log_trace "Token fetched (hashed): $hashed_token"
log_events "Token fetched successfully"

# Check if the token was successfully fetched
if [ -z "$bearer_Token" ]; then
  echo "Failed to fetch access token"
  log_trace "Failed to fetch access token"
  log_events "Failed to fetch access token"
  exit 1
fi

# Use the token to fetch the details of VM
vm_details=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input")

# Debugging step: Print the raw JSON response
log_trace "Raw JSON response from API: $vm_details"

echo "#######################################"
echo "# Checking API Response & Output      #"
echo "#######################################"

# Session DB are mortal until end of session
# Future Candidate for In memory DB
# Remove the database file if it exists
if [ -f "$db_file" ]; then
  rm "$db_file"
  log_trace "Removed existing session database file: $db_file"
fi

# Create the table for backup_session
sqlite3 "$db_file" <<EOF
CREATE TABLE IF NOT EXISTS backup_session_$sanitized_vm_id (
  id INTEGER PRIMARY KEY,
  vm_id TEXT,
  vm_name TEXT,
  vm_status TEXT,
  disk_id TEXT,
  backup_id TEXT,
  transfer_id TEXT,
  backup_checkpoint TEXT,
  replication_status TEXT
);
EOF
log_trace "Created session table in database: backup_session_$sanitized_vm_id"

# Parse VM details using jq
vm_name=$(echo "$vm_details" | jq -r '.name')
vm_status=$(echo "$vm_details" | jq -r '.status')

disk_response=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input/diskattachments")
disk_ids=$(echo "$disk_response" | xmlstarlet sel -t -m "//disk_attachment/disk" -v "@id" -n | tr '\n' ',')
disk_ids=${disk_ids%,}  # Remove trailing comma
echo "VM ID: $vm_id_input"
echo "Disk IDs: $disk_ids"
echo " "
log_trace "Fetched disk IDs for VM: $disk_ids"
log_events "Fetched disk details for VM"

# Insert directly into the database
sqlite3 "$db_file" <<EOF
INSERT INTO backup_session_$sanitized_vm_id (vm_id, vm_name, vm_status, disk_id, backup_id, transfer_id, backup_checkpoint, replication_status)
VALUES ('$vm_id_input', '$vm_name', '$vm_status', '$disk_ids', '$backup_id', '$transfer_id', '$backup_checkpoint', '$replication_status');
EOF
log_trace "Inserted VM details into session table"

echo "Display from DB: $db_file "
echo " "
# Query the data to check if the table is populated
sqlite3 "$db_file" <<EOF
.header on
.mode column
SELECT * FROM backup_session_$sanitized_vm_id;
EOF

# Function to initialize and poll replication
init_replication() {
  fetchvmattribs=$(sqlite3 "$db_file" <<EOF
SELECT vm_name, disk_id FROM backup_session_$sanitized_vm_id WHERE vm_id='$vm_id_input';
EOF
  )

  if [ -z "$fetchvmattribs" ]; then
    echo "No VM Name or Disk ID found for VM ID '$vm_id_input'"
    log_trace "No VM Name or Disk ID found for VM ID '$vm_id_input'"
    log_events "Failed to fetch VM details"
    return 1
  else
    # Extract the VM ID and Disk ID
    IFS="|" read -r fetchvmattribs_vmName fetchvmattribs_diskID <<< "$fetchvmattribs"
    echo "Fetched VM Name: $fetchvmattribs_vmName, Disk ID: $fetchvmattribs_diskID for VM ID: $vm_id_input"
    log_trace "Fetched VM Name: $fetchvmattribs_vmName, Disk ID: $fetchvmattribs_diskID for VM ID: $vm_id_input"

    # Check for the latest checkpoint
    latest_checkpoint=$(sqlite3 "$backup_index_db" <<EOF
SELECT Checkpoint FROM $sanitized_tablename WHERE Full_Backup >= 1 ORDER BY Date DESC, Time DESC LIMIT 1;
EOF
    )

    # Echo the latest checkpoint value for debugging
    echo "Latest Checkpoint: $latest_checkpoint"
    log_trace "Latest Checkpoint: $latest_checkpoint"

    if [ -n "$latest_checkpoint" ]; then
      echo " "
      echo "#######################################"
      echo "#  Incremental Backup                 #"
      echo "#######################################"
      echo " "
      log_trace "Starting Incremental Backup with checkpoint: $latest_checkpoint"
      echo "Starting Incremental Backup with checkpoint: $latest_checkpoint" 

      # Starting Incremental Backup
      init_start_query=$(curl -s -k -X POST -H "Accept: application/xml" -H "Content-Type:application/xml" -H "Authorization: Bearer $bearer_Token" -d "<backup><from_checkpoint_id>$latest_checkpoint</from_checkpoint_id><disks><disk id=\"$disk_ids\" /></disks></backup>" "$url_Engine/api/vms/$vm_id_input/backups")
      init_start_status=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/phase")
      init_start_backupID=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/@id")
      log_trace "Incremental Backup initiation response: $init_start_query"
      echo "Incremental Backup initiation response: $init_start_query"

      if [ "$init_start_status" = "starting" ]; then
        sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Initializing Replication', backup_id='$init_start_backupID' WHERE vm_id='$vm_id_input';
EOF
        log_trace "Backup initialization started for VM ID: $vm_id_input, Backup ID: $init_start_backupID"
        log_events "Backup initialization started"
      else
        sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Initialization Failed' WHERE vm_id='$vm_id_input';
EOF
        log_trace "Backup initialization failed for VM ID: $vm_id_input"
        log_events "Backup initialization failed"
      fi

      # Using sleep 30 to wait for backup readiness
      echo "Checking & Polling if backup is Ready..."
      log_trace "Checking if backup is ready..."
      ./spinner1.sh 30 

      # Poll Backup Status
      init_status_query=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input/backups/$init_start_backupID")
      init_status_phase=$(echo "$init_status_query" | xmlstarlet sel -t -v "//backup/phase")
      init_status_checkpoint=$(echo "$init_status_query" | xmlstarlet sel -t -v "//backup/to_checkpoint_id")

      echo "Checkpoint ID: $init_status_checkpoint"
      log_trace "Checkpoint ID: $init_status_checkpoint"

      if [ "$init_status_phase" = "ready" ]; then
        sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Replication READY', backup_id='$init_start_backupID', backup_checkpoint='$init_status_checkpoint' WHERE vm_id='$vm_id_input';
EOF
        log_trace "Backup ready for VM ID: $vm_id_input"
        log_events "Backup ready"
      else
        echo "Backup is not ready yet. Waiting..."
        log_trace "Backup is not ready yet. Waiting..."
        sleep 30
      fi
    else
      echo "No valid checkpoint found for VM ID '$vm_id_input'"
      log_trace "No valid checkpoint found for VM ID '$vm_id_input'"
      log_events "No valid checkpoint found for VM"
      return 1
    fi
  fi
}

echo " "
echo "#######################################"
echo "#  Starting the Initial Replication   #"
echo "#######################################"
echo " "

# Call the init_replication function
init_replication

# Display the contents of the backup_session table
echo " "
echo "#######################################"
echo "#  Backup Session Table Contents      #"
echo "#######################################"
echo " "

sqlite3 "$db_file" <<EOF
.header on
.mode column
SELECT * FROM backup_session_$sanitized_vm_id;
EOF

# Create incremental_$sanitized_vm_id table if not exists
sqlite3 "$backup_index_db" <<EOF
CREATE TABLE IF NOT EXISTS incremental_$sanitized_vm_id (
  Start TEXT,
  Length TEXT,
  Dirty TEXT,
  Zero TEXT,
  Date TEXT,
  Time TEXT,
  Checkpoint TEXT
);
EOF
log_trace "Created incremental table in database: incremental_$sanitized_vm_id"

# Function to finalize the image transfer
finalize_image_transfer() {
  local transfer_id="$1"
  
  while true; do
    local finalize_response=$(curl -s -k -X POST -H "Authorization: Bearer $bearer_Token" \
                           -H "Content-Type:application/xml" -d "<action />" \
                           "$url_Engine/api/imagetransfers/$transfer_id/finalize" 2>&1)
    echo "Image transfer finalization response: $finalize_response"
    log_trace "Image transfer finalization response: $finalize_response"

    local transfer_status=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" \
                           "$url_Engine/api/imagetransfers/$transfer_id" | xmlstarlet sel -t -v "//image_transfer/phase")
    echo "Image transfer status: $transfer_status"

    if [[ "$transfer_status" == "finished_success" ]]; then
      # Extract the checkpoint ID after finalizing the image transfer
      local backup_info=$(curl -s -k -H "Accept:application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input/backups/$fetchvmattribs_backupID")
      local checkpoint_id=$(echo "$backup_info" | xmlstarlet sel -t -v "//backup/to_checkpoint_id")
      # Update Checkpoint in incremental table
      sqlite3 "$backup_index_db" <<EOF
UPDATE incremental_$sanitized_vm_id SET Checkpoint='$checkpoint_id' WHERE Date = (SELECT Date FROM incremental_$sanitized_vm_id ORDER BY Date DESC, Time DESC LIMIT 1) AND Time = (SELECT Time FROM incremental_$sanitized_vm_id ORDER BY Date DESC, Time DESC LIMIT 1);
EOF
      echo "Updating Checkpoint in incremental table..."
      echo "Checkpoint ID: $checkpoint_id"
      echo "Date: $fixed_date, Time: $fixed_time"
      break
    elif [[ "$transfer_status" == "finished_failure" || "$transfer_status" == "cancelled_system" ]]; then
      echo "Error: Image transfer failed with status $transfer_status"
      exit 1
    fi

    echo "Image transfer is still active. Retrying in 10 seconds..."
    ./spinner1.sh 10
  done
}

# Function to invoke imageTransfer and Download the backup
process_imageTransferDownload() {
  fetchvmattribs=$(sqlite3 "$db_file" <<EOF
SELECT vm_name, disk_id, backup_id FROM backup_session_$sanitized_vm_id WHERE vm_id='$vm_id_input';
EOF
  )

  if [ -z "$fetchvmattribs" ]; then
    echo "No VM Name, Disk ID, or Backup ID found for VM ID '$vm_id_input'"
    return 1
  else
    IFS="|" read -r fetchvmattribs_vmName fetchvmattribs_diskID fetchvmattribs_backupID <<< "$fetchvmattribs"
    echo "Fetched VM Name: $fetchvmattribs_vmName, Disk ID: $fetchvmattribs_diskID Backup ID: $fetchvmattribs_backupID for VM ID: $vm_id_input"

    echo "Starting image transfer for backup ID: $fetchvmattribs_backupID"

    # Starting image transfer
    imageTransfer_start=$(curl -s -k -X POST -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $bearer_Token" -d "{\"disk\":{\"id\":\"$fetchvmattribs_diskID\"},\"backup\":{\"id\":\"$fetchvmattribs_backupID\"},\"direction\":\"download\",\"format\":\"raw\",\"inactivity_timeout\":60}" "$url_Engine/api/imagetransfers")

    # Debugging step: Print the raw response
    echo "Image Transfer Start Response:"
    echo "$imageTransfer_start"

    imageTransfer_status=$(echo "$imageTransfer_start" | jq -r '.phase')
    imageTransfer_transferID=$(echo "$imageTransfer_start" | jq -r '.id')
    imageTransfer_proxy_url=$(echo "$imageTransfer_start" | jq -r '.proxy_url')

    # Ensure transfer ID is extracted
    if [ -z "$imageTransfer_transferID" ]; then
      echo "Error: transfer_id could not be extracted."
      return 1
    fi

    # Debugging step: Print the extracted transfer ID
    echo "Extracted Transfer ID: $imageTransfer_transferID"

    # Update the transfer_id in the database
    sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET transfer_id='$imageTransfer_transferID' WHERE vm_id='$vm_id_input';
EOF

    timestamp=$(date +%Y%m%d_%H%M%S)
    restore_dir="/backup/restore/$vm_id_input/$timestamp"
    mkdir -p $restore_dir

    echo "Preparing for ImageTransfer"
    log_trace "Preparing for ImageTransfer"
    ./spinner1.sh 10
    
    echo "Fetching download URL for transfer ID: $imageTransfer_transferID"

    # Fetch the download URL using curl
    downloadURL_response=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/imagetransfers/$imageTransfer_transferID")

    # Debugging step: Print the raw response for the download URL
    echo "Download URL Response:"
    echo "$downloadURL_response"

    downloadURL=$(echo "$downloadURL_response" | jq -r '.proxy_url')
    echo "Download URL: $downloadURL"

    if [ -z "$downloadURL" ]; then
      echo "Download URL is not available yet. Waiting..."
      log_trace "Download URL is not available yet. Waiting..."
      sleep 30
    fi

    # Send OPTIONS request to understand server capabilities
    echo "Sending OPTIONS request to the download URL"
    options_response=$(curl -k -X OPTIONS "$downloadURL" -H "Authorization: Bearer $bearer_Token")
    echo "OPTIONS Response: $options_response"

    # Implement incremental backup logic here
    echo "Fetching the list of changed blocks..."
    CHANGED_BLOCKS=$(curl -s -k -H "Content-Type: application/json" "$downloadURL/extents?context=dirty")

    # Get the latest time from the last download
    latest_time=$(date +%H:%M:%S)

    # Display table before download
    table_before="| Start          | Length          | Dirty | Zero | Date | Time |\n|----------------|-----------------|-------|------|------|------|\n"
    for block in $(echo "$CHANGED_BLOCKS" | jq -c '.[]'); do
        START=$(echo "$block" | jq -r '.start')
        LENGTH=$(echo "$block" | jq -r '.length')
        DIRTY=$(echo "$block" | jq -r '.dirty')
        ZERO=$(echo "$block" | jq -r '.zero')
        DATE=$(date +%Y-%m-%d)
        TIME=$latest_time
        table_before="$table_before| $START | $LENGTH | $DIRTY | $ZERO | $DATE | $TIME |\n"
    done
    echo -e "$table_before"

    # Insert table_before details into incremental_$sanitized_vm_id
    for block in $(echo "$CHANGED_BLOCKS" | jq -c '.[]'); do
        START=$(echo "$block" | jq -r '.start')
        LENGTH=$(echo "$block" | jq -r '.length')
        DIRTY=$(echo "$block" | jq -r '.dirty')
        ZERO=$(echo "$block" | jq -r '.zero')
        DATE=$(date +%Y-%m-%d)
        TIME=$latest_time
        sqlite3 "$backup_index_db" <<EOF
INSERT INTO incremental_$sanitized_vm_id (Start, Length, Dirty, Zero, Date, Time, Checkpoint)
VALUES ('$START', '$LENGTH', '$DIRTY', '$ZERO', '$DATE', '$TIME', NULL);
EOF
    done

    # Initialize variables
    extent_metadata_file="$restore_dir/extent_metadata_${vm_name}_$timestamp.txt"
    echo -e "$table_before" > $extent_metadata_file

    echo "Processing extents..."

    backup_files=""

    for block in $(echo "$CHANGED_BLOCKS" | jq -c '.[]'); do
        START=$(echo "$block" | jq -r '.start')
        LENGTH=$(echo "$block" | jq -r '.length')
        DIRTY=$(echo "$block" | jq -r '.dirty')

        if [ "$DIRTY" = "true" ]; then
            file_path="$restore_dir/${vm_id_input}_${START}_${LENGTH}.raw"
            backup_files="$backup_files$file_path, "
            echo "Downloading range starting at: $START"
            curl -k --range "$START-$((START + LENGTH - 1))" "$downloadURL" --output "$file_path"
        fi
    done

    # Remove trailing comma and space
    backup_files=${backup_files%, }

    echo -e "\nTable before download:\n$table_before"

    # Get current date and time for logging
    fixed_date=$(date +%Y-%m-%d)
    fixed_time=$(date +%H:%M:%S)

    echo "Download completed at Date: $fixed_date, Time: $fixed_time"
    log_trace "Download completed at Date: $fixed_date, Time: $fixed_time"

    # Finalize the image transfer
    finalize_image_transfer "$imageTransfer_transferID"

    # List all the files generated and their respective sizes
    echo " "
    echo "#######################################"
    echo "#  List of Generated Files            #"
    echo "#######################################"
    echo " "
    total_size=0
    for file in $restore_dir/*; do
        size=$(stat -c%s "$file")
        total_size=$((total_size + size))
        echo "File: $file, Size: $size bytes"
    done
    total_size_mb=$(echo "scale=2; $total_size/1024/1024" | bc)
    echo "Total size of all files: $total_size bytes ($total_size_mb MB)"
    log_trace "Total size of all files: $total_size bytes ($total_size_mb MB)"

    # Display incremental table after update
    echo "#######################################"
    echo "# Final Extent Table                  #"
    echo "#######################################"
    sqlite3 "$backup_index_db" <<EOF
.header on
.mode column
UPDATE incremental_$sanitized_vm_id SET Time = '$fixed_time' WHERE Time = '$latest_time';
SELECT * FROM incremental_$sanitized_vm_id;
EOF
  fi
}

echo " "
echo "#######################################"
echo "#  Invoking imageTransfer and         #"
echo "#  Download the backup                #"
echo "#######################################"
echo " "

# Call the process_imageTransferDownload function
process_imageTransferDownload

echo " "
echo "#######################################"
echo "#  Final Backup Session Table Contents #"
echo "#######################################"
echo " "

sqlite3 "$db_file" <<EOF
.header on
.mode column
SELECT * FROM backup_session_$sanitized_vm_id;
EOF

# Function to fetch backup information and update checkpoint IDs
fetch_backup_info_and_update() {
    echo "Fetching backup information for VM ID: $vm_id_input"
    log_trace "Fetching backup information for VM ID: $vm_id_input"
    backup_info=$(curl -s -k -H "Accept:application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input/backups")

    # Extract to_checkpoint_id using xmlstarlet
    to_checkpoint_ids=$(echo "$backup_info" | xmlstarlet sel -t -m "//backup" -v "concat(@id, ' ', to_checkpoint_id)" -n)

    # Compare and update the matched checkpoint IDs in the database
    echo "Comparing backup IDs with to_checkpoint_ids and updating database:"
    log_trace "Comparing backup IDs with to_checkpoint_ids and updating database:"
    while read -r line; do
      b_id=$(echo $line | cut -d' ' -f1)
      t_id=$(echo $line | cut -d' ' -f2)
      echo "UPDATE backup_session_$sanitized_vm_id SET backup_checkpoint='$t_id' WHERE backup_id='$b_id';"
      sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET backup_checkpoint='$t_id' WHERE backup_id='$b_id';
EOF
      echo "Backup ID: $b_id updated with To Checkpoint ID: $t_id"
      log_trace "Backup ID: $b_id updated with To Checkpoint ID: $t_id"
    done <<< "$to_checkpoint_ids"
}

echo " "
echo "#######################################"
echo "#  Finalizing Replication - Cleanup   #"
echo "#######################################"
echo " "

fetch_backup_info_and_update

# Display the final backup session table
echo " "
echo "#########################################"
echo "#Complete backup_session Table Contents #"
echo "#########################################"
echo " "
echo " --> To copy the table to Engine_DB"
log_trace "Complete backup_session Table Contents"

echo "SELECT * FROM backup_session_$sanitized_vm_id;"
sqlite3 "$db_file" <<EOF
.header on
.mode column
SELECT * FROM backup_session_$sanitized_vm_id;
EOF

# Function to finalize the backup
finalize_backup() {
  fetchvmattribs=$(sqlite3 "$db_file" <<EOF
SELECT vm_name, backup_id, transfer_id FROM backup_session_$sanitized_vm_id WHERE vm_id='$vm_id_input';
EOF
  )
  
  IFS="|" read -r fetchvmattribs_vmName fetchvmattribs_backupID fetchvmattribs_transferID <<< "$fetchvmattribs"

  if [ -z "$fetchvmattribs_vmName" ] || [ -z "$fetchvmattribs_backupID" ]; then
    echo "No VM ID or Backup ID found for VM ID '$vm_id_input'"
    log_trace "No VM ID or Backup ID found for VM ID '$vm_id_input'"
    return 1
  fi

  echo "Finalizing backup for VM ID: $vm_id_input, Backup ID: $fetchvmattribs_backupID"
  log_trace "Finalizing backup for VM ID: $vm_id_input, Backup ID: $fetchvmattribs_backupID"
  log_events "Finalizing backup"

  # Poll for the backup status being ready and initiate finalization
  echo "Waiting for backup to be ready..."
  log_trace "Waiting for backup to be ready..."
  ./spinner1.sh 30

  backup_status=$(curl -s -k -H "Accept:application/xml" -H "Authorization: Bearer $bearer_Token" \
    "$url_Engine/api/vms/$vm_id_input/backups/$fetchvmattribs_backupID" | xmlstarlet sel -t -v "//backup/phase")
  if [ "$backup_status" = "ready" ]; then
    echo "Backup is ready for finalization."
  else
    echo "Backup is not ready yet. Exiting..."
    log_trace "Backup is not ready yet. Exiting..."
    return 1
  fi

  # Finalizing the backup
  finalize_response=$(curl -s -k -X POST -H "Accept:application/xml" -H "Content-type:application/xml" -H "Authorization: Bearer $bearer_Token" \
    -d "<action />" "$url_Engine/api/vms/$vm_id_input/backups/$fetchvmattribs_backupID/finalize")
  echo "Backup finalization response: $finalize_response"
  log_trace "Backup finalization response: $finalize_response"
  log_events "Backup finalized successfully"

  # Extract and save final backup information in the database
  finalize_phase=$(echo "$finalize_response" | xmlstarlet sel -t -v "//action/status")
  if [ "$finalize_phase" = "complete" ]; then
    echo "UPDATE backup_session_$sanitized_vm_id SET replication_status='Finalized' WHERE vm_id='$vm_id_input';"
    sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Finalized' WHERE vm_id='$vm_id_input';
EOF
    log_trace "Backup finalized for VM ID: $vm_id_input"
  else
    echo "Backup finalization failed for VM ID: $vm_id_input"
    log_trace "Backup finalization failed for VM ID: $vm_id_input"
  fi

  echo "Backup session completed for VM ID: $vm_id_input"
  log_trace "Backup session completed for VM ID: $vm_id_input"
  log_events "Backup session completed"
}

finalize_backup

echo " "
echo "############################################# "
echo "# GRAND Final Backup Session Table Contents #"
echo "#############################################"
echo " "

echo "SELECT * FROM backup_session_$sanitized_vm_id;"
sqlite3 "$db_file" <<EOF
.header on
.mode column
SELECT * FROM backup_session_$sanitized_vm_id;
EOF

# Function to back up the SQLite database and copy it to /backup/sqldump
backup_sqlite_db() {
  timestamp=$(date +%Y%m%d_%H%M%S)
  backup_file="/backup/sqldump/backup_session_$timestamp.db"
  echo " " 
  echo "Backing up SQLite database to $backup_file"
  log_trace "Backing up SQLite database to $backup_file"
  sqlite3 "$db_file" ".backup '$backup_file'"
  
  if [ -f "$backup_file" ]; then
    echo " "
    echo "Backup successful: $backup_file"
    log_trace "Backup successful: $backup_file"
    log_events "Backup session saved"
    echo "UPDATE backup_session_$sanitized_vm_id SET replication_status='Replication COMPLETE Successfully' WHERE vm_id='$vm_id_input';"
    sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Replication COMPLETE Successfully' WHERE vm_id='$vm_id_input';  
EOF
  else
    echo "Backup failed."
    log_trace "Backup failed."
    log_events "Backup failed"
  fi
}

# Call the backup function
backup_sqlite_db

echo "#######################################"
echo "# Replication COMPLETE Successfully   #"
echo "#######################################"
echo " "

# Display the final backup session table
echo "SELECT * FROM backup_session_$sanitized_vm_id;"
sqlite3 "$db_file" <<EOF
SELECT * FROM backup_session_$sanitized_vm_id;
EOF

# Function to update the Backup_Index DB
update_backup_index_db() {
  fetchvmattribs=$(sqlite3 "$db_file" <<EOF
SELECT vm_name, disk_id, backup_checkpoint, replication_status FROM backup_session_$sanitized_vm_id WHERE vm_id='$vm_id_input';
EOF
  )

  if [ -z "$fetchvmattribs" ]; then
    echo "No VM attributes found for VM ID '$vm_id_input'"
    log_trace "No VM attributes found for VM ID '$vm_id_input'"
    return 1
  fi

  IFS="|" read -r fetchvmattribs_vmName fetchvmattribs_diskID fetchvmattribs_checkpoint fetchvmattribs_status <<< "$fetchvmattribs"

  # Use current time and date
  current_time=$(date +%H:%M:%S)
  current_date=$(date +%Y-%m-%d)

  # Echo the current time and date values
  echo "Current TIME: $current_time"
  echo "Current DATE: $current_date"
  log_trace "Current TIME: $current_time"
  log_trace "Current DATE: $current_date"

  global_timestamp_time=$current_time
  global_timestamp_date=$current_date

  echo "$sanitized_tablename"
  echo " "
  echo " *Displaying Backup_Index DB to journal the entries* "
  echo " "
  log_trace "Updating Backup_Index DB for VM ID: $vm_id_input"

  # Create and update the sanitized table
  echo "CREATE TABLE IF NOT EXISTS $sanitized_tablename (id INTEGER PRIMARY KEY, vm_id TEXT, vm_name TEXT, disk_id TEXT, Full_Backup INTEGER, Backup_path TEXT, Checkpoint TEXT, Time TEXT, Date TEXT, Status TEXT, Duration TEXT, Size TEXT);"
  echo "INSERT INTO $sanitized_tablename (vm_id, vm_name, disk_id, Full_Backup, Backup_path, Checkpoint, Time, Date, Status, Duration, Size) VALUES ('$vm_id_input', '$fetchvmattribs_vmName', '$fetchvmattribs_diskID', $Full_Backup, '$backup_files', '$fetchvmattribs_checkpoint', '$global_timestamp_time', '$global_timestamp_date', '$fetchvmattribs_status', '0', '$total_size_mb');"
  sqlite3 $backup_index_db <<EOF
CREATE TABLE IF NOT EXISTS $sanitized_tablename (
    id INTEGER PRIMARY KEY,
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

INSERT INTO $sanitized_tablename (vm_id, vm_name, disk_id, Full_Backup, Backup_path, Checkpoint, Time, Date, Status, Duration, Size)
VALUES ('$vm_id_input', '$fetchvmattribs_vmName', '$fetchvmattribs_diskID', $Full_Backup, '$backup_files', '$fetchvmattribs_checkpoint', '$global_timestamp_time', '$global_timestamp_date', '$fetchvmattribs_status', '0', '$total_size_mb');
EOF

  # Check for the latest checkpoint from backup_session table
  latest_checkpoint=$(sqlite3 "$db_file" <<EOF
SELECT backup_checkpoint FROM backup_session_$sanitized_vm_id ORDER BY id DESC LIMIT 1;
EOF
  )

  # Echo the latest checkpoint value for debugging
  echo "Latest Checkpoint: $latest_checkpoint"
  log_trace "Latest Checkpoint: $latest_checkpoint"

  # Update old records in the Backup_Index DB
  Full_backup_status=$(sqlite3 "$backup_index_db" <<EOF
SELECT Full_Backup FROM $sanitized_tablename WHERE Checkpoint='$latest_checkpoint';
EOF
  )

  # Echo the Full_backup_status value for debugging
  echo "Full Backup Status: $Full_backup_status"
  log_trace "Full Backup Status: $Full_backup_status"

  if [ "$Full_backup_status" = "1" ]; then
    echo "UPDATE $sanitized_tablename SET Backup_path='$backup_files', Time='$global_timestamp_time', Date='$global_timestamp_date', Size='$total_size_mb' WHERE Checkpoint='$fetchvmattribs_checkpoint';"
    sqlite3 "$backup_index_db" <<EOF
UPDATE $sanitized_tablename SET Backup_path='$backup_files', Time='$global_timestamp_time', Date='$global_timestamp_date', Size='$total_size_mb' WHERE Checkpoint='$fetchvmattribs_checkpoint';
EOF
  elif [ "$Full_backup_status" = "25" ]; then
    get_id=$(sqlite3 "$backup_index_db" <<EOF
SELECT id FROM $sanitized_tablename WHERE Checkpoint='$latest_checkpoint';
EOF
    )
    
    echo "######################## "
    echo "Current ID : $get_id"
    echo "######################## "

    previous_full_backup_status=$(sqlite3 "$backup_index_db" <<EOF
SELECT Full_Backup FROM $sanitized_tablename WHERE id =($get_id-1);
EOF
    )
    
    if [ "$previous_full_backup_status" = "25" ]; then
      update_previous_full_backup_status=$(sqlite3 "$backup_index_db" <<EOF
UPDATE $sanitized_tablename SET Full_Backup=0 WHERE id=($get_id-1);
EOF
      )
    else
      echo "It's Previous full Backup - leaving untouched"
    fi

    echo "Updating old records in $sanitized_tablename"
    echo "Backup_path: $backup_files"
    echo "Timestamp Time: $global_timestamp_time"
    echo "Timestamp Date: $global_timestamp_date"
    echo "Checkpoint: $fetchvmattribs_checkpoint"
    echo "Full Backup: $Full_Backup"
    echo "Size: $total_size_mb"
    sqlite3 "$backup_index_db" <<EOF
UPDATE $sanitized_tablename SET Backup_path='$backup_files', Time='$global_timestamp_time', Date='$global_timestamp_date', Size='$total_size_mb' WHERE Checkpoint='$fetchvmattribs_checkpoint';
EOF
  else
    echo "Updating old records in $sanitized_tablename"
    echo "Backup_path: $backup_files"
    echo "Timestamp Time: $global_timestamp_time"
    echo "Timestamp Date: $global_timestamp_date"
    echo "Checkpoint: $fetchvmattribs_checkpoint"
    echo "Full Backup: $Full_Backup"
    echo "Size: $total_size_mb"
    sqlite3 "$backup_index_db" <<EOF
UPDATE $sanitized_tablename SET Backup_path='$backup_files', Time='$global_timestamp_time', Date='$global_timestamp_date', Size='$total_size_mb' WHERE Checkpoint='$fetchvmattribs_checkpoint';
EOF
  fi

  # For post Failover: logic to check for empty Backup_path and update date/time
  sqlite3 "$backup_index_db" <<EOF
UPDATE $sanitized_tablename
SET Time = '$global_timestamp_time', Date = '$global_timestamp_date', Status = 'Setting Checkpoint after Failover & Failback', Size='$total_size_mb'
WHERE Backup_path = '' AND id = (
  SELECT id FROM $sanitized_tablename WHERE Checkpoint = '$latest_checkpoint' ORDER BY Date DESC, Time DESC LIMIT 1
);
EOF

  # Show all details in the new table
  echo "Details in Table $sanitized_tablename :"
  log_trace "Details in Table $sanitized_tablename"
  echo "SELECT * FROM $sanitized_tablename;"
  sqlite3 $backup_index_db <<EOF
.header on
.mode column
SELECT * FROM $sanitized_tablename ;
EOF
}

echo " "
echo "#######################################"
echo "# Backup Index DB Update Complete     #"
echo "#######################################"
echo " "
log_events "Backup Index DB update complete"

# Call the update_backup_index_db function
update_backup_index_db

echo " "
echo "Trace Log File Location: $trace_log"
echo "Log Events File Location: $log_events"
echo " "
log_events "Trace Log File Location: $trace_log"
log_events "Log Events File Location: $log_events"

# Capture end time
end_time=$(date +%s)

# Calculate elapsed time
elapsed_time=$((end_time - start_time))

# Update the duration in Backup_Index.db
sqlite3 $backup_index_db <<EOF
UPDATE $sanitized_tablename SET Duration='$elapsed_time' WHERE vm_id='$vm_id_input' AND Checkpoint='$fetchvmattribs_checkpoint';
EOF


# Fetch retention_days and RPO (in minutes) from the VmSettings table in settings.db based on vm_id_input
retention_days=$(sqlite3 "settings.db" <<EOF
SELECT retentionPeriod FROM VmSettings WHERE vmId='$vm_id_input';
EOF
)

RPO=$(sqlite3 "settings.db" <<EOF
SELECT rpo FROM VmSettings WHERE vmId='$vm_id_input';
EOF
)

# Ensure that retention_days and RPO have values, otherwise set defaults
if [ -z "$retention_days" ]; then
    retention_days="NULL"  # Set Retention to NULL
fi

if [ -z "$RPO" ]; then
    RPO="NULL"  # Set RPO to NULL if not available
fi

# Get time, date, size, status, and backupfile_Path from table_BI_$sanitized_vm_id
IFS='|' read -r time date size status backupfile_Path <<< $(sqlite3 "$backup_index_db" <<EOF
SELECT Time, Date, Size, Status, Backup_path FROM table_BI_$sanitized_vm_id ORDER BY id DESC LIMIT 1;
EOF
)

# Insert the backup details into the existing table
sqlite3 "$backup_index_db" <<EOF
INSERT INTO backupindex_VM_$sanitized_vm_id (
    checkpoint,
    backup_date,
    backup_time,
    backup_type,
    backup_path,
    size,
    status,
    retention_days,
    RPO
    previous_run_date,
    next_run_date,
    next_run_date_checker

) VALUES (
    '$fetchvmattribs_checkpoint',
    '$date',
    '$time',
    'Incremental Backup',
    '$backupfile_Path',
    '$size',
    '$status',
    $retention_days,
    $RPO
    NULL,  -- Not used for incremental backups
    NULL,  -- Not used for incremental backups
    0  -- No synthetic backup needed for incremental
);
EOF

echo "Backup details inserted into table backupindex_VM_$sanitized_vm_id"
log_trace "Backup details inserted into table backupindex_VM_$sanitized_vm_id"
log_events "Backup details inserted into table backupindex_VM_$sanitized_vm_id"

# Display the contents of the backupindex_VM_$sanitized_vm_id table
echo "#########################################"
echo "# Contents of backupindex_VM_$sanitized_vm_id Table #"
echo "#########################################"

sqlite3 "$backup_index_db" <<EOF
.header on
.mode column
SELECT * FROM backupindex_VM_$sanitized_vm_id;
EOF



# Write the duration to a file
duration_status_file="/backup/restore/${vm_id_input}/restore_duration_status.txt"
mkdir -p "$(dirname "$duration_status_file")"
echo "$elapsed_time" > "$duration_status_file"

echo "Duration of the script: $elapsed_time seconds"
log_trace "Duration of the script: $elapsed_time seconds"
log_events "Duration of the script: $elapsed_time seconds"

