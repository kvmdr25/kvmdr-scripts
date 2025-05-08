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
echo "<--Branch for Kill Simulator for Source---->"
echo "____________________________________________"
echo " "

# Arguments and initial setup
vm_id_input="$1"

if [ -z "$vm_id_input" ] ; then
  echo "Error: Missing arguments. Usage: $0 <vm_id>"
  exit 1
fi

sanitized_vm_id=$(echo "$vm_id_input" | sed 's/[^a-zA-Z0-9]//g')
timestamp=$(date +%Y%m%d%H%M%S)
trace_log="/kvmdr/log/restore/$vm_id_input/trace_$timestamp.log"
log_events="/kvmdr/log/restore/$vm_id_input/events_$timestamp.log"                                                                  
url_Engine="https://dr.local/ovirt-engine"                                                                                          
url_getToken="$url_Engine/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"
backup_index_db="Backup_Index.db"                                                                                                   
jobid_db="/root/vmSettings.db"                                                                                                      
job_type="Simulator"  

# Make sure the directory structure exists:
mkdir -p "/kvmdr/log/restore/$vm_id_input"


echo " "                                                                                                                            
echo "Timestamp: $timestamp"  # Ensure this is part of the script's output                                                          
echo " "                                                                                                                            
                                                                                                                                    
# Write the timestamp to a file named timestamp_<vmid>.txt                                                                          
echo "${timestamp}" > "/tmp/timestamp_killrecovery${vm_id_input}.txt"  


log_trace() {                                                                                                                       
  echo "$(date '+%Y-%M-%d %H:%M:%S') - $1" >> "$trace_log"                                                                          
}                                                                                                                                   
                                                                                                                                    
log_event() {                                                                                                                       
  echo "$(date '+%Y-%M-%d %H:%M:%S') - $1" >> "$log_events"                                                                         
}         

  # Fetch oVirt API token                                                                                                                               
  echo "Fetching oVirt API token..."                                                                                                                    
  bearer_Token=$(curl -s -k --header Accept:application/json "$url_getToken" | jq -r '.access_token')                                                   
  if [ -z "$bearer_Token" ]; then                                                                                                                       
    echo "Error: Failed to fetch oVirt API token."                                                                                                      
    exit 1                                                                                                                                              
  fi                                                                                                                                                    
  echo "Token fetched"                                                                                                                                  


log_trace "=====================Starting the Log====================="                                                              
log_event "=====================Starting the Log====================="                                                              
                                                                                                                                    
vm_name=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input" | xmlstarlet sel -t -v "//vm/name")
target_start=$(sqlite3 vmSettings.db "SELECT host_ip FROM Target LIMIT 1;")                                                         
                                                                                                                                    
log_trace "Received Request to Terminate Simulator VM $vm_name to Target: $target_start "                                                 
log_event "Received Request to Terminate Simulator VM $vm_name to Target: $target_start "                                                 
                                                                                                                                    
log_trace "Restore process started for VM: $vm_id_input"                                                                            
log_event "Restore process initiated for VM: $vm_id_input"                                                                          
                                                                                                                                    
log_trace " Registering Job ID "                                                                                                    
log_event " Registering Job ID "                                                                                                                                                   
                                                                                                                                                                                   
# Starting jobid session                                                                                                                                                           
# Insert the new job into the database                                                                                                                                             
sqlite3 "$jobid_db" "INSERT INTO table_jobid (job_type, vm_id, vm_name, timestamp, logs_path) VALUES ('$job_type', '$vm_id_input', '$vm_name_start', '$timestamp', '$log_events');"
                                                                                                                                                                                   
# Retrieve the last assigned job_id                                                                                                                                                
# Query the job_id using vm_id, job_type, and timestamp                                                                                                                            
job_id=$(sqlite3 "$jobid_db" "SELECT job_id FROM table_jobid WHERE vm_id = '$vm_id_input' AND job_type = '$job_type' AND timestamp = '$timestamp';")   

echo " "                                                                                                                                                                           
echo " Job ID: $job_id"                                                                                                                                                            
echo " "                                                                                                                                                                           
                                                                                                                                                                                   
                                                                                                                                                                                   
# Log the retrieved job_id                                                                                                                                                         
log_trace " Job ID:  $job_id "                                                                                                                                                     
log_event " Job ID: $job_id "   


#Shutdown the Simulator VM

echo "Sending shutdown command to Simulator  VM: $vm_id_input"
shutdown_response=$(curl -s -k -X POST -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token" -d "<action/>" "$url_Engine/api/vms/$vm_id_input/shutdown")
echo "Shutdown response: $shutdown_response"


log_trace " Shutdown the Simulator VM "                                                                                                                                                     
log_event " Shutdown the Simulator VM " 
                       
# Wait until the VM is down                                                                                                                                                                   
  while true; do                                                                                                                                                                                
    vm_status=$(curl -s -k -X GET -H "Accept: application/xml" -H "Authorization: Bearer $bearer_Token" "$url_Engine/api/vms/$vm_id_input" | xmlstarlet sel -t -v "//vm/status")             
    echo "VM status: $vm_status"                                                                                                                                                                
    if [[ "${vm_status,,}" == "down" ]]; then
      echo " VM :$vm_id_input  is completely shutdown!"                                                                                                                                                   
      break                                                                                                                                                                                     
    fi                                                                                                                                                                                          
    echo "Waiting for VM to be in down state..."                                                                                                                                                
    /root/spinner1.sh 5                                                                                                                                                                                     
  done  

vm_remove=$(curl -s -k -X DELETE -H "Content-Type: application/xml" -H "Authorization: Bearer $bearer_Token"  "$url_Engine/api/vms/$vm_id_input")


log_trace " Removing VM : $vm_remove "                                                                                                                                                     
log_event " Removing VM : $vm_remove " 

clean() {                                                                
                                                                         
  echo " Cleaning up Simulators Temp files"
  echo " "
  raw_file=$(sqlite3 "$backup_index_db" "SELECT mergedfilepath  FROM drsimulator_$sanitized_vm_id WHERE new_vmid='$vm_id_input' LIMIT 1;")
  qcow2_file=$(echo "$raw_file" | sed 's/\.raw$/.qcow2/')                
  echo "Listing files in /backup/tmp..."                                 
  ls -lh /backup/tmp                                                     
  echo " "                                                               

  log_trace "Listing files in /backup/tmp..... "
  log_event " Listing files in /backup/tmp..... "
                                                                         
  echo "Stat files before deletion:"                     
  stat "$raw_file"                                       
  stat "$qcow2_file"                                     
  echo " "                                               
                                                         
  echo "Cleaning up temporary files..." 
  rm -f "$raw_file"                        
  rm -f "$qcow2_file"  
  echo " "                                         
  echo "SIMULATOR Temporary files deleted!"                 
  echo " "                                    

  log_trace "Cleaning up temporary files... "
  log_event " Cleaning up temporary files... "

}                                                                                                                                   
                                       
#Clean up simulators temp files             
clean

# Drop the restore session table                                                                                                          
  echo " "                                                                                                                                
  echo "Dropping the DR Simulator table..."                                                                                               
  sqlite3 "$backup_index_db" "DROP TABLE IF EXISTS drsimulator_$sanitized_vm_id;"                                                         
  echo " "                                                                                                                                
  echo "DR Simulator table : drsimulator_$sanitized_vm_id  Dropped!!"                                                                     
  echo " "                                                                                                                                

log_trace " DR Simulator table : drsimulator_$sanitized_vm_id  Dropped!! "                                                                                                                                                     
log_event " DR Simulator table : drsimulator_$sanitized_vm_id  Dropped!! " 
                                  
# Capture end time                                                       
end_time=$(date +%s)                                                     
execution_time=$(($end_time - $start_time))                     
echo "Script executed in $execution_time seconds." 

                                                                       
