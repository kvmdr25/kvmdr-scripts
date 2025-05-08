#!/bin/bash

# Config
TARGET_HOST="alpine2"
TARGET_USER="root"

# Run ransomware simulation remotely in one go
ssh ${TARGET_USER}@${TARGET_HOST} 'bash -s' <<'EOF'
TARGET_DIR="/root/documents3"
ENCRYPTION_KEY="hacked123"

echo "🧪 Starting ransomware simulation on $(hostname)..."

mkdir -p "$TARGET_DIR"
for i in $(seq 1 1000); do
    echo "Sensitive data file number $i - $(date)" > "$TARGET_DIR/doc_$i.txt"
done

cd "$TARGET_DIR"
for f in *.txt; do
    openssl enc -aes-256-cbc -salt -in "$f" -out "$f.enc" -k "$ENCRYPTION_KEY" 2>/dev/null && rm -f "$f"
done

echo "✅ Ransomware simulation complete. Encrypted files ready for backup."
EOF
