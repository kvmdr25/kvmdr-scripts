#!/bin/bash

# Configuration
DB_PATH="/root/aspar.db"
VM_ID_RAW="$1"
SANITIZED_VM_ID=$(echo "$VM_ID_RAW" | tr -d '-')
PDF_DIR="/backup/aspar/$VM_ID_RAW"
mkdir -p "$PDF_DIR"
PDF_LOG="$PDF_DIR/gemini_error.log"
SETTINGS_DB="/root/vmSettings.db"


# Logging
log(){
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Sanitized VM ID for SQLite: $SANITIZED_VM_ID"

# Ensure table exists
sqlite3 "$DB_PATH" "
CREATE TABLE IF NOT EXISTS ransomware_ai_$SANITIZED_VM_ID (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vmid TEXT,
    timestamp TEXT,
    anomaly_percentage REAL,
    threshold REAL,
    analysis_status TEXT,
    log_path TEXT
);"

# Fetch latest anomaly percentage
ANOMALY_PERCENTAGE=$(sqlite3 "$DB_PATH" "SELECT printf('%.6f', anomaly_percentage) FROM ransomware_analysis_results WHERE vmid='$VM_ID_RAW' ORDER BY id DESC LIMIT 1;")
MEAN=$(sqlite3 "$DB_PATH" "SELECT printf('%.6f', IFNULL(avg(anomaly_percentage), 0)) FROM ransomware_analysis_results WHERE vmid='$VM_ID_RAW';")
STDEV=$(sqlite3 "$DB_PATH" "SELECT printf('%.6f', IFNULL(sqrt(avg((anomaly_percentage - $MEAN)*(anomaly_percentage - $MEAN))), 0)) FROM ransomware_analysis_results WHERE vmid='$VM_ID_RAW';")



# Calculate Threshold
if [ -z "$MEAN" ] || [ -z "$STDEV" ] || (( $(echo "$STDEV == 0" | bc -l) )); then
    THRESHOLD="0.11"
else
    THRESHOLD=$(echo "$MEAN + $STDEV" | bc -l)
fi

# Debug output
echo "📌 DEBUG: MEAN = $MEAN, STDEV = $STDEV, THRESHOLD = $THRESHOLD"

# Fetch Latest Ransomware Intelligence
CISA_CVE=$(curl -s "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json" | jq -r '.vulnerabilities[].cveID' | head -10 | paste -sd ",")
MITRE_VARIANTS=$(curl -s "https://attack.mitre.org/software/" | grep -ioP '(?<=\>)(TrickBot|EKANS|Pikabot|SynAck|Ryuk)(?=\<)' | sort -u | paste -sd ",")

# Display results
echo -e "📊 **Anomaly Percentage Detected:** $ANOMALY_PERCENTAGE"
echo -e "📏 **Dynamically Calculated Threshold Value:** $THRESHOLD"
echo -e "🛡️ **CISA Known Exploited Vulnerabilities (Top 10):** $CISA_CVE"
echo -e "🛡️ **MITRE ATT&CK Identified Ransomware Variants:** $MITRE_VARIANTS"

# Threshold Check and Gemini Analysis
if (( $(echo "$ANOMALY_PERCENTAGE > $THRESHOLD" | bc -l) )); then
    log "⚠️ Threshold exceeded. Running Gemini analysis..."

     GOOGLE_API_KEY=$(sqlite3 "$SETTINGS_DB" "SELECT API_Key FROM vmAttribs WHERE vmId='$VM_ID_RAW';")


    GEMINI_RESPONSE=$(curl -s "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$GOOGLE_API_KEY" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg anomaly "$ANOMALY_PERCENTAGE" \
                   --arg threshold "$THRESHOLD" \
                   --arg mitre "$MITRE_VARIANTS" \
                   --arg cisa "$CISA_CVE" \
        '{
          contents: [{
            parts: [{
              text: "Perform ransomware entropy analysis with deviation: \($anomaly)% vs threshold: \($threshold)%. Compare with MITRE ransomware variants: \($mitre) and CISA CVEs: \($cisa). Provide risk assessment, forensic indicators, and validation steps clearly."
            }]
          }]
        }')")

    ANALYSIS=$(echo "$GEMINI_RESPONSE" | jq -r '.candidates[0].content.parts[0].text')

    if [ -z "$ANALYSIS" ] || [ "$ANALYSIS" = "null" ]; then
        log "❌ Gemini analysis failed. Logging failure."
        echo "Gemini Failure at $(date)" >> "$PDF_LOG"
        STATUS="failure"
    else
        log "✅ Gemini analysis completed successfully."
        PDF_FILE="$PDF_DIR/ransomware_gemini_${VM_ID_RAW}_$(date '+%Y-%m-%d_%H-%M-%S').pdf"
        echo "$ANALYSIS" | pandoc -o "$PDF_FILE" 2>/dev/null || echo "$ANALYSIS" > "${PDF_FILE%.pdf}.txt"
        echo -e "\n🔍 ----------- Gemini Analysis Output -----------\n"
        echo -e "$ANALYSIS"
        echo -e "\n📄 Gemini Analysis saved at: $PDF_FILE\n"
        STATUS="success"
    fi
else
    log "✅ Anomaly within normal limits."
    STATUS="success"
fi

# Store analysis result with log_path
if [[ "$STATUS" == "success" && -n "$PDF_FILE" ]]; then
    LOG_PATH="$PDF_FILE"
else
    LOG_PATH="N/A"
fi

sqlite3 "$DB_PATH" "INSERT INTO ransomware_ai_$SANITIZED_VM_ID (vmid, timestamp, anomaly_percentage, threshold, analysis_status, log_path) 
VALUES ('$VM_ID_RAW', '$(date '+%Y-%m-%d %H:%M:%S')', '$ANOMALY_PERCENTAGE', '$THRESHOLD', '$STATUS', '$LOG_PATH');"


# Display final table
sqlite3 "$DB_PATH" -header -column "SELECT * FROM ransomware_ai_$SANITIZED_VM_ID;"
