#!/bin/bash
set -e

# Environment Variables
url_Engine="https://engine.local/ovirt-engine"
url_getToken="${url_Engine}/sso/oauth/token?grant_type=password&username=admin@ovirt@internalsso&password=ravi001&scope=ovirt-app-api"

# Fetch the access token
bearer_Token=$(curl -s -k --header "Accept: application/json" "$url_getToken" | jq -r '.access_token')

# Validate token
if [ -z "$bearer_Token" ]; then
  echo '{"success":false,"message":"Failed to fetch access token"}'
  exit 1
fi

# Fetch VM details
vm_details=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "${url_Engine}/api/vms")

# Validate VM details response
if [ -z "$vm_details" ] || [ "$vm_details" = "null" ]; then
  echo '{"success":false,"message":"No VMs found or invalid API response"}'
  exit 1
fi

# Initialize JSON array
output="["

# Parse VM details and fetch disk IDs
while IFS= read -r vm; do
  vm_id=$(echo "$vm" | jq -r '.id')
  vm_name=$(echo "$vm" | jq -r '.name')
  vm_status=$(echo "$vm" | jq -r '.status')

  # Fetch disk attachments for the VM
  disk_attachments=$(curl -s -k -H "Accept: application/json" -H "Authorization: Bearer $bearer_Token" "${url_Engine}/api/vms/${vm_id}/diskattachments")

  # Extract disk IDs
  disk_ids=$(echo "$disk_attachments" | jq -r '[.disk_attachment[]?.disk.id]')

  # Format JSON for the VM
  vm_json=$(jq -n --arg name "$vm_name" --arg status "$vm_status" --arg id "$vm_id" --argjson disk_ids "$disk_ids" '{
    name: $name,
    status: $status,
    id: $id,
    disk_ids: $disk_ids
  }')

  # Append to output
  output+="$vm_json,"
done < <(echo "$vm_details" | jq -c '.vm[]')

# Finalize JSON output
output="${output%,}]"
echo "$output"
