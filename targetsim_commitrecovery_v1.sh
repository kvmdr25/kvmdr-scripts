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
echo "<--Branch for DR Simulator Commit to Recovery from Target---->"
echo "______________________________________________________________"
echo " "

# Arguments and initial setup
vm_id_input="$1"

# Sanitize vm_id_input and define variables
sanitized_vm_id=$(echo "$vm_id_input" | sed 's/[^a-zA-Z0-9]//g')
sanitized_tablename="drsimulator_$sanitized_vm_id"
url_Engine="https://dr.local/ovirt-engine"
url_getToken="$url_Engine/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"
backup_index_db="Backup_Index.db"
DRurl_Engine="https://engine.local/ovirt-engine"                                                                                                                                          
DRurl_getToken="$DRurl_Engine/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"     


# Fetch original_vmid and make it global
original_vm_id=$(sqlite3 "$backup_index_db" "SELECT original_vmid FROM drsimulator_$sanitized_vm_id WHERE new_vmid='$vm_id_input' LIMIT 1;")
sanitized_original_vmid=$(echo "$original_vm_id" | sed 's/[^a-zA-Z0-9]//g') 

# Function to remove a cron job related to the given Source VM
remove_cron_job() {
    local vm_id=$(sqlite3 "$backup_index_db" "SELECT original_vmid FROM drsimulator_$sanitized_vm_id WHERE new_vmid='$vm_id_input' LIMIT 1;")
    crontab -l | grep -v "$vm_id" | crontab -
    echo "Cron job related to VM ID $vm_id has been removed."
}

# Call the function to remove the cron job
remove_cron_job

# Fetch Source(engine) oVirt API token
echo "Fetching oVirt API token..."
bearer_Token=$(curl -s -k --header Accept:application/json "$url_getToken" | jq -r '.access_token')

if [ -z "$bearer_Token" ]; then
    echo "Error: Failed to fetch oVirt API token."
    exit 1
fi
echo "Token fetched: $bearer_Token"

# Fetch Target(dr)oVirt API token
echo "Fetching oVirt API token..."
DRbearer_Token=$(curl -s -k --header Accept:application/json "$DRurl_getToken" | jq -r '.access_token')

if [ -z "$DRbearer_Token" ]; then
    echo "Error: Failed to fetch oVirt API token."
    exit 1
fi
echo "Token fetched: $DRbearer_Token"

# Function to perform Synthetic Backup
create_synthetic() {
  echo "Starting Create Synthethic Backup process..."

  # Fetch the merged backup file path from the database, limiting to one result
  merged_backup_file=$(sqlite3 "$backup_index_db" "SELECT mergedfilepath FROM drsimulator_$sanitized_vm_id WHERE new_vmid='$vm_id_input' LIMIT 1;")

  # Extract date directly from the filename
    e_date=$(echo "$merged_backup_file" | awk -F'[_]' '{print $(NF-1)}')

  # Extract time directly from the filename
    e_time=$(echo "$merged_backup_file" | awk -F'[_]' '{print $NF}' | sed 's/\..*//') 

  #original_vm_id=$(sqlite3 "$backup_index_db" "SELECT original_vmid FROM drsimulator_$sanitized_vm_id WHERE new_vmid='$vm_id_input' LIMIT 1;") 
  response_vm_name=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$original_vm_id")
  vm_name=$(echo $response_vm_name | jq -r '.name')
   
  # Define the new backup file path
  new_backup_file="/backup/Full_backup_${vm_name}_RecoveredFO_${e_date}_${e_time}.raw"

 
  # Copy and rename the merged backup file
  echo " Copying the merged file to /backup/........"
  cp "$merged_backup_file" "$new_backup_file"
  export raw_file=$merged_backup_file

 
  echo " "
  echo " Created Synthethic Backup at : $new_backup_file"


  # Get the size of the new backup file
  new_backup_size=$(stat -c%s "$new_backup_file")
  new_backup_size_mb=$(awk "BEGIN {printf \"%.2f\", ${new_backup_size}/(1024*1024)}")
  echo " Size of Synthethic Backup : $new_backup_size_mb MB" 



  # Making sure correct checkpoint copied for first Incremental in new table
  echo "Finding Checkpoint mark for Restore Date and Time"
  response_checkpoint=$(sqlite3 "$backup_index_db" "SELECT rewind_time, rewind_date FROM drsimulator_$sanitized_vm_id WHERE new_vmid='$vm_id_input' LIMIT 1;")
   
     # Split the response into rewind_date and rewind_time
         rewind_time=$(echo $response_checkpoint | cut -d '|' -f 1)
         rewind_date=$(echo $response_checkpoint | cut -d '|' -f 2)

     #  Ensure both rewind_time and rewind_date are retrieved
           if [[ -z "$rewind_time" || -z "$rewind_date" ]]; then
               echo "Error: Unable to retrieve rewind time or date from the database."
                   exit 1
           fi

  
  # Sanitize original_vmid  and define variables
  #sanitized_original_vmid=$(echo "$original_vm_id" | sed 's/[^a-zA-Z0-9]//g')
  original_vmid_table="table_BI_$sanitized_original_vmid"
  checkpoint=$(sqlite3 "$backup_index_db" "SELECT Checkpoint FROM $original_vmid_table WHERE Date='$rewind_date' AND Time<='$rewind_time' ORDER BY Date DESC, Time DESC LIMIT 1;")
  echo " "
  echo "SETTING CHECKPOINT for INCREMENTAL INITIAL RUN : $checkpoint"
  echo " "

  response_disk_id=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $DRbearer_Token" "$DRurl_Engine/api/vms/$vm_id_input")
  new_disk_id=$(echo $response_disk_id | jq -r '.disk.id')


# Get the Simulator vm name                                                                                                                                                             
simname_response=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $DRbearer_Token" "$DRurl_Engine/api/vms/$vm_id_input")                                            
  simulator_vm_name=$(echo $simname_response | jq -r '.name') 

echo "Executing SQL commands For creating & populating tables..."
echo "sanitized_vm_id: $sanitized_vm_id"
echo "original_vmid_table: $original_vmid_table"

  # Execute the  SQL commands
sqlite3 "$backup_index_db" <<EOF
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS table_BI_$sanitized_vm_id (
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
INSERT INTO table_BI_$sanitized_vm_id (Full_Backup, Checkpoint, Date, Time, Backup_path, VM_Name, VM_ID, Disk_ID, Status, Duration, Size) VALUES (1, '$checkpoint', '$rewind_date', '$rewind_time', '$new_backup_file', '$vm_name', '$vm_id_input', '$new_disk_id', 'Full Backup Ready for RR', '0', '$new_backup_size_mb');
INSERT INTO $original_vmid_table (Full_Backup, Checkpoint, Date, Time, Backup_path, VM_Name, VM_ID, Disk_ID, Status, Duration, Size) VALUES (1010, '$checkpoint', '$rewind_date', '$rewind_time', '$new_backup_file', '$simulator_vm_name', '$vm_id_input', '$new_disk_id', 'Waiting for Failback', '0', '$new_backup_size_mb');

COMMIT;
EOF



  echo "Create Synthethic process completed."
  echo " "
  # Display the contents of both tables
  echo "#######################################"
  echo "# Table: table_BI_$sanitized_vm_id for VM : $simulator_vm_name #"
  echo "#######################################"
  sqlite3 "$backup_index_db" ".headers on" ".mode column" "SELECT * FROM table_BI_$sanitized_vm_id;"

  echo "#######################################"
  echo "# Table: $original_vmid_table for VM: $vm_name  #"
  echo "#######################################"
  sqlite3 "$backup_index_db" ".headers on" ".mode column" "SELECT * FROM $original_vmid_table;"
}

# Call the create_synthetic function before migrating checkpoints
create_synthetic

# The new function migrate_checkpoint
migrate_checkpoint() {
  echo "Starting checkpoint migration..."

  # Variables
  SOURCE_DB_HOST="dr.local"
  SOURCE_DB_NAME="engine"
  SOURCE_DB_USER="root"  # root user for SSH
  SOURCE_DB_ENGINE_USER="engine"  # engine user for PostgreSQL
  SOURCE_DB_PASSWORD=$(ssh root@dr.local "grep 'ENGINE_DB_PASSWORD' /etc/ovirt-engine/engine.conf.d/10-setup-database.conf | cut -d'=' -f2 | tr -d '\"'")
  SOURCE_VM_ID="${original_vm_id}"  # Source VM ID

  DR_DB_HOST="engine.local"
  DR_DB_NAME="engine"
  DR_DB_USER="root"  # root user for SSH
  DR_DB_ENGINE_USER="engine"  # engine user for PostgreSQL
  DR_DB_PASSWORD=$(ssh root@engine.local "grep 'ENGINE_DB_PASSWORD' /etc/ovirt-engine/engine.conf.d/10-setup-database.conf | cut -d'=' -f2 | tr -d '\"'")
  DR_VM_ID="${vm_id_input}"  # Corrected DR VM ID
  DR_API_URL="https://engine.local/ovirt-engine/api"
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

# Call the migrate_checkpoint function after reverse replication
migrate_checkpoint

# Read the table to get the original_vmid
echo "Reading original_vmid from table: $sanitized_tablename"
original_vmid=$(sqlite3 "$backup_index_db" "SELECT original_vmid FROM $sanitized_tablename WHERE new_vmid='$vm_id_input';")
if [[ -z "$original_vmid" ]]; then
    echo "Error: original_vmid not found for new_vmid: $vm_id_input"
    exit 1
fi
echo "Original VMID: $original_vmid"

# Get the vm_name for original_vmid using oVirt API
echo "Getting VM name for original_vmid: $original_vmid"
response=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$original_vmid")
echo "Response from API: $response"
vm_name=$(echo $response | jq -r '.name')
if [[ -z "$vm_name" ]]; then
    echo "Error: Failed to get VM name for original_vmid: $original_vmid"
    exit 1
fi
echo "Original VM Name: $vm_name"

# Shutdown the original_vmid
echo "Sending shutdown command to original VM: $original_vmid"
shutdown_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" -d "<action/>" "$url_Engine/api/vms/$original_vmid/shutdown")
echo "Shutdown command sent to VM: $original_vmid"
echo "Shutdown response: $shutdown_response"

# Wait for the VM to shut down (Optional, depending on your requirements)
echo "Waiting for the VM to shut down..."
#marksmen 1

# Initial status check
vm_status=$(curl -s -k -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$original_vmid" | grep -o "<state>[^<]*</state>" | sed 's/<state>//g' | sed 's/<\/state>//g')

# Loop to check the VM status
while [ "$vm_status" == "up" ]; do
    echo "Current VM status: $vm_status"
    sleep 5
    vm_status=$(curl -s -k -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$original_vmid" | grep -o "<state>[^<]*</state>" | sed 's/<state>//g' | sed 's/<\/state>//g')
done


echo "VM: $vm_name  has shut down."




# Change the vm_name of original_vmid to vm_name_old
echo "Changing name of original VM to ${vm_name}_old"
rename_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" -d "<vm><name>${vm_name}_old</name></vm>" "$url_Engine/api/vms/$original_vmid")
echo "Original VM name changed to: ${vm_name}_old"
echo "Rename response: $rename_response"

# Change the vm_name of vm_id_input to vm_name
echo "Changing name of new VM to $vm_name"
rename_new_response=$(curl -s -k -X PUT -H "Content-Type: application/xml" -H "Authorization: Bearer $DRbearer_Token" -d "<vm><name>$vm_name</name></vm>" "$DRurl_Engine/api/vms/$vm_id_input")
echo "Recovered VM name set to: $vm_name"
echo "Rename new VM response: $rename_new_response"

# Run incremental backup after reverse replication
echo "Running incremental backup after reverse replication..."
/root/incremental_fofb_v20.sh $vm_id_input

# New function to delete source checkpoints                                                                                                                                              
delete_source_checkpoint() {                                                                                                                                                             
  echo " "                                                                                                                                                                               
  echo "Starting deletion of source checkpoints..."                                                                                                                                      
  echo " "                                                                                                                                                                               
                                                                                                                                                                                         
  # Define variables                                                                                                                                                                     

  OVIRT_ENGINE_URL=$url_Engine                                                                                                                                                
  VM_ID=$original_vm_id                                                                                                                                                                      

  CHECKPOINTS_URL="$OVIRT_ENGINE_URL/api/vms/$VM_ID/checkpoints"                                                                                                            
                                                                                                                                                                                         
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
      DELETE_RESPONSE=$(curl -s -k -X DELETE -H "Content-Type: application/json" -H "Authorization: Bearer $bearer_Token" "$DELETE_URL")                                                                                                                                                                
      echo "Response from deleting checkpoint $CHECKPOINT_ID: $DELETE_RESPONSE"                                                                                                          
  done                                                                                                                                                                                   
                                                                                                                                                                                         
  echo "All checkpoints deleted."                                                                                                                                                        
}                                                                                                                                                                                        
          

create_FO_FB_table() {
  # Create the table with the new schema
  sqlite3 "$backup_index_db" <<EOF
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS sourceFO_$sanitized_vm_id (
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
   echo " "
   echo "___________________________________________________________________"
   echo "| Table sourceFO_$sanitized_vm_id created to be used for Failback. |"
   echo "-------------------------------------------------------------------"
   echo " " 
  # Fetch VM ID and name from table_BI_$sanitized_vm_id
  echo "Fetching Restored VM ID and name from table_BI_$sanitized_vm_id..."
  vm_info=$(sqlite3 "$backup_index_db" "SELECT vm_id, vm_name FROM table_BI_$sanitized_vm_id LIMIT 1;")
  FO_vmid=$(echo "$vm_info" | cut -d'|' -f1)
  FO_vmname=$(echo "$vm_info" | cut -d'|' -f2)
  FO_engine=$DRurl_Engine

  vm_details=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $DRbearer_Token" "$DRurl_Engine/api/vms/$FO_vmid")

   # Extracting the distribution field
   FO_os=$(echo "$vm_details" | jq -r '.guest_operating_system.distribution')

 
  # Fetch NICs
  nics=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $DRbearer_Token" "$DRurl_Engine/api/vms/$FO_vmid/nics")
  echo "NICs Details: $nics"  # Debugging information to see the actual content

  # Extract NIC ID
  nic_id=$(echo "$nics" | jq -r '.nic[0].id // empty')

  # Fetch reported devices to get IP address
  if [ "$nic_id" != "empty" ]; then
    reported_devices=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $DRbearer_Token" "$DRurl_Engine/api/vms/$FO_vmid/nics/$nic_id/reporteddevices")
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

  echo "Fetching details for Source VM ID: $original_vm_id..."

  # Fetch VM ID and name from table_BI_$sanitized_original_vmid
  echo "Fetching Source VM ID and name from table_BI_$sanitized_original_vmid..."
  vm_info1=$(sqlite3 "$backup_index_db" "SELECT vm_name FROM table_BI_$sanitized_original_vmid WHERE vm_id='$original_vm_id' LIMIT 1;")
  source_vmid=$original_vm_id
  source_vmname=$vm_info1
  source_engine=$url_Engine 

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
INSERT INTO sourceFO_$sanitized_vm_id (source_vmid, source_vmname, source_engine, source_ip, source_os, FO_vmid, FO_vmname, FO_engine, FO_ip, FO_os) VALUES ('$source_vmid', '$source_vmname', '$source_engine', '$source_ip', '$source_os', '$FO_vmid', '$FO_vmname', '$FO_engine', '$FO_ip', '$FO_os');
COMMIT;
EOF

  echo "VM information inserted into sourceFO_$sanitized_vm_id."

  # Display the table with headers on and mode column
  echo "Displaying the contents of sourceFO_$sanitized_vm_id..."
  sqlite3 "$backup_index_db" <<EOF
.headers on
.mode column
SELECT * FROM sourceFO_$sanitized_vm_id;
EOF
}


# Create and populate the sourceFO table
create_FO_FB_table


# Call the delete_source_checkpoint function after FOFB table creation          
delete_source_checkpoint 

echo " "
echo "+++++++++++++++++++++++++++++++++++++++"

echo "VM $vm_name successfully Recovered(FO)."

echo "++++++++++++++++++++++++++++++++++++++++"
echo " "

# Drop the restore session table
  echo " "
  echo "Dropping the DR Simulator table..."
  sqlite3 "$backup_index_db" "DROP TABLE IF EXISTS $sanitized_tablename;"
  echo "Restore session table dropped."

clean() {
  
  qcow2_file=$(echo "$raw_file" | sed 's/\.raw$/.qcow2/')
  echo "Listing files in /backup/tmp..."
  ls -lh /backup/tmp
  echo " "

  echo "Stat files before deletion:"
  stat "$raw_file"
  stat "$qcow2_file"
  echo " "

  echo "Cleaning up temporary files..."
  rm -f "$raw_file"
  rm -f "$qcow2_file"
  echo "Temporary files deleted."
  echo " "
}

#Clean up simulators temp files
clean


# Capture end time
end_time=$(date +%s)
execution_time=$(($end_time - $start_time))
echo "Script executed in $execution_time seconds."

