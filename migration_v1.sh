#!/bin/bash
# Capture start time
start_time=$(date +%s)
echo " "
echo "#########################"
echo " KVMDR Replicator MVP"
echo " Release : Winter '25 "
echo " Codename: M2_Kent   "
echo "#########################"
echo " "
echo "<----Branch for Migration---- >"
echo "________________________________"
echo " "
# Environment Variables
vm_id_input="$1"
sanitized_vm_id=$(echo "$vm_id_input" | sed 's/[^a-zA-Z0-9]//g')
sanitized_tablename="table_BI_$sanitized_vm_id"
timestamp=$(date +%Y%m%d%H%M%S)
trace_log="/kvmdr/log/migration/$vm_id_input/trace_$timestamp.log"
log_events="/kvmdr/log/migration/$vm_id_input/events_$timestamp.log"
url_Source="https://engine.local/ovirt-engine"
url_getTokenSource="$url_Source/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"
url_Target="https://dr.local/ovirt-engine"
url_getTokenTarget="$url_Target/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"
backup_index_db="Backup_Index.db"
jobid_db="/root/vmSettings.db"
job_type="Migration"
echo " "
echo "Timestamp: $timestamp"  # Ensure this is part of the script's output
echo " "
# Write the timestamp to a file named timestamp_<vmid>.txt
echo "${timestamp}" > "/tmp/timestamp_migration${vm_id_input}.txt"
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
#Starting the Logs
log_trace "=====================Starting the Log====================="
log_events "=====================Starting the Log====================="
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
# Fetch a new oVirt API token using curl
echo "Fetching oVirt API token..."
log_trace "Fetching oVirt API token..."
log_events "Fetching oVirt API token..."
# Fetch the token using curl and parse it with jq
bearer_Token=$(curl -s -k --header Accept:application/json "$url_getTokenSource" | jq -r '.access_token')
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
vm_details=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Source/api/vms/$vm_id_input")
# Parse VM details using jq
vm_name=$(echo "$vm_details" | jq -r '.name')
vm_status=$(echo "$vm_details" | jq -r '.status')
log_trace " Inserting vm name into table_jobid"
log_events " Inserting vm name into table_jobid"
echo " VM Name: $vm_name"
echo " "
sqlite3 "$jobid_db" "UPDATE table_jobid SET vm_name = '$vm_name' WHERE vm_id = '$vm_id_input';"
# TASK Push
# Query to fetch vm_name, status, and job_type for a specific job_id
taskquery="SELECT vm_name, status, job_type FROM table_jobid WHERE job_id='$job_id';"
# Fetch and process the query result
taskresult=$(sqlite3 "$jobid_db" "$taskquery")
status="Running"
# Debug: Log the raw query result
echo "Task: Raw Query Result: $taskresult"
# Check if result is not empty
if [ -n "$taskresult" ]; then
  # Split the result into variables
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
log_trace " Tasks Updated "
log_events " Tasks Updated  "



# Start Full Backup
init_replication() {
# Get the Disk details
echo " Get the Disk Details "
echo " "
disk_response=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Source/api/vms/$vm_id_input/diskattachments")
disk_ids=$(echo "$disk_response" | xmlstarlet sel -t -m "//disk_attachment/disk" -v "@id" -n | tr '\n' ',')
disk_ids=${disk_ids%,}  # Remove trailing comma
echo "VM ID: $vm_id_input"
echo "Disk IDs: $disk_ids"
echo " "
log_trace "Fetched disk IDs for VM: $disk_ids"
log_events "Fetched disk details for VM"
# Starting Backup
init_start_query=$(curl -s -k -X POST -H "Accept: application/xml" -H "Content-Type:application/xml" -H "Authorization: Bearer $bearer_Token" -d "<backup><disks><disk id=\"$disk_ids\" /></disks></backup>" "$url_Source/api/vms/$vm_id_input/backups")
      init_start_status=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/phase")
      init_start_backupID=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/@id")
      if [ "$init_start_status" = "starting" ]; then
        echo " "
        echo "Backup initialization started for VM ID: $vm_id_input, Backup ID: $init_start_backupID" 
        log_trace "Backup initialization started for VM ID: $vm_id_input, Backup ID: $init_start_backupID"
        log_events "Backup initialization started"
      else
        echo " "
        echo " Backup initilization Failed..."
        log_trace "Backup initialization failed for VM ID: $vm_id_input"
        log_events "Backup initialization failed"
      fi
# Poll Backup Status until it's ready
      while true; do
        echo "Checking & Polling if Backup is ready..."
        log_trace "Checking if backup is ready..."
        ./spinner1.sh 30
        init_status_query=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Source/api/vms/$vm_id_input/backups/$init_start_backupID")
        init_status_phase=$(echo "$init_status_query" | xmlstarlet sel -t -v "//backup/phase")
        init_status_checkpoint=$(echo "$init_status_query" | xmlstarlet sel -t -v "//backup/to_checkpoint_id" 2>/dev/null || true)
        if [ "$init_status_phase" = "ready" ]; then
          echo " "
          echo " Backup ready for VM ID: $vm_id_input "
          log_trace "Backup ready for VM ID: $vm_id_input"
          log_events "Backup ready"
          break
        else
          echo "Backup not ready, continuing to check..."
          log_trace "Backup not ready, continuing to check..."
        fi
      done
# Starting imageTransfer
echo " "
echo "Starting ImageTransfer"
log_trace "Starting ImageTransfer"
log_events "Starting ImageTransfer"
echo " "
imageTransfer_start=$(curl -s -k -X POST -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $bearer_Token" -d "{\"disk\":{\"id\":\"$disk_ids\"},\"backup\":{\"id\":\"$init_start_backupID\"},\"direction\":\"download\",\"format\":\"raw\",\"inactivity_timeout\":120}" "$url_Source/api/imagetransfers")
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
    else
      echo "No tranfer ID" 
    fi
    # Debugging step: Print the extracted transfer ID
    echo "Extracted Transfer ID: $imageTransfer_transferID"
    echo "To Checkpoint ID: $imageTransfer_to_checkpoint"
    log_trace "Extracted Transfer ID: $imageTransfer_transferID"
    log_trace "To Checkpoint ID: $imageTransfer_to_checkpoint"
# Setting download directory
    echo "Preparing for ImageTransfer - Estimated  30s"
    echo " "
    log_trace "Preparing for ImageTransfer - sleep 30s"
    log_events "Preparing for ImageTransfer"
    ./spinner1.sh 30
    echo "Checking available disk space:"
    df -h /backup
    log_trace "Checked available disk space"
    echo " "
    echo "Downloading image from URL: $imageTransfer_proxy_url"
    log_trace "Downloading image from URL: $imageTransfer_proxy_url"
    log_events "Starting image download"
if [ "$imageTransfer_status" = "transferring" ]; then
      log_trace "Image transfer status set to 'Transferring Image'"
      # Ensure the status directory exists
      mkdir -p "/backup/status/$sanitized_vm_id"
      # Perform the download and log the progress
        curl -k -H "Authorization: Bearer $bearer_Token" -o "$output_file" "$imageTransfer_proxy_url"
     # Echo the location of the log file after the download finishes
       echo "Download complete. Log file is located at: $status_log" | tee -a "$status_log"
       log_events "Download complete"
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
      else
        echo "Download Failed"
     fi
else
  echo "Image Transfer Failed"
fi


}

echo "######################################################"
echo "# STEP 1 : Start the Full Backup -Init Replication   #"
echo "######################################################"


# Call the init_replication function
init_replication
