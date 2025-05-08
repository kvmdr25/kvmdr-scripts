#!/bin/bash

echo "#########################"
echo "Populate VM Attributes"
echo "#########################"

# oVirt engine credentials
OVIRT_ENGINE_URL="https://engine.local/ovirt-engine/api"
OVIRT_USERNAME="admin@ovirt@internalsso"
OVIRT_PASSWORD="ravi001"

# Database path
DB_PATH="/root/vmSettings.db"

# Get oVirt API token
url_getToken="https://engine.local/ovirt-engine/sso/oauth/token?grant_type=password&username=$OVIRT_USERNAME&password=$OVIRT_PASSWORD&scope=ovirt-app-api"
echo "Fetching authentication token from oVirt..."
Bearer_Token=$(curl -s -k --header Accept:application/json "$url_getToken" | jq -r '.access_token')

if [ -z "$Bearer_Token" ] || [ "$Bearer_Token" == "null" ]; then
  echo "❌ Failed to retrieve authentication token from oVirt."
  exit 1
fi

echo "✅ Token retrieved successfully."

# Get default RPO and retention from Source table
default_rpo=$(sqlite3 "$DB_PATH" "SELECT rpo FROM Source LIMIT 1;")
default_retention=$(sqlite3 "$DB_PATH" "SELECT retention FROM Source LIMIT 1;")
default_rpo=${default_rpo:-5}
default_retention=${default_retention:-30}

# Get Target DR IP from Target table
target_dr_ip=$(sqlite3 "$DB_PATH" "SELECT engine_ip FROM Target LIMIT 1;")
target_dr_ip=${target_dr_ip:-"unknown"}

# Update Settings table: default engine and archive retention
echo "🔧 Setting default engine to Gemini and archive retention to 1..."
sqlite3 "$DB_PATH" <<EOF
UPDATE Settings SET engine = 'Gemini', archive_retention = 1;
EOF

# Fetch VMs from oVirt
echo "📡 Fetching VM details from oVirt..."
response=$(curl -s -k -H "Authorization: Bearer $Bearer_Token" -X GET "$OVIRT_ENGINE_URL/vms" -H "Accept: application/json")

echo "🔍 Raw response from oVirt:"
echo "$response" | jq '.'

if [ -z "$response" ] || [ "$response" == "null" ]; then
  echo "❌ Failed to retrieve VM data from oVirt."
  exit 1
fi

# Detect structure
json_type=$(echo "$response" | jq 'type')
if [ "$json_type" == '"object"' ]; then
  vm_query=".vm[]"
elif [ "$json_type" == '"array"' ]; then
  vm_query=".[]"
else
  echo "❌ Invalid JSON structure from oVirt API."
  exit 1
fi

# Extract VM details
echo "🔄 Extracting VM details..."
vm_details=$(echo "$response" | jq -c "$vm_query | {vmId: .id, vmName: .name, vmIP: (.guest_info.ip // \"N/A\"), vmOS: (.os.type // \"Unknown\")}")

if [ -z "$vm_details" ]; then
  echo "⚠️ No VM details found in the response."
  exit 1
fi

# Insert or update VM records
echo "$vm_details" | while read -r vm; do
  vmId=$(echo "$vm" | jq -r '.vmId')
  vmName=$(echo "$vm" | jq -r '.vmName')
  vmIP=$(echo "$vm" | jq -r '.vmIP')
  vmOS=$(echo "$vm" | jq -r '.vmOS')

  # Skip filtered VM names
  if [[ "$vmName" == "HostedEngine" ]] || [[ "$vmName" == "kvmdr" ]]; then
    echo "⏭️ Skipping $vmName (excluded VM)"
    continue
  fi

  if [ -z "$vmId" ] || [ -z "$vmName" ]; then
    echo "⚠️ Skipping incomplete VM entry: $vm"
    continue
  fi

  # Escape values
  vmId_escaped=$(echo "$vmId" | sed "s/'/''/g")
  vmName_escaped=$(echo "$vmName" | sed "s/'/''/g")
  vmIP_escaped=$(echo "$vmIP" | sed "s/'/''/g")
  vmOS_escaped=$(echo "$vmOS" | sed "s/'/''/g")

  # Check if VM exists
  exists=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM vmAttribs WHERE vmId = '$vmId_escaped';")

  if [ "$exists" -eq 0 ]; then
    echo "💾 Inserting new VM $vmName ($vmId)..."
    sqlite3 "$DB_PATH" <<EOF
INSERT INTO vmAttribs (vmId, vmName, vmIP, vmOS, rpo, retentionPeriod, APSAR_Model, Target_DR)
VALUES ('$vmId_escaped', '$vmName_escaped', '$vmIP_escaped', '$vmOS_escaped', $default_rpo, $default_retention, 'Gemini', '$target_dr_ip');
EOF
    [ $? -eq 0 ] && echo "✅ Inserted $vmName" || echo "❌ Failed to insert $vmName"
  else
    # Check for missing fields
    check=$(sqlite3 "$DB_PATH" <<EOF
SELECT COUNT(*) FROM vmAttribs
WHERE vmId = '$vmId_escaped'
AND (
  rpo IS NULL OR rpo = 0 OR
  retentionPeriod IS NULL OR retentionPeriod = 0 OR
  APSAR_Model IS NULL OR APSAR_Model = '' OR
  Target_DR IS NULL OR Target_DR = ''
);
EOF
)

    if [ "$check" -gt 0 ]; then
      echo "🔄 Updating missing fields for $vmName ($vmId)..."
      sqlite3 "$DB_PATH" <<EOF
UPDATE vmAttribs
SET
  rpo = CASE WHEN rpo IS NULL OR rpo = 0 THEN $default_rpo ELSE rpo END,
  retentionPeriod = CASE WHEN retentionPeriod IS NULL OR retentionPeriod = 0 THEN $default_retention ELSE retentionPeriod END,
  APSAR_Model = CASE WHEN APSAR_Model IS NULL OR APSAR_Model = '' THEN 'Gemini' ELSE APSAR_Model END,
  Target_DR = CASE WHEN Target_DR IS NULL OR Target_DR = '' THEN '$target_dr_ip' ELSE Target_DR END
WHERE vmId = '$vmId_escaped';
EOF
      echo "✅ Updated $vmName"
    else
      echo "⏭️ VM $vmName ($vmId) already complete — skipping."
    fi
  fi
done

# Show final results
echo "📋 Displaying vmAttribs table..."
sqlite3 "$DB_PATH" <<EOF
.mode column
.headers on
SELECT * FROM vmAttribs;
EOF

echo "✅ Process completed."
