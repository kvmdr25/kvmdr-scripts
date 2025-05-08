#!/bin/bash
echo "#########################"
echo "Kill Orphaned Backup"
echo "#########################"

# Get the VM ID from the first argument
vm_id=$1

# Define the URL for the oVirt engine
url_Engine="https://engine.local/ovirt-engine"

# Define the URL to get the token
url_getToken="https://engine.local/ovirt-engine/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"

# Fetch the bearer token using curl
Bearer_Token=$(curl -s -k --header Accept:application/json "$url_getToken" | jq -r '.access_token')

# Fetch the disk details using the token
disk_response=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $Bearer_Token" "$url_Engine/api/vms/$vm_id/diskattachments")
disk_ids=$(echo "$disk_response" | xmlstarlet sel -t -m "//disk_attachment/disk" -v "@id" -n | tr '\n' ',')
disk_ids=${disk_ids%,}  # Remove trailing comma

# Print the VM ID and disk IDs
echo "VM ID: $vm_id"
echo "Disk IDs: $disk_ids"
echo " "

# Fetch the details of the backups using the token
vm_poll_backup=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $Bearer_Token" "$url_Engine/api/vms/$vm_id/backups")

# Traverse through the backups and kill the ones in the "ready" phase
echo "$vm_poll_backup" | jq -c '.backup[]' | while read -r backup; do
    phase=$(echo "$backup" | jq -r '.phase')
    backup_id=$(echo "$backup" | jq -r '.id')

    if [ "$phase" == "ready" ]; then
        echo "Finalizing backup with ID: $backup_id"

        # Finalize the backup
        finalize_url="$url_Engine/api/vms/$vm_id/backups/$backup_id/finalize"
        finalize_response=$(curl -s -k -X POST -H "Accept: application/xml" -H "Content-Type:application/xml" -H "Authorization: Bearer $Bearer_Token" -d "<action />" "$finalize_url")
        finalize_status=$(echo "$finalize_response" | xmlstarlet sel -t -v "//backup/phase")

        # Poll the status until it is "succeeded" or timeout
        end=$((SECONDS+300))  # 5 minutes timeout
        while [ "$finalize_status" != "succeeded" ]; do
            if [ $SECONDS -ge $end ]; then
                echo "Finalization of backup $backup_id timed out."
                break
            fi
            sleep 5
            finalize_response=$(curl -s -k -H "Accept: application/xml" -H "Authorization: Bearer $Bearer_Token" "$url_Engine/api/vms/$vm_id/backups/$backup_id")
            finalize_status=$(echo "$finalize_response" | xmlstarlet sel -t -v "//backup/phase")
        done

        if [ "$finalize_status" == "succeeded" ]; then
            echo "Backup with ID $backup_id has been successfully finalized."
        else
            echo "Backup with ID $backup_id could not be finalized."
        fi
    fi
done

