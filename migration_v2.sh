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
backupfile_Path=""
qcow2_file=""

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
echo "----------------------"
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
echo " Starting Backup "
echo "-----------------"
echo " "


init_start_query=$(curl -s -k -X POST -H "Accept: application/xml" -H "Content-Type:application/xml" -H "Authorization: Bearer $bearer_Token" -d "<backup><disks><disk id=\"$disk_ids\" /></disks></backup>" "$url_Source/api/vms/$vm_id_input/backups")
      init_start_status=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/phase")
      init_start_backupID=$(echo "$init_start_query" | xmlstarlet sel -t -v "//backup/@id")
      if [ "$init_start_status" = "starting" ]; then
        echo " "
        echo "Backup initialization started for VM ID: $vm_id_input, Backup ID: $init_start_backupID" 
        log_trace "Backup initialization started for VM ID: $vm_id_input, Backup ID: $init_start_backupID"
        log_events "Backup initialization started"
        echo " "
      else
        echo " "
        echo " Backup initilization Failed..."
        log_trace "Backup initialization failed for VM ID: $vm_id_input"
        log_events "Backup initialization failed"
      fi

# Poll Backup Status until it's ready
echo " Poll Backup "
echo "-------------"
echo " "


      while true; do
        echo "Checking & Polling if Backup is ready..."
        log_trace "Checking if backup is ready..."
        /root/spinner1.sh 30
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
echo "----------------------"

log_trace  "Starting ImageTransfer"
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
    /root/spinner1.sh 30
    echo "Checking available disk space:"
    df -h /backup
    log_trace "Checked available disk space"
    echo " "

    echo "Downloading image from URL: $imageTransfer_proxy_url"
    log_trace "Downloading image from URL: $imageTransfer_proxy_url"
    log_events "Starting image download"


 if [ "$imageTransfer_status" = "transferring" ]; then

      output_file="/backup/migration/migration_${vm_name}_$timestamp.raw"
      echo "Preparing for ImageTransfer - Estimated  30s"

       log_trace "Preparing for Download"
       log_events "Preparing for Download"

      # Perform the download and log the progress

        curl -k -H "Authorization: Bearer $bearer_Token" -o "$output_file" "$imageTransfer_proxy_url"


     # log file after the download finishes
       log_events "Download complete"

      # Debugging step: Check if the file is being written
      echo "Checking if the file is being written..."
      ls -l "$output_file"
      ls_output=$(ls -l "$output_file")
      log_trace "Image file details: $ls_output"

      # Extract Backup Filepath
      backupfile_Path=$(echo "$ls_output" | awk '{print $9}')

      echo " "
      echo "Backup_File Path: $backupfile_Path"
      echo " "
      log_trace "Backup_File Path: $backupfile_Path"

      # Check the size of the downloaded image
      if [ -f "$output_file" ]; then
        image_size=$(du -b "$output_file" | cut -f1)
        image_size_mb=$(echo "scale=2; $image_size/1024/1024" | bc)
        echo "Downloaded Image Size: $image_size_mb MB"
        log_trace "Downloaded Image Size: $image_size_mb MB"
    fi
fi 

# Finalize the image transfer
echo " Finalize the image transfer "
echo "-----------------------------"
        echo " "
        echo "Finalizing backup for VM ID: $vm_id_input, Backup ID: $init_start_backupID"
         log_trace "Finalizing backup for VM ID: $vm_id_input, Backup ID: $init_start_backupID"
         log_events "Finalizing backup"

             # Poll for the backup status being ready and initiate finalization
               while true; do
                   echo "Polling finalization status for 10 seconds..."
                   log_trace "Polling finalization status for 10 seconds..."
                   log_events "Polling finalization status for 10 seconds..."
                   /root/spinner1.sh 10

                    poll_finalize_backup=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Source/api/vms/$vm_id_input/backups/$init_start_backupID")
                    status_finalize_backup=$(echo "$poll_finalize_backup" | xmlstarlet sel -t -v "//backup/phase")

                    echo "Current status: $status_finalize_backup"
                    log_trace "Current status: $status_finalize_backup"

                            if [ "$status_finalize_backup" = "ready" ]; then
                                # Check for active image transfer
                                echo "Checking for active image transfer..."
                                log_trace "Checking for active image transfer..."
                                 image_transfer_status=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Source/api/imagetransfers/$imageTransfer_transferID" | xmlstarlet sel -t -v "//image_transfer/phase")

                                  echo "Image transfer status: $image_transfer_status"
                                  log_trace "Image transfer status: $image_transfer_status"

      if [ "$image_transfer_status" = "finished_success" ] || [ "$image_transfer_status" = "finished_failure" ]; then
        echo "Finalizing backup..."
        log_trace "Finalizing backup..."
        init_finalize_backup=$(curl -s -k -X POST -H "Accept: application/xml" -H "Content-Type:application/xml" -H "Authorization: Bearer $bearer_Token" -d "<action />"  "$url_Source/api/vms/$vm_id_input/backups/$init_start_backupID/finalize")

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
          /root/spinner1.sh 20

          poll_finalize_backup=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Source/api/vms/$vm_id_input/backups/$init_start_backupID")
          status_finalize_backup=$(echo "$poll_finalize_backup" | xmlstarlet sel -t -v "//backup/phase")

          echo "Current Finalizing Backup status: $status_finalize_backup"
          log_trace "Current Finalizing Backup status: $status_finalize_backup"

          if [ "$status_finalize_backup" = "succeeded" ]; then
            echo " "
            echo " Backup finalization succeeded for VM ID: $vm_id_input"
            log_trace "Backup finalization succeeded for VM ID: $vm_id_input"
            log_events "Backup finalization succeeded"
            break
          elif [ "$status_finalize_backup" = "failed" ]; then
            echo " "
            echo " Backup finalization failed for VM ID: $vm_id_input "
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


echo " "
echo "********************************"
echo "* BACKUP COMPLETED SUCCESFULLY *"
echo "********************************"

}

echo "######################################################"
echo "# STEP 1 : Start the Full Backup -Init Replication   #"
echo "######################################################"

log_trace "Start the Replication  process "
log_events "Start the Replication process"

# Call the init_replication function
init_replication




init_recovery() {

#Fetch Target Token

echo " "
echo "Fetch Target Token"
echo "------------------"

# Fetch the token using curl and parse it with jq
         bearer_TokenTarget=$(curl -s -k --header Accept:application/json "$url_getTokenTarget" | jq -r '.access_token')

# Hash the token
hashed_tokenTarget=$(echo -n "$bearer_TokenTarget" | sha256sum | awk '{print $1}')

echo "Token fetched (hashed): $hashed_tokenTarget"
echo " "
log_trace "Token fetched (hashed): $hashed_tokenTarget"
log_events "Token fetched successfully"

# Check if the token was successfully fetched
if [ -z "$bearer_TokenTarget" ]; then
  echo "Failed to fetch access token"
  log_trace "Failed to fetch access token"
  log_events "Failed to fetch access token"
  exit 1
fi

echo " "
echo "+++++++++" 
echo "|STEP 1 |"
echo "+++++++++"

# Convert the Backup raw file to QCOW2 format
  echo "STEP 1: Converting the Backup  raw backup file to QCOW2 format..."

log_trace " Converting the Backup raw backup file to QCOW2 format..."
log_events " Converting the Backup  raw backup file to QCOW2 format... "

echo " Backup File Path : $backupfile_Path"
qcow2_file="${backupfile_Path%.raw}.qcow2"
qemu-img convert -p -f raw -O qcow2 -o cluster_size=2M -c "$backupfile_Path" "$qcow2_file"
echo " "
echo "QCOW2 conversion completed: $qcow2_file"

echo " "
echo "+++++++++"
echo "|STEP 2 |"
echo "+++++++++"

# Create a new disk in the storage domain hosted_storage with the correct virtual size
  echo "STEP 2: Create a new disk in the storage domain hosted_storage with the correct virtual size...." 

log_trace " Create a new disk in the storage domain hosted_storage with the correct virtual size"
log_events "  Create a new disk in the storage domain hosted_storage with the correct virtual size"

 echo "Creating a new disk in the storage domain hosted_storage..."
  virtual_size=$(qemu-img info --output=json "$qcow2_file" | jq -r '.["virtual-size"]')
  new_disk_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
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
       "$url_Target/api/disks")
  echo "Disk creation response: $new_disk_response"
  new_disk_id=$(echo "$new_disk_response" | xmlstarlet sel -t -v "//disk/@id")
  echo "Created new disk with ID: $new_disk_id"
  log_trace "Created new disk with ID: $new_disk_id"

# Wait until disk status is OK
  while true; do
    disk_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" "$url_Target/api/disks/$new_disk_id" | xmlstarlet sel -t -v "//disk/status")
    echo "Disk status: $disk_status"
    if [[ "${disk_status,,}" == "ok" ]]; then
      break
    fi
    echo "Waiting for disk to be ready..."
    sleep 5
  done

echo " "
echo "+++++++++"
echo "|STEP 3 |"
echo "+++++++++"

log_trace " Enable incremental backup for the newly uploaded QCOW2 disk"
log_events " Enable incremental backup for the newly uploaded QCOW2 disk"

  # Enable incremental backup for the newly uploaded QCOW2 disk
  echo "STEP 3: Enabling incremental backup for the new QCOW2 disk..."
  enable_backup_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
       -d "<disk>
              <backup>incremental</backup>
           </disk>" \
       "$url_Target/api/disks/$new_disk_id")
  echo "Incremental backup enable response: $enable_backup_response"

  # Ensure the disk is unlocked before starting the image transfer
  while true; do
    disk_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" "$url_Target/api/disks/$new_disk_id" | xmlstarlet sel -t -v "//disk/status")
    echo "Disk status: $disk_status"
    if [[ "${disk_status,,}" != "locked" ]]; then
      break
    fi
    echo "Waiting for disk to be unlocked..."
    sleep 5
  done

echo " "
echo "+++++++++"
echo "|STEP 4 |"
echo "+++++++++"

log_trace " Creating a new Migrated VM "
log_events " Creating a new Migrated VM "


 # Create a new VM with the original VM name and _Recovered suffix
  restored_vm_name="${vm_name}_MIGRATED_$timestamp"
  echo "STEP 4 : Creating a new VM with name $restored_vm_name..."
  create_vm_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
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
       "$url_Target/api/vms")
  echo "VM creation response: $create_vm_response"
restored_vm_id=$(echo "$create_vm_response" | xmlstarlet sel -t -v "//vm/@id")
  echo "Created new VM with ID: $restored_vm_id"

  # Wait until the VM is down
  while true; do
    vm_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" "$url_Target/api/vms/$restored_vm_id" | xmlstarlet sel -t -v "//vm/status")
    echo "VM status: $vm_status"
    if [[ "${vm_status,,}" == "down" ]]; then
      break
    fi
    echo "Waiting for VM to be in down state..."
    sleep 5
  done

echo " "
echo "+++++++++"
echo "|STEP 5 |"
echo "+++++++++"

log_trace "  Create an image transfer to upload the QCOW2 file"
log_events "  Create an image transfer to upload the QCOW2 file"

  # Create an image transfer to upload the QCOW2 file
  echo "STEP 5: Creating an image transfer to upload the QCOW2 file..."
  image_transfer_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
       -d "<image_transfer>
              <disk id='$new_disk_id' />
              <direction>upload</direction>
              <format>cow</format>
           </image_transfer>" \
       "$url_Target/api/imagetransfers")
  echo "Image transfer creation response: $image_transfer_response"

  transfer_id=$(echo "$image_transfer_response" | xmlstarlet sel -t -v "//image_transfer/@id")
  transfer_proxy_url=$(echo "$image_transfer_response" | xmlstarlet sel -t -v "//image_transfer/proxy_url")
  echo "Created image transfer with ID: $transfer_id"
  echo "Transfer proxy URL: $transfer_proxy_url"
  
  # Upload QCOW2 file using ImageIO API
  echo "Uploading QCOW2 file to the new disk..."
  
  curl -k --progress-meter --upload-file "$qcow2_file" "$transfer_proxy_url"

echo " "
echo "+++++++++"
echo "|STEP 6 |"
echo "+++++++++"

log_trace "Finalize Image Transfer"
log_events " Finalize Image Transfer"


  # Finalize Image Transfer
  echo "STEP 6: Finalizing the image transfer..."
  finalize_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
       -d "<action />" \
       "$url_Target/api/imagetransfers/$transfer_id/finalize")
  echo "Finalize response: $finalize_response"

  # Ensure Disk is Ready for Attachment
  echo "Ensuring the disk is fully ready before attachment..."
  while true; do
    disk_transfer_phase=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
      "$url_Target/api/imagetransfers/$transfer_id" | xmlstarlet sel -t -v "//image_transfer/phase")
    echo "Disk transfer phase: $disk_transfer_phase"
    if [[ "${disk_transfer_phase,,}" == "finished_success" ]]; then
      break
    fi
    echo "Waiting for disk transfer to finish..."
    sleep 5
  done

echo " "
echo "+++++++++"
echo "|STEP 7 |"
echo "+++++++++"

log_trace "Attaching the new disk to the new VM.."
log_events " Attaching the new disk to the new VM.."


# Ensure disk is not locked before attaching
  echo "Checking disk status before attachment..."
  while true; do
    disk_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" "$url_Target/api/disks/$new_disk_id" | xmlstarlet sel -t -v "//disk/status")
    echo "Disk status: $disk_status"
    if [[ "${disk_status,,}" == "ok" ]]; then
      break
    fi
    echo "Waiting for disk to be ready for attachment..."
    sleep 5
  done

  # Attach the disk to the VM
  echo "STEP 7 : Attaching the new disk to the new VM..."
  disk_attachment_data="<disk_attachment>
                          <bootable>true</bootable>
                          <interface>virtio_scsi</interface>
                          <active>true</active>
                          <disk id='$new_disk_id' />
                        </disk_attachment>"

  attach_disk_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
    -d "$disk_attachment_data" "$url_Target/api/vms/$restored_vm_id/diskattachments")
  echo "Disk attachment response: $attach_disk_response"
  log_trace "Attached disk $new_disk_id to VM $restored_vm_id"

echo " "
echo "+++++++++"
echo "|STEP 8 |"
echo "+++++++++"

log_trace "Activate the Network Interface  "
log_events "Activate the Network Interface"

echo " STEP 8 : Activate the Network Interface  "

# Get vNIC profile ID for 'ovirtmgmt'
  echo "Fetching vNIC profile ID for 'ovirtmgmt'..."
  vnic_profile_id=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
       "$url_Target/api/vnicprofiles" | xmlstarlet sel -t -m "//vnic_profile[name='ovirtmgmt']" -v "@id")
  if [ -z "$vnic_profile_id" ]; then
    echo "Error: vNIC profile 'ovirtmgmt' not found."
    exit 1
  fi
  echo "vNIC profile ID for 'ovirtmgmt': $vnic_profile_id"

  # Add Network Interface to the VM with vNIC profile 'ovirtmgmt'
  echo "Adding network interface to the new VM with vNIC profile 'ovirtmgmt'..."
  nic_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
       -d "<nic>
              <name>nic1</name>
              <vnic_profile id='$vnic_profile_id'/>
              <interface>virtio</interface>
           </nic>" \
       "$url_Target/api/vms/$restored_vm_id/nics")
  echo "Network interface creation response: $nic_response"
  nic_id=$(echo "$nic_response" | xmlstarlet sel -t -v "//nic/@id")
  echo "Added network interface with ID: $nic_id to VM: $restored_vm_id"

echo "Activating the network interface..."
  activate_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" \
       -d "<action />" \
       "$url_Target/api/vms/$restored_vm_id/nics/$nic_id/activate")
  echo "Network interface activation response: $activate_response"
  log_trace "Network interface activation response: $activate_response"

echo " "
echo "+++++++++"
echo "|STEP 9 |"
echo "+++++++++"

log_trace "Rename the Migrated VM  "
log_events "Rename the Migrated VM "

  echo "STEP 9 : Renaming the Migrated VM......"

# Fetch oVirt API token for original VM
    echo "Fetching oVirt API token for original VM..."
    bearer_Token_Source=$(curl -s -k --header Accept:application/json "$url_getTokenSource" | jq -r '.access_token')

    if [ -z "$bearer_Token_Source" ]; then
        echo "Error: Failed to fetch oVirt API token for original VM."
        exit 1
    fi
    echo "Token fetched for original VM."

    # Get the vm_name for original_vmid using oVirt API
    echo "Getting VM name for original_vmid: $original_vmid"
    response=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token_Source" "$url_Source/api/vms/$vm_id_input")
    vm_name=$(echo $response | jq -r '.name')
    if [[ -z "$vm_name" || "$vm_name" == "null" ]]; then
        echo "Error: Failed to get VM name for original_vmid: $vm_id_input"
        exit 1
    fi
    echo "Original VM Name: $vm_name"

log_trace " Shutdown the original_vmid "
log_events " Shutdown the original_vmid"

    # Shutdown the original_vmid
    echo "Sending shutdown command to original VM: $vm_id_input"
    shutdown_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token_Source" -d "<action/>" "$url_Source/api/vms/$vm_id_input/shutdown")

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
        status_response=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token_Source" "$url_Source/api/vms/$vm_id_input")

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
    echo "Renaming original VM to ${vm_name}_MIGRATED"
    rename_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token_Source" -d "<vm><name>${vm_name}_MIGRATED</name></vm>" "$url_Source/api/vms/$vm_id_input")
    if [[ "$rename_response" == *"<fault>"* ]]; then
        echo "Error: Failed to rename the original VM."
        exit 1
    fi
    echo "Original VM renamed to ${vm_name}_Migrated."

log_trace "  Original VM renamed to ${vm_name}_Migrated."
log_events " Original VM renamed to ${vm_name}_Migrated"

# Get the vm_name for restored_vmid using oVirt API
    echo "Getting VM name for restored_vmid: $restored_vm_id"

    response1=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_TokenTarget" "$url_Target/api/vms/$restored_vm_id")
    echo "$response1"
    restored_vm_name=$(echo $response1 | jq -r '.name')
    if [[ -z "$restored_vm_name" || "$restored_vm_name" == "null" ]]; then
        echo "Error: Failed to get VM name for restored_vmid: $restored_vm_id"
        exit 1
    fi
    echo "Restored VM Name: $restored_vm_name"

    # Change the vm_name of Migrated VM
    echo "Changing name of Migrated VM to $vm_name"
    rename_new_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" -d "<vm><name>$vm_name</name></vm>" "$url_Target/api/vms/$restored_vm_id")
    echo "Recovered VM name set to: $vm_name"

    # Check if the renaming was successful
    if [[ "$rename_new_response" == *"<fault>"* ]]; then
        echo "Error: Failed to rename the recovered VM."
        exit 1
    fi

    echo " "
    echo "==========================================="
    echo "VM $vm_name successfully MIGRATED"
    echo "==========================================="

# Start the recovered VM
    echo "Starting the recovered VM with name $vm_name and ID: $restored_vm_id..."
    start_vm_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_TokenTarget" -d "<action/>" "$url_Target/api/vms/$restored_vm_id/start")
    echo "Start VM response: $start_vm_response"

    # Check if the start operation was successful
    if [[ "$start_vm_response" == *"<fault>"* ]]; then
        echo "Error: Failed to start the recovered VM."
        exit 1
    fi
    
    echo " "
    echo "Recovered VM with name $vm_name and ID: $restored_vm_id STARTED successfully."
    echo "------------------------------------------------------------------------------------------"
    echo " "
}

echo " "
echo "######################################################"
echo "# STEP 2: Start Recovery Process to Target DR        #"
echo "######################################################"


log_trace "Start the Recovery process "
log_events "Start the Recovery process"

# Call the init_replication function
init_recovery


cleanup () {

echo "Let's start the cleanup"
echo "======================="

echo "Listing files in /backup/tmp..."
  ls -lh /backup/migration
  echo " "

  echo "Stat files before deletion:"
  stat "$backupfile_Path"
  stat "$qcow2_file"
  echo " "

  echo "Cleaning up temporary files..."
  rm -f "$backupfile_Path"
  rm -f "$qcow2_file"
  echo "Temporary files deleted."
  echo " "

log_trace "Cleanup Process Completed "
log_events "Cleanup Process Completed "

}

log_trace "Cleanup Process Started "
log_events "Cleanup Process Started"

echo " "
echo "######################################################"
echo "# STEP 3 : Cleanup                                   #"
echo "######################################################"

cleanup


sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Completed' WHERE job_id = '$job_id';"

log_trace " Recovery for $vm_name with VM ID: $vm_id_input  COMPLETED "
log_events " Recover for $vm_name with VM ID: $vm_id_input  COMPLETED "

log_trace " ======================================================================= "
log_events " ======================================================================= "


