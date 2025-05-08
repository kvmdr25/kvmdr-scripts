#!/bin/bash

# Database file
db_file="vmSettings.db"

# SQLite commands
sqlite3 "$db_file" <<EOF
-- Delete all contents from table_jobid
DELETE FROM table_jobid;

-- Reset the AUTOINCREMENT value for job_id
DELETE FROM sqlite_sequence WHERE name='table_jobid';

-- Set the job_id to start at 10000
INSERT INTO sqlite_sequence (name, seq) VALUES ('table_jobid', 9999);
EOF

echo "Contents erased, and job_id reset to start at 10000."
