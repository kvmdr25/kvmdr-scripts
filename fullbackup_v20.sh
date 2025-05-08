#!/bin/bash

# Capture start time
start_time=$(date +%s)

echo " "  
echo "#########################"
echo " KVMDR Replicator MVP"
echo " Release : Summer '24"
echo " Codename: M2_Kent   "
echo "#########################"
echo " "
echo "<----Branch for FULL Backup---- >"
echo "________________________________"
echo " "

# Environment Variables                                                                                                                          
vm_id_input="$1"                                                                                                                                  
sanitized_vm_id=$(echo "$vm_id_input" | sed 's/[^a-zA-Z0-9]//g')                                                                                  
sanitized_tablename="table_BI_$sanitized_vm_id"                                                                                                   
db_file="backup_session_$sanitized_vm_id.db"
timestamp=$(date +%Y%m%d%H%M%S)
formatted_time=$(date +%H:%M:%S)
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
jobid_db="/root/vmSettings.db"
job_type="Initial Sync"



echo " "
echo "Timestamp: $timestamp"  # Ensure this is part of the script's output
echo " "

# Write the timestamp to a file named timestamp_<vmid>.txt
echo "${timestamp}" > "/tmp/timestamp_${vm_id_input}.txt"


# Validate the input
if [ -z "$vm_id_input" ]; then
  echo "Error: VM ID is required as the first argument."
  exit 1
fi

echo "VM ID provided: $vm_id_input"
echo " "


# Start Logging 

mkdir -p "$(dirname "$trace_log")"
mkdir -p "$(dirname "$log_events")"

# Create the log file immediately
touch "$log_events"

# Log initialization message
echo "Log initialized for VMID: $vm_id_input at $timestamp" >> "$log_events"


log_trace() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$trace_log"
}

log_events() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$log_events"
}


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


# Redirect stdout and stderr to the log file
exec > >(stdbuf -oL tee -a "$log_events") 2>&1

# Enable error handling
set -o pipefail
set -e



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
      break
    elif [[ "$transfer_status" == "finished_failure" || "$transfer_status" == "cancelled_system" ]]; then
      echo "Error: Image transfer failed with status $transfer_status"
      exit 1
    fi

    echo "Image transfer is still active. Retrying in 10 seconds..."
    ./spinner1.sh 10
  done
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

#PLACEHOLDER insert into table_jobid
log_trace " Inserting vm name into table_jobid"                                                                                                          
log_events " Inserting vm name into table_jobid" 

sqlite3 "$jobid_db" "UPDATE table_jobid SET vm_name = '$vm_name' WHERE vm_id = '$vm_id_input';"

# TASK Push                                                                                                                                                                 
                                                                                                                                                                           
# Query to fetch vm_name, status, and job_type for a specific job_id                                                                                                       
taskquery="SELECT vm_name, status, job_type FROM table_jobid WHERE job_id='$job_id';"                                                                                      
                                                                                                                                                                           
# Fetch and process the query result                                                                                                                                       
taskresult=$(sqlite3 "$jobid_db" "$taskquery")                                                                                                                             
                                                                                                                                                                           
# Debug: Log the raw query result                                                                                                                                         
echo "Task: Raw Query Result: $taskresult"                                                                                                                                 
                                                                                                                                                                           
# Check if result is not empty                                                                                                                                             
if [ -n "$taskresult" ]; then                                                                                                                                              
  # Split the result into variables                                                                                                                                        
  IFS='|' read -r vm_name status job_type <<< "$taskresult"                                                                                                                
                                                                                                                                                                           
  # Debug: Log the parsed variables                                                                                                                                        
  echo "Task: vm_name=$vm_name, status=$status, job_type=$job_type"                                                                                                        
                                                                                                                                                                           
  # Format the message as JSON                                                                                                                                             
  message="{\"vm_name\": \"$vm_name\", \"status\": \"$status\", \"job_type\": \"$job_type\"}"                                                                              
                                                                                                                                                                           
  # Debug: Log the formatted JSON                                                                                                                                          
  echo "Task: JSON Message: $message"                                                                                                                                      
                                                                                                                                                                           
  # Send the message via websocat                                                                                                                                          
  echo "$message" | websocat ws://192.168.1.127:3001                                                                                                                       
                                                                                                                                                                           
  # Debug: Log the successful message send                                                                                                                                 
  echo "Task: Message sent successfully: $message"                                                                                                                        
else                                                                                                                                                                       
  # Debug: Log if no data is found                                                                                                                                         
  echo "Task: No data found for job_id=$job_id"                                                                                                                            
fi



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
 
      # Starting Backup 
      init_start_query=$(curl -s -k -X POST -H "Accept: application/xml" -H "Content-Type:application/xml" -H "Authorization: Bearer $bearer_Token" -d "<backup><disks><disk id=\"$fetchvmattribs_diskID\" /></disks></backup>" "$url_Engine/api/vms/$vm_id_input/backups")
      init_start_status=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/phase")
      init_start_backupID=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/@id")

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

      # Poll Backup Status until it's ready
      while true; do
        echo "Checking & Polling if Backup is ready..."
        log_trace "Checking if backup is ready..."
        ./spinner1.sh 30 
        init_status_query=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input/backups/$init_start_backupID")
        init_status_phase=$(echo "$init_status_query" | xmlstarlet sel -t -v "//backup/phase")
        #init_status_checkpoint=$(echo "$init_status_query" | xmlstarlet sel -t -v "//backup/to_checkpoint_id")
        init_status_checkpoint=$(echo "$init_status_query" | xmlstarlet sel -t -v "//backup/to_checkpoint_id" 2>/dev/null || true)

        if [ "$init_status_phase" = "ready" ]; then
          sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Replication READY', backup_id='$init_start_backupID', backup_checkpoint='$init_status_checkpoint' WHERE vm_id='$vm_id_input';
EOF
          log_trace "Backup ready for VM ID: $vm_id_input"
          log_events "Backup ready"
          break
        else
          echo "Backup not ready, continuing to check..."
          log_trace "Backup not ready, continuing to check..."
        fi
      done
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

# Function to invoke imageTransfer and Download the backup
process_imageTransferDownload() {
  fetchvmattribs=$(sqlite3 "$db_file" <<EOF
SELECT vm_name, disk_id, backup_id FROM backup_session_$sanitized_vm_id WHERE vm_id='$vm_id_input';
EOF
  )

  # If VM exists
  if [ -z "$fetchvmattribs" ]; then
    echo "No VM Name, Disk ID, or Backup ID found for VM ID '$vm_id_input'"
    log_trace "No VM Name, Disk ID, or Backup ID found for VM ID '$vm_id_input'"
    log_events "Failed to fetch VM backup details"
    return 1
  else
    # Extract the VM Name, Disk ID, and Backup ID
    IFS="|" read -r fetchvmattribs_vmName fetchvmattribs_diskID fetchvmattribs_backupID <<< "$fetchvmattribs"
    echo "Fetched VM Name: $fetchvmattribs_vmName, Disk ID: $fetchvmattribs_diskID Backup ID: $fetchvmattribs_backupID for VM ID: $vm_id_input"
    log_trace "Fetched VM Name: $fetchvmattribs_vmName, Disk ID: $fetchvmattribs_diskID Backup ID: $fetchvmattribs_backupID for VM ID: $vm_id_input"

    if [ -z "$fetchvmattribs_backupID" ]; then
      echo "Error: backup_id is empty."
      log_trace "Error: backup_id is empty for VM ID: $vm_id_input"
      return 1
    fi

    # Starting imageTransfer
    imageTransfer_start=$(curl -s -k -X POST -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $bearer_Token" -d "{\"disk\":{\"id\":\"$fetchvmattribs_diskID\"},\"backup\":{\"id\":\"$fetchvmattribs_backupID\"},\"direction\":\"download\",\"format\":\"raw\",\"inactivity_timeout\":120}" "$url_Engine/api/imagetransfers")

    # Debugging step: Print the raw response
    echo "Image Transfer Start Response:"
    echo "$imageTransfer_start"
    log_trace "Image Transfer Start Response: $imageTransfer_start"

    imageTransfer_status=$(echo "$imageTransfer_start" | jq -r '.phase')
    imageTransfer_transferID=$(echo "$imageTransfer_start" | jq -r '.id')
    imageTransfer_proxy_url=$(echo "$imageTransfer_start" | jq -r '.proxy_url')
    imageTransfer_to_checkpoint=$(echo "$imageTransfer_start" | jq -r '.to_checkpoint_id')

    # Ensure transfer ID is extracted
    if [ -z "$imageTransfer_transferID" ]; then
      echo "Error: transfer_id could not be extracted."
      log_trace "Error: transfer_id could not be extracted for VM ID: $vm_id_input"
      return 1
    fi

    # Debugging step: Print the extracted transfer ID
    echo "Extracted Transfer ID: $imageTransfer_transferID"
    echo "To Checkpoint ID: $imageTransfer_to_checkpoint"
    log_trace "Extracted Transfer ID: $imageTransfer_transferID"
    log_trace "To Checkpoint ID: $imageTransfer_to_checkpoint"

    # Update the transfer_id and to_checkpoint_id in the database
    sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET transfer_id='$imageTransfer_transferID', backup_checkpoint='$imageTransfer_to_checkpoint' WHERE vm_id='$vm_id_input';
EOF
    log_trace "Updated transfer ID and checkpoint ID in session table"

    timestamp=$(date +%Y%m%d_%H%M%S)
    formatted_time=$(date +%H:%M:%S)
    output_file="/backup/Full_backup_${vm_name}_$timestamp.raw"

    echo "Preparing for ImageTransfer - Estimated  30s"

    log_trace "Preparing for ImageTransfer - sleep 30s"
    ./spinner1.sh 30
    echo "Checking available disk space:"
    df -h /backup
    log_trace "Checked available disk space"

    echo "Downloading image from URL: $imageTransfer_proxy_url"
    log_trace "Downloading image from URL: $imageTransfer_proxy_url"
    log_events "Starting image download"

    if [ "$imageTransfer_status" = "transferring" ]; then
      sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Transferring Image' WHERE vm_id='$vm_id_input';
EOF
      log_trace "Image transfer status set to 'Transferring Image'"

      # Ensure the status directory exists
      mkdir -p "/backup/status/$sanitized_vm_id"

      # Log file for download status
      status_log="/backup/status/$sanitized_vm_id/fullbackup_transfersize.txt"

      # Start the progress logging in the background
      {
        while :; do
          echo "$(date +'%Y-%m-%d %H:%M:%S') - Download in progress..." >> "$status_log"
          sleep 2
        done
      } &
      progress_pid=$!

      # Ensure the background process is killed when the script exits or is interrupted
      trap "kill $progress_pid" EXIT

      # Perform the download and log the progress
      {
        curl -k -H "Authorization: Bearer $bearer_Token" -o "$output_file" "$imageTransfer_proxy_url"
      } 2>&1 | tee -a "$status_log"

      # Explicitly kill the background logging loop after the download completes
      kill $progress_pid
      trap - EXIT
     
     # Echo the location of the log file after the download finishes
       echo "Download complete. Log file is located at: $status_log" | tee -a "$status_log"

  
      # Debugging step: Check if the file is being written
      echo "Checking if the file is being written..."
      ls -l "$output_file"
      ls_output=$(ls -l "$output_file")
      log_trace "Image file details: $ls_output"

      # Extract timestamp from the output_file
      timestamp=$(echo "$output_file" | sed 's/.*_\([0-9]\{8\}_[0-9]\{6\}\)\.raw/\1/')

      # Separate date and time using sed
      timestamp_date=$(echo "$timestamp" | sed 's/_.*//' | sed 's/\(....\)\(..\)\(..\)/\1-\2-\3/')
      timestamp_time=$(echo "$timestamp" | sed 's/.*_//' | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')
    
      # Extract Backup Filepath
      backupfile_Path=$(echo "$ls_output" | awk '{print $9}') 
       
      echo " "
      echo "Date: $timestamp_date"
      echo "Time: $timestamp_time" 
      echo "Backup_File Path: $backupfile_Path"
      echo " "
      log_trace "Date: $timestamp_date"
      log_trace "Time: $timestamp_time"
      log_trace "Backup_File Path: $backupfile_Path"

      # Check the size of the downloaded image
      if [ -f "$output_file" ]; then
        image_size=$(du -b "$output_file" | cut -f1)
        image_size_mb=$(echo "scale=2; $image_size/1024/1024" | bc)
        echo "Downloaded Image Size: $image_size_mb MB"
        log_trace "Downloaded Image Size: $image_size_mb MB"

        # Update the replication status to completed
        sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Replication SESSION Completed' WHERE vm_id='$vm_id_input';
EOF
        log_trace "Replication SESSION Completed"
        log_events "Image download completed"

        # Finalize the image transfer
        finalize_image_transfer "$imageTransfer_transferID"
        
      else
        echo "Image file does not exist: $output_file"
        log_trace "Image file does not exist: $output_file"
        sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Image File Missing' WHERE vm_id='$vm_id_input';
EOF
        log_events "Image file missing"
      fi
    else
      echo "Image Transfer & Download Failed"
      log_trace "Image Transfer & Download Failed"
      sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Image Transfer Failed' WHERE vm_id='$vm_id_input';
EOF
      log_events "Image transfer failed"
    fi
  fi
}

echo " "
echo "###########################################"
echo "#  Starting the Image Transfer Download   #"
echo "###########################################"
echo " "

process_imageTransferDownload

echo " "
echo "#######################################"
echo "#  Final Backup Session Table Contents #"
echo "#######################################"
echo " "

# Query the data to check if the table is populated
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
  while true; do
    echo "Polling finalization status for 10 seconds..."
    log_trace "Polling finalization status for 10 seconds..."
    ./spinner1.sh 10

    poll_finalize_backup=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input/backups/$fetchvmattribs_backupID")
    status_finalize_backup=$(echo "$poll_finalize_backup" | xmlstarlet sel -t -v "//backup/phase")

    echo "Current status: $status_finalize_backup"
    log_trace "Current status: $status_finalize_backup"

    if [ "$status_finalize_backup" = "ready" ]; then
      # Check for active image transfer
      echo "Checking for active image transfer..."
      log_trace "Checking for active image transfer..."
      image_transfer_status=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/imagetransfers/$fetchvmattribs_transferID" | xmlstarlet sel -t -v "//image_transfer/phase")

      echo "Image transfer status: $image_transfer_status"
      log_trace "Image transfer status: $image_transfer_status"

      if [ "$image_transfer_status" = "finished_success" ] || [ "$image_transfer_status" = "finished_failure" ]; then
        echo "Finalizing backup..."
        log_trace "Finalizing backup..."
        init_finalize_backup=$(curl -s -k -X POST -H "Accept: application/xml" -H "Content-Type:application/xml" -H "Authorization: Bearer $bearer_Token" -d "<action />"  "$url_Engine/api/vms/$vm_id_input/backups/$fetchvmattribs_backupID/finalize")
        
        # Display the response of the init_finalize_backup command
        echo "Response from finalization initiation:"
        echo "$init_finalize_backup"
        log_trace "Response from finalization initiation: $init_finalize_backup"

        # Adding a check to see if the finalization succeeded
        if [[ "$init_finalize_backup" == *"Internal Server Error"* ]]; then
          echo "Finalization initiation failed due to server error. Retrying..."
          log_trace "Finalization initiation failed due to server error. Retrying..."
          continue
        fi

        # Poll for the finalization status being succeeded or failed
        while true; do
          echo "Checking Backup finalization status for 20 seconds..."
          log_trace "Checking Backup finalization status for 20 seconds..."
          ./spinner1.sh 20

          poll_finalize_backup=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input/backups/$fetchvmattribs_backupID")
          status_finalize_backup=$(echo "$poll_finalize_backup" | xmlstarlet sel -t -v "//backup/phase")
          
          echo "Current Finalizing Backup status: $status_finalize_backup"
          log_trace "Current Finalizing Backup status: $status_finalize_backup"

          if [ "$status_finalize_backup" = "succeeded" ]; then
            sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='FINALIZED Replication' WHERE vm_id='$vm_id_input';
EOF
            log_trace "Backup finalization succeeded for VM ID: $vm_id_input"
            log_events "Backup finalization succeeded"
            break
          elif [ "$status_finalize_backup" = "failed" ]; then
            sqlite3 "$db_file" <<EOF
UPDATE backup_session_$sanitized_vm_id SET replication_status='Finalization Failed' WHERE vm_id='$vm_id_input';
EOF
            log_trace "Backup finalization failed for VM ID: $vm_id_input"
            log_events "Backup finalization failed"
            break
          fi
        done
        break
      else
        echo "Image transfer is still active. Retrying..."
        log_trace "Image transfer is still active. Retrying..."
      fi
    else
      echo "Backup is not ready, current status: $status_finalize_backup"
      log_trace "Backup is not ready, current status: $status_finalize_backup"
    fi
  done
}

finalize_backup

echo " "
echo "############################################# "
echo "# GRAND Final Backup Session Table Contents #"
echo "#############################################"
echo " "

# Query the data to check if the table is populated
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

  echo "$sanitized_tablename"
  echo " "
  echo " *Displaying Backup_Index DB to journal the entries* "
  echo " "
  log_trace "Updating Backup_Index DB for VM ID: $vm_id_input"

  # Create and update the sanitized table
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

INSERT INTO $sanitized_tablename (vm_id, vm_name, disk_id, Full_Backup, Backup_path, Checkpoint, Time, Date, Status, Size)
VALUES ('$vm_id_input', '$fetchvmattribs_vmName', '$fetchvmattribs_diskID', 1, '$backupfile_Path', '$fetchvmattribs_checkpoint', '$timestamp_time', '$timestamp_date', '$fetchvmattribs_status', '$image_size_mb');
EOF

  # Show all details in the new table
  echo "Details in Table $sanitized_tablename :"
  log_trace "Details in Table $sanitized_tablename"
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


# Query the database to get the RPO value in minutes
rpo_minutes=$(sqlite3 vmSettings.db  "SELECT rpo FROM vmAttribs WHERE vmId='$vm_id_input';")

echo " "
echo " RPO : $rpo_minutes minutes"
echo " "


# Calculate the crontab schedule based on RPO in minutes
cron_schedule="*/$rpo_minutes * * * *"


# Add a crontab entry to run incrementalSource_v21.sh every 60 minutes
echo " Adding incremnental backup in scheduler....."
#(crontab -l ; echo "$cron_schedule /root/incrementalSource_v21.sh $vm_id_input") | crontab -
(crontab -l; echo "$cron_schedule PATH=/usr/local/bin:/usr/bin:/bin /root/incrementalSource_v21.sh $vm_id_input >> /backup/tmp/incrementalSource_v21_$vm_id_input.log 2>&1") | crontab -


# Verify if the entry was added
if crontab -l | grep -q "/root/incrementalSource_v21.sh $vm_id_input"; then
    echo "Crontab entry added successfully."
else
    echo "Failed to add crontab entry."
fi


# Fetch retention_days and RPO (in minutes) from the vmAttribs table in vmSettings.db based on vm_id_input
retention_days=$(sqlite3 "vmSettings.db" <<EOF
SELECT retentionPeriod FROM vmAttribs WHERE vmId='$vm_id_input';
EOF
)

RPO=$(sqlite3 "vmSettings.db" <<EOF
SELECT rpo FROM vmAttribs WHERE vmId='$vm_id_input';
EOF
)



# Ensure that retention_days and RPO have values, otherwise set defaults
if [ -z "$retention_days" ]; then
    retention_days="NULL"  # Set Retention to NULL
fi

if [ -z "$RPO" ]; then
    RPO="NULL"  # Set RPO to NULL if not available
fi


# Read size, status, and backupfile_Path from the latest entry in table_BI_$sanitized_vm_id
IFS='|' read -r size status backupfile_Path <<< $(sqlite3 "$backup_index_db" <<EOF
SELECT Size, Status, Backup_path FROM table_BI_$sanitized_vm_id ORDER BY id DESC LIMIT 1;
EOF
)

echo "$status"


# Creating a backup table with a dynamic name based on the VM ID
backup_table_name="backupindex_VM_$sanitized_vm_id"

sqlite3 "$backup_index_db" <<EOF
CREATE TABLE IF NOT EXISTS $backup_table_name (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    checkpoint TEXT,
    backup_date TEXT NOT NULL,
    backup_time TEXT NOT NULL,
    backup_type TEXT NOT NULL,
    backup_path TEXT NOT NULL,
    size REAL,
    status TEXT NOT NULL,
    retention_days INTEGER NOT NULL,
    RPO INTEGER,  
    previous_run_date TEXT,  
    next_run_date TEXT, 
    next_run_date_checker INTEGER DEFAULT 0  
);
EOF

# Calculate next_run_date by adding retention_days to the date part only, and then combining it with the original time
next_run_date=$(date -d "$timestamp_date + $retention_days days" +"%Y-%m-%d")" $timestamp_time"

echo $next_run_date


# Insert the backup details into the newly created table
sqlite3 "$backup_index_db" <<EOF
INSERT INTO $backup_table_name (
    checkpoint, 
    backup_date, 
    backup_time, 
    backup_type, 
    backup_path, 
    size, 
    status, 
    retention_days, 
    RPO,
    previous_run_date,
    next_run_date,
    next_run_date_checker

) VALUES (
    '$fetchvmattribs_checkpoint', 
    '$timestamp_date', 
    '$timestamp_time', 
    'Full Backup', 
    '$backupfile_Path', 
    '$image_size_mb', 
    '$status', 
    '$retention_days', 
    $RPO,
    NULL,  
    '$next_run_date', 
    0  
);
EOF

echo "Backup details inserted into table $backup_table_name"
log_trace "Backup details inserted into table $backup_table_name"
log_events "Backup details inserted into table $backup_table_name"

# Display the contents of the backupindex_VM_$sanitized_vm_id table
echo "#########################################"
echo "# Contents of backupindex_VM_$sanitized_vm_id Table #"
echo "#########################################"

sqlite3 "$backup_index_db" <<EOF
.header on
.mode column
SELECT * FROM backupindex_VM_$sanitized_vm_id;
EOF


echo "Duration of the script: $elapsed_time seconds"
log_trace "Duration of the script: $elapsed_time seconds"
log_events "Duration of the script: $elapsed_time seconds"

# At the end of the script - Remove the backup_session database
if [ -f "$db_file" ]; then
    rm "$db_file"
    log_trace "Removed backup session database file: $db_file"
fi

echo "================================="
echo "  SCHEDULING ASPAR COMPONENTS    "
echo "================================="
echo " "

# Insert cron entry for ML scripting
echo "Insert cron entry for ML scripting"
log_trace "Schedule ML aspar"
log_events "Schedule ML aspar"

# Fetch the RPO value from the database for the given vm_id_input
rpo=$(sqlite3 /root/vmSettings.db "SELECT RPO FROM vmAttribs WHERE vmId = '$vm_id_input'")
echo "RPO: $rpo"

# Validate RPO
if [[ -z "$rpo" || ! "$rpo" =~ ^[0-9]+$ ]]; then
  echo "Error: Invalid RPO for vm_id $vm_id_input"
  exit 1
fi

# Calculate cron schedule
minute=$((rpo + 2))

# Define ML cron entry
cron_entry="*/$minute * * * * PATH=/usr/local/bin:/usr/bin:/bin /root/myenv/bin/python /root/ransomware_ML_analysis.py $vm_id_input >> /backup/tmp/ransom_$vm_id_input.txt 2>&1"

echo "Scheduled ML entry: $cron_entry"

# Add ML cron job
(crontab -l 2>/dev/null | grep -v "ransomware_ML_analysis.py $vm_id_input"; echo "$cron_entry") | crontab -

# Insert cron entry for AI ransomware analytics
APSAR_Model=$(sqlite3 /root/vmSettings.db "SELECT APSAR_Model FROM vmAttribs WHERE vmId = '$vm_id_input'")
echo "APSAR_Model: $APSAR_Model"

# Calculate xminute (RPO * 2)
xminute=$((rpo * 2))

# Determine the correct AI ransomware script
if [[ "$APSAR_Model" == "Gemini" ]]; then
  xcron_entry="*/$xminute * * * * PATH=/usr/local/bin:/usr/bin:/bin /root/ransomware_gemini.sh $vm_id_input >> /backup/tmp/ransom_$vm_id_input.txt 2>&1"
elif [[ "$APSAR_Model" == "Grok" ]]; then
  xcron_entry="*/$xminute * * * * PATH=/usr/local/bin:/usr/bin:/bin /root/ransomware_grok.sh $vm_id_input >> /backup/tmp/ransom_$vm_id_input.txt 2>&1"
elif [[ "$APSAR_Model" == "OpenAI" ]]; then
  xcron_entry="*/$xminute * * * * PATH=/usr/local/bin:/usr/bin:/bin /root/ransomware_openai.sh $vm_id_input >> /backup/tmp/ransom_$vm_id_input.txt 2>&1"
else
  echo "Error: Unknown APSAR_Model ($APSAR_Model). No cron job scheduled."
  exit 1
fi

echo "Scheduled AI entry: $xcron_entry"

# Add AI cron job
(crontab -l 2>/dev/null | grep -v "ransomware_.*.sh $vm_id_input"; echo "$xcron_entry") | crontab -


echo " "
# Registering the active_replication entry
# Insert into vmSettings.db

# Extract source_host and target_host using sqlite3
SOURCE_HOST=$(sqlite3 /root/vmSettings.db "SELECT host_ip FROM Source LIMIT 1;")
TARGET_HOST=$(sqlite3 /root/vmSettings.db "SELECT host_ip FROM Target LIMIT 1;")


sqlite3 /root/vmSettings.db <<EOF
CREATE TABLE IF NOT EXISTS active_replications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  vmid TEXT,
  vm_name TEXT,
  source_host TEXT,
  target_host TEXT,
  last_synced_date TEXT,
  last_synced_time TEXT,
  rpo INTEGER,
  status TEXT
);

INSERT INTO active_replications (
  vmid, vm_name, source_host, target_host, last_synced_date, last_synced_time, rpo, status
) VALUES (
  '$vm_id_input', '$vm_name', '$SOURCE_HOST', '$TARGET_HOST', '$timestamp_date', '$timestamp_time', $rpo, 'Active: FailOver Ready'
);
EOF

echo " "

sqlite3 -header -column /root/vmSettings.db "SELECT * FROM active_replications;"


# At the end of the script, after all backup steps are completed
if [ $? -eq 0 ]; then
    # Update status in table_jobid
    sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Completed' WHERE job_id = $job_id;"
    echo "Backup completed successfully." >> "$log_events"
    echo "BACKUP_COMPLETION_SIGNAL"
    exit 0
else
    # Update status at the end (optional)
    sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Failed' WHERE job_id = $job_id;"
    echo "Backup failed." >> "$log_events"
    echo "BACKUP_FAILED_SIGNAL"
    exit 1
fi

