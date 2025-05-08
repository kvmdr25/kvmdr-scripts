#!/bin/bash

# Path to your SQLite database
DB_PATH="/root/Backup_Index.db"

# Generate the DROP TABLE statements for all tables
TABLES=$(sqlite3 "$DB_PATH" .tables)

# Disable foreign key constraints
sqlite3 "$DB_PATH" "PRAGMA foreign_keys = OFF;"

# Loop through each table and drop it
for TABLE in $TABLES; do
  sqlite3 "$DB_PATH" "DROP TABLE IF EXISTS $TABLE;"
  echo "Dropped table $TABLE"
done

# Re-enable foreign key constraints
sqlite3 "$DB_PATH" "PRAGMA foreign_keys = ON;"

