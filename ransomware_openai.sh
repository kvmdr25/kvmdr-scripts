#!/bin/bash

# Database & OpenAI Configuration
DB_PATH="/root/aspar.db"
VM_ID_RAW="$1"
SANITIZED_VM_ID=$(echo "$VM_ID_RAW" | tr -d '-')  # Remove hyphens for SQLite compatibility
PDF_DIR="/backup/aspar/$VM_ID_RAW"
mkdir -p "$PDF_DIR"
PDF_FILE="$PDF_DIR/ransomware_openai_${VM_ID_RAW}_report_$(date +"%Y-%m-%d_%H-%M-%S").pdf"
SETTINGS_DB="/root/vmSettings.db"



echo "📌 DEBUG: Running ransomware AI analysis for VM ID: $VM_ID_RAW"
echo "📌 DEBUG: Database Path: $DB_PATH"
echo "📌 DEBUG: Sanitized VM ID for SQLite: $SANITIZED_VM_ID"

# Ensure the correct table exists before querying
sqlite3 "$DB_PATH" "
CREATE TABLE IF NOT EXISTS ransomware_ai_$SANITIZED_VM_ID (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vmid TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    anomaly_percentage REAL NOT NULL,
    threshold REAL NOT NULL,
    analysis_status TEXT DEFAULT 'pending'
);" 

# Extract the latest anomaly percentage
ANOMALY_PERCENTAGE=$(sqlite3 "$DB_PATH" "SELECT printf('%.6f', anomaly_percentage) FROM ransomware_analysis_results WHERE vmid='$VM_ID_RAW' ORDER BY id DESC LIMIT 1;")
MEAN=$(sqlite3 "$DB_PATH" "SELECT printf('%.6f', IFNULL(avg(anomaly_percentage), 0)) FROM ransomware_analysis_results WHERE vmid='$VM_ID_RAW';")
STDEV=$(sqlite3 "$DB_PATH" "SELECT printf('%.6f', IFNULL(sqrt(avg((anomaly_percentage - $MEAN)*(anomaly_percentage - $MEAN))), 0)) FROM ransomware_analysis_results WHERE vmid='$VM_ID_RAW';")


# Debug output
echo "📌 DEBUG: Extracted Mean: '$MEAN'"
echo "📌 DEBUG: Extracted Standard Deviation: '$STDEV'"

# Threshold Calculation
if [[ -z "$MEAN" || -z "$STDEV" || "$STDEV" == "0.000000" ]]; then
    THRESHOLD="0.1"  # Default threshold
else
    THRESHOLD=$(echo "$MEAN + $STDEV" | bc -l)
fi

echo "📌 DEBUG: Final Dynamically Calculated Threshold: '$THRESHOLD'"

# Fetch real-time ransomware intelligence from CISA & MITRE
CISA_CVE=$(curl -s "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json" | jq -r '.vulnerabilities[].cveID' | head -10 | paste -sd ",")
MITRE_VARIANTS=$(curl -s "https://raw.githubusercontent.com/mitre/cti/master/enterprise-attack/enterprise-attack.json" | jq -r '.objects[] | select(.description? and (.description | test("(?i)ransomware"))) | .name' | head -10 | paste -sd ",")

# Display findings
echo -e "📊 **Anomaly Percentage Detected:** $ANOMALY_PERCENTAGE"
echo -e "📏 **Dynamically Calculated Threshold Value:** $THRESHOLD"
echo -e "🛡️ **Latest CISA Exploited Vulnerabilities:** $CISA_CVE"
echo -e "🛡️ **MITRE ATT&CK Identified Ransomware Variants:** $MITRE_VARIANTS"

# Check if anomaly exceeds threshold
if (( $(echo "$ANOMALY_PERCENTAGE > $THRESHOLD" | bc -l) )); then
    echo "⚠️ Threshold exceeded. Running OpenAI analysis..."
    
    OPENAI_API_KEY=$(sqlite3 "$SETTINGS_DB" "SELECT API_Key FROM vmAttribs WHERE vmId='$VM_ID_RAW';")
 
    # Construct OpenAI request payload
    OPENAI_PAYLOAD=$(jq -n --arg anomaly "$ANOMALY_PERCENTAGE" --arg threshold "$THRESHOLD" --arg mitre "$MITRE_VARIANTS" --arg cisa "$CISA_CVE" '
    {
        model: "gpt-4o-2024-08-06",
        messages: [
            {
                role: "user",
                content: "Perform a ransomware entropy analysis based on block-level changes observed from incremental backup.\n\n### **Context:**\n- **Observed entropy deviation:** \($anomaly)%\n- **Threshold:** \($threshold)%\n- **Known ransomware entropy deviations from MITRE:** \($mitre)\n- **Latest CISA Exploited Vulnerabilities:** \($cisa)\n\n### **Required Analysis:**\n1. **Compare our entropy deviation with real ransomware cases.**\n2. **Calculate P(False Positive) and P(Genuine Encryption).**\n3. **Provide forensic indicators of compromise.**\n\n### **Expected Output:**\n- A **risk assessment** comparing our anomaly vs. real-world ransomware entropy.\n- **Benchmark comparisons** with known ransomware entropy shifts.\n- **Forensic validation steps** to confirm or dismiss encryption."
            }
        ],
        max_tokens: 700
    }')

    # Send request to OpenAI API
    OPENAI_RESPONSE=$(curl -s -X POST "https://api.openai.com/v1/chat/completions" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$OPENAI_PAYLOAD")

    # Extract OpenAI response content
    ANALYSIS=$(echo "$OPENAI_RESPONSE" | jq -r '.choices[0].message.content')

    if [[ -z "$ANALYSIS" || "$ANALYSIS" == "null" ]]; then
        echo "❌ OpenAI did not return a valid response. Logging failure."
        echo "OpenAI Failure at $(date)" >> "$PDF_DIR/openai_error.log"
        STATUS="failure"
    else
        echo -e "---------------- OpenAI Response ----------------\n$ANALYSIS\n------------------------------------------------"

        # Save to PDF (fallback to plaintext if PDF generation fails)
        echo "$ANALYSIS" | pandoc -o "$PDF_FILE" 2>/dev/null || echo "$ANALYSIS" > "${PDF_FILE}.txt"
        echo "✅ Report saved: $PDF_FILE"
        STATUS="success"
    fi
else
    echo "✅ Anomaly is within normal limits. No further action required."
    STATUS="success"
fi

# Ensure the file exists before assigning log_path
if [[ "$STATUS" == "success" && -f "$PDF_FILE" ]]; then
    LOG_PATH="$PDF_FILE"
else
    LOG_PATH="N/A"
    echo "❌ ERROR: Report file does not exist. Storing 'N/A' in database." >> "$PDF_DIR/openai_error.log"
fi


sqlite3 "$DB_PATH" "INSERT INTO ransomware_ai_$SANITIZED_VM_ID 
(vmid, timestamp, anomaly_percentage, threshold, analysis_status, log_path)
VALUES ('$VM_ID_RAW', '$(date '+%Y-%m-%d %H:%M:%S')', '$ANOMALY_PERCENTAGE', '$THRESHOLD', '$STATUS', '$LOG_PATH');"


# Display the correct database table for verification
echo "📋 Displaying Correct Table: ransomware_ai_$SANITIZED_VM_ID"
sqlite3 "$DB_PATH" <<EOF
.mode column
.headers on
SELECT * FROM ransomware_ai_$SANITIZED_VM_ID;
EOF
