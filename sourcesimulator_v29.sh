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
OS_type="alpine"
#OS_type="redhat"  # Hardcoded OS type (candidate for setting DB)
jobid_db="/root/vmSettings.db"                                                                                                      
job_type="Simulator"   


echo " "                                                                                                                            
echo "Timestamp: $timestamp"  # Ensure this is part of the script's output                                                          
echo " "                                                                                                                            
                                                                                                                                    
# Write the timestamp to a file named timestamp_<vmid>.txt                                                                          
echo "${timestamp}" > "/tmp/timestamp_simulator${vm_id_input}.txt"     




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

log_event() {
  echo "$(date '+%Y-%M-%d %H:%M:%S') - $1" >> "$log_events"
}

log_trace "=====================Starting the Log====================="                                                              
log_event "=====================Starting the Log====================="                                                              
                                                                                                                                    
vm_name_start=$(sqlite3 "$backup_index_db" "SELECT vm_name FROM $sanitized_tablename LIMIT 1;")                                     
target_start=$(sqlite3 vmSettings.db "SELECT host_ip FROM Target LIMIT 1;")                                                         
                                                                                                                                    
log_trace "Received Request to Simulation  VM $vm_name_start to Target: $target_start "                                                 
log_event "Received Request to Simulation  VM $vm_name_start to Target: $target_start "                                                 
                                                                                                                                    
log_trace "Restore process started for VM: $vm_id_input"                                                                            
log_event "Restore process initiated for VM: $vm_id_input"                                                                          
                                                                                                                                    
log_trace " Registering Job ID "                                                                                                    
log_event " Registering Job ID "                                                                                                    
                                                                                                                                    
# Starting jobid session                                                                                                            
# Insert the new job into the database                                                                                              
sqlite3 "$jobid_db" "INSERT INTO table_jobid (job_type, vm_id, vm_name, timestamp, status, logs_path) VALUES ('$job_type', '$vm_id_input', '$vm_name_start', '$timestamp', 'Running', '$log_events');"

# Retrieve the last assigned job_id                                                                                                                                        
# Query the job_id using vm_id, job_type, and timestamp                                                                                                                    
job_id=$(sqlite3 "$jobid_db" "SELECT job_id FROM table_jobid WHERE vm_id = '$vm_id_input' AND job_type = '$job_type' AND timestamp = '$timestamp';")                       
                                                                                                                                                                           
                                                                                                                                                                           
echo " "                                                                                                                                                                   
echo " Job ID: $job_id"                                                                                                                                                    
echo " "                                                                                                                                                                   
                                                                                                                                                                           
                                                                                                                                                                           
# Log the retrieved job_id                                                                                                                                                 
log_trace " Job ID:  $job_id "                                                                                                                                             
log_event " Job ID: $job_id "                                                                                                                                             
                                       

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


init_restore() {
  echo "#######################################"
  echo "# Starting Restore                    #"
  echo "#######################################"

log_trace "  Starting Simulation Recovery  "                                                                                                    
log_event "  Starting Simulation Recovery  " 



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

# TASK Push - tasks push

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



log_trace "  Fetching Full Backup Path  "                                                                                                                                       
log_event "  Fetching Full Backup Path  "    

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

 
log_trace "  Fetching Checkpoints for the given date and time  "                                                                                                                                          
log_event "  Fetching Checkpoints for the given date and time  "

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


log_trace "  Processing  Checkpoints(if any) for the given date and time  "                                                                                                                                     
log_event "  Processing  Checkpoints(if any) for the given date and time  " 

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

log_trace "  Merging all Deltas  "                                                                                                                          
log_event "  Merging all Deltas  "  

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
  

log_trace "  Convert the merged raw file to QCOW2 format  "                                                                                                                                                                   
log_event "  Convert the merged raw file to QCOW2 format  "    

  # Convert the merged raw file to QCOW2 format
  echo "Converting the merged raw backup file to QCOW2 format..."

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

log_trace "  QCOW2 conversion completed: $qcow2_file  "                                                                                                                                          
log_event "  QCOW2 conversion completed: $qcow2_file  "  


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

log_trace "  Create a new disk in the storage domain  "                                                                                                                                              
log_event "  Create a new disk in the storage domain  "  



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


log_trace "  Enable incremental backup for the newly uploaded QCOW2 disk  "                                                                                                                                              
log_event "  Enable incremental backup for the newly uploaded QCOW2 disk  "  

  # Enable incremental backup for the newly uploaded QCOW2 disk
  echo "Enabling incremental backup for the new QCOW2 disk..."
  enable_backup_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<disk>
              <backup>incremental</backup>
           </disk>" \
       "$url_Engine/api/disks/$new_disk_id")
  echo "Incremental backup enable response: $enable_backup_response"

log_trace "  Ensure the disk is unlocked before starting the image transfer  "                                                                                                                          
log_event "  Ensure the disk is unlocked before starting the image transfer  " 



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

log_trace "  Create a new VM with the original VM name and _Recovered suffix  "                                                                                                                       
log_event "  Create a new VM with the original VM name and _Recovered suffix  "     

  # Create a new VM with the original VM name and _Recovered suffix
  restored_vm_name="${vm_name}_SIMULATOR_$timestamp"
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

log_trace "  Create an image transfer to upload the QCOW2 file  "                                                                                                                      
log_event "  Create an image transfer to upload the QCOW2 file  "   


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

log_trace "  Upload QCOW2 file  "                                                                                                                                    
log_event "  Upload QCOW2 file  "  

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

log_trace "  Attach the disk to the VM   "                                                                                                                                                                    
log_event "  Attach the disk to the VM   "        


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


                                                                                                                                                                                                     
log_trace "  Add Network Interface to the VM    "                                                                                                                                                           
log_event "  Add Network Interface to the VM    "   


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


log_trace "  Activate the Network Interface     "                                                                                                                                                    
log_event "  Activate the Network Interface     "   


  # Activate the Network Interface
  echo "Activating the network interface..."
  activate_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<action />" \
       "$url_Engine/api/vms/$restored_vm_id/nics/$nic_id/activate")
  echo "Network interface activation response: $activate_response"
  log_trace "Network interface activation response: $activate_response"



log_trace "  Start the VM     "                                                                                                                                                    
log_event "  Start the VM     " 

  # Start the VM
  echo "Starting the restored VM with name $restored_vm_name and ID: $restored_vm_id..."
  start_vm_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" \
       -d "<action />" \
       "$url_Engine/api/vms/$restored_vm_id/start")
  echo "VM start response: $start_vm_response"
  echo "Restored VM with name $restored_vm_name and ID: $restored_vm_id started successfully."

  # Drop the restore session table
  echo "Dropping the restore session table..."
  sqlite3 "$backup_index_db" "DROP TABLE IF EXISTS $restore_session_table;"
  echo "Restore session table dropped."

  # Final step: Logging completion
  log_event "Restore process completed successfully for VM ID $vm_id_input and incremental backup enabled."
  echo "Restore process completed successfully!"
  dmsetup remove_all

  # Call simulator_temp_table function with the restored_vm_id
  simulator_temp_table "$restored_vm_id"
}

# Function to create and populate DR Simulator temporary table
simulator_temp_table() {
  local restored_vm_id="$1"  # Accept restored_vm_id as a parameter
  sanitized_restored_vm_id=$(echo "$restored_vm_id" | sed 's/[^a-zA-Z0-9_]//g')

  echo "Creating temporary table drsimulator_$sanitized_restored_vm_id..."

  # Create the table with the new schema, including mergedfilepath column
  sqlite3 "$backup_index_db" <<EOF
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS drsimulator_$sanitized_restored_vm_id (
    new_vmid TEXT,
    vmname TEXT,
    original_vmid TEXT,
    ip TEXT,
    OS TEXT,
    mergedfilepath TEXT,
    rewind_time TEXT,
    rewind_date TEXT
);
COMMIT;
EOF

  echo "Table drsimulator_$sanitized_restored_vm_id created."

  echo "Fetching details for VM ID: $restored_vm_id..."

  # Fetch VM details from the oVirt API using the restored VM ID
  vm_details=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$restored_vm_id")
  echo "VM Details: $vm_details"  # Debugging information to see the actual content

  # Extract VM name and OS distribution from the API response
  vmname=$(echo "$vm_details" | jq -r '.name // empty')
  OS=$(echo "$vm_details" | jq -r '.guest_operating_system.distribution // empty')

  # Fetch NICs for the restored VM
  nics=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$restored_vm_id/nics")
  echo "NICs Details: $nics"  # Debugging information to see the actual content

  # Extract NIC ID
  nic_id=$(echo "$nics" | jq -r '.nic[0].id // empty')

  # Fetch reported devices to get IP address
  if [ "$nic_id" != "empty" ]; then
    reported_devices=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$restored_vm_id/nics/$nic_id/reporteddevices")
    echo "Reported Devices: $reported_devices"  # Debugging information to see the actual content
    ip=$(echo "$reported_devices" | jq -r '.reported_device[0].ips.ip[0].address // empty')
  else
    ip="N/A"
  fi

  # Provide default values if fields are empty
  ip=${ip:-"N/A"}
  OS=${OS:-"N/A"}

  echo "Parsed VM Details: VMID=$restored_vm_id, VMName=$vmname, Original VMID=$vm_id_input, IP=$ip, OS=$OS"  # Debugging information

  # Insert into the table
  sqlite3 "$backup_index_db" <<EOF
BEGIN TRANSACTION;
INSERT INTO drsimulator_$sanitized_restored_vm_id (new_vmid, vmname, original_vmid, ip, OS, mergedfilepath, rewind_time, rewind_date) VALUES ('$restored_vm_id', '$vmname', '$vm_id_input','$ip', '$OS', '$merged_backup_file', '$time_input', '$date_input');
COMMIT;
EOF

  echo "VM information inserted into drsimulator_$sanitized_restored_vm_id."

  # Display the table with headers on and mode column
  echo "Displaying the contents of drsimulator_$sanitized_restored_vm_id..."
  sqlite3 "$backup_index_db" <<EOF
.headers on
.mode column
SELECT * FROM drsimulator_$sanitized_restored_vm_id;
EOF
}



# Cleanup loop devices on exit
trap cleanup_loop_devices EXIT

# Start the restore process
init_restore "$vm_id_input" "$date_input" "$time_input"

# Capture end time
end_time=$(date +%s)

# Calculate elapsed time
elapsed_time=$((end_time - start_time))

# Log the duration
echo "Duration of the script: $elapsed_time seconds"
log_trace "Duration of the script: $elapsed_time seconds"
log_event "Duration of the script: $elapsed_time seconds"

# Write the duration to a file
duration_status_file="/backup/status/${vm_id_input}/restore_duration_status.txt"
mkdir -p "$(dirname "$duration_status_file")"
echo "$elapsed_time" > "$duration_status_file"
echo "Elapsed time written to: $duration_status_file"
log_trace "Elapsed time written to: $duration_status_file"
log_event "Elapsed time written to: $duration_status_file"

# Update table job_id
echo " "
echo " Updating table Job_ID"

sqlite3 "$jobid_db" "UPDATE table_jobid SET status = 'Completed' WHERE job_id = '$job_id';"
echo " "

log_trace " SIMULATION RECOVERY of $vm_name_start to Target Platform : $target_start COMPLETED "                                               
log_event " SIMULATION RECOVERY of $vm_name_start to Target Platform : $target_start COMPLETED "                                               
                                                                                                                                    
log_trace " ======================================================================= "                                               
log_event " ======================================================================= "  
