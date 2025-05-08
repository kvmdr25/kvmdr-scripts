const express = require("express");
const cors = require("cors");
const fs = require("fs");
const sqlite3 = require("sqlite3").verbose();
const WebSocket = require("ws");
const { exec } = require('child_process');
const { spawn } = require('child_process');
const path = require("path");
const vmSettingsDbPath = "/root/vmSettings.db";
const backupIndexDbPath = "/root/Backup_Index.db";
const router = express.Router();
const fse = require('fs-extra');


const app = express();
app.use(cors());
app.use(express.json());
app.use(router);

const vmSettingsDb = new sqlite3.Database(vmSettingsDbPath, (err) => {
  if (err) {
    console.error("Error connecting to vmSettings.db:", err.message);
    process.exit(1); // Exit if database connection fails
  } else {
    console.log("Connected to vmSettings.db");
  }
});

// Initialize Backup_Index.db
const backupIndexDb = new sqlite3.Database(backupIndexDbPath, (err) => {
  if (err) {
    console.error("Error connecting to Backup_Index.db:", err.message);
    process.exit(1); // Exit if database connection fails
  } else {
    console.log("Connected to Backup_Index.db");
  }
});

//Pre-load Settings
app.get("/get-settings", (req, res) => {
  vmSettingsDb.serialize(() => {
    vmSettingsDb.get("SELECT * FROM Source LIMIT 1", (err, sourceRow) => {
      if (err) return res.status(500).json({ success: false, message: "Error retrieving Source data" });

      vmSettingsDb.get("SELECT * FROM Target LIMIT 1", (err, targetRow) => {
        if (err) return res.status(500).json({ success: false, message: "Error retrieving Target data" });

        // Fetch global ASPAR Model and API Key (from vmAttribs, assuming first row)
        vmSettingsDb.get("SELECT APSAR_Model, API_Key FROM vmAttribs LIMIT 1", (err, attribRow) => {
          if (err) return res.status(500).json({ success: false, message: "Error retrieving VM attributes" });

          res.json({
            success: true,
            data: {
              source: {
                ...sourceRow,
                asp_model: attribRow ? attribRow.APSAR_Model : "",
                api_key: attribRow ? attribRow.API_Key : "",
              },
              target: targetRow,
            },
          });
        });
      });
    });
  });
});


// for Settings update/saving

app.post("/save-settings", (req, res) => {
  const {
    sourceHostIP,
    sourceEngineIP,
    sourceAdminPassword,
    sourceRPO,
    sourceRetention,
    targetHostIP,
    targetEngineIP,
    targetAdminPassword,
    targetStorageProtocol,
    targetStorageReplicationTarget,
    sourceAspModel,  // Existing ASPAR Model field
    targetDrValue,   // Added Target_DR value
    sourceApiKey     // <-- NEW: API Key field added
  } = req.body;

  vmSettingsDb.serialize(() => {
    // Update Source Table
    vmSettingsDb.get(`SELECT * FROM Source LIMIT 1`, (err, sourceRow) => {
      if (err) {
        return res.status(500).send({ success: false, message: "Error retrieving Source table" });
      }

      if (sourceRow) {
        vmSettingsDb.run(
          `UPDATE Source 
           SET host_ip = ?, engine_ip = ?, admin_password = ?, rpo = ?, retention = ?
           WHERE id = ?`,
          [sourceHostIP, sourceEngineIP, sourceAdminPassword, sourceRPO, sourceRetention, sourceRow.id],
          (err) => {
            if (err) {
              return res.status(500).send({ success: false, message: "Error updating Source table" });
            }
          }
        );
      } else {
        vmSettingsDb.run(
          `INSERT INTO Source (host_ip, engine_ip, admin_password, rpo, retention)
           VALUES (?, ?, ?, ?, ?)`,
          [sourceHostIP, sourceEngineIP, sourceAdminPassword, sourceRPO, sourceRetention],
          (err) => {
            if (err) {
              return res.status(500).send({ success: false, message: "Error inserting into Source table" });
            }
          }
        );
      }
    });

    // Update Target Table
    vmSettingsDb.get(`SELECT * FROM Target LIMIT 1`, (err, targetRow) => {
      if (err) {
        return res.status(500).send({ success: false, message: "Error retrieving Target table" });
      }

      if (targetRow) {
        vmSettingsDb.run(
          `UPDATE Target 
           SET host_ip = ?, engine_ip = ?, admin_password = ?, storage_protocol = ?, storage_replication_target = ?
           WHERE id = ?`,
          [targetHostIP, targetEngineIP, targetAdminPassword, targetStorageProtocol, targetStorageReplicationTarget, targetRow.id],
          (err) => {
            if (err) {
              return res.status(500).send({ success: false, message: "Error updating Target table" });
            }
          }
        );
      } else {
        vmSettingsDb.run(
          `INSERT INTO Target (host_ip, engine_ip, admin_password, storage_protocol, storage_replication_target)
           VALUES (?, ?, ?, ?, ?)`,
          [targetHostIP, targetEngineIP, targetAdminPassword, targetStorageProtocol, targetStorageReplicationTarget],
          (err) => {
            if (err) {
              return res.status(500).send({ success: false, message: "Error inserting into Target table" });
            }
          }
        );
      }
    });

    // Update vmAttribs Table (Adding API_Key)
    vmSettingsDb.run(
      `UPDATE vmAttribs 
       SET APSAR_Model = ?, API_Key = ?, Target_DR = ?`,
      [sourceAspModel, sourceApiKey, targetEngineIP], 
      (err) => {
        if (err) {
          return res.status(500).send({ success: false, message: "Error updating vmAttribs table" });
        }
        res.json({ success: true, message: "Settings saved successfully!" });
      }
    );
  });
});

// Endpoint to Save to vmAttribs
app.post('/vmAttribs-save-settings', (req, res) => {
  const { vm_name, rpo, retention, apsarEnabled, engineIP } = req.body;

  // SQL query to update the vmAttribs table using vm_name
  const updateQuery = `
    UPDATE vmAttribs
    SET rpo = ?, retentionPeriod = ?, APSAR_enabled = ?, Target_DR = ?
    WHERE vmName = ?`;

  // Run the update query
  vmSettingsDb.run(updateQuery, [rpo, retention, apsarEnabled, engineIP, vm_name], function (err) {
    if (err) {
      console.error("Error updating settings:", err);
      res.status(500).json({ success: false, message: "Error updating settings" });
      return;
    }
    res.json({ success: true, message: "Settings updated successfully" });
  });
});



// Endpoint to test connectivity using ping
app.post("/test-connectivity", (req, res) => {
  const { ip } = req.body;

  if (!ip) {
    return res.status(400).send({ success: false, message: "IP address is required" });
  }

  const command = `ping -c 1 ${ip}`;

  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Ping error for IP ${ip}:`, stderr);
      return res.status(200).send({ success: false, message: `Ping failed for IP ${ip}` });
    }

    console.log(`Ping successful for IP ${ip}:`, stdout);
    res.status(200).send({ success: true, message: `Ping successful for IP ${ip}` });
  });
});

// Endpoint to fetch the list of VMs -Source
app.get("/vms", (req, res) => {
  const scriptPath = "/root/listvmjson.sh";

  exec(scriptPath, (error, stdout, stderr) => {
    if (error) {
      console.error("Error executing VM list script:", stderr);
      return res.status(500).send({ success: false, message: "Error listing VMs" });
    }

    try {
      const vmData = JSON.parse(stdout);
      res.json({ success: true, vms: vmData });
    } catch (err) {
      res.status(500).send({ success: false, message: "Error parsing VM data" });
    }
  });
});

// Endpoint to fetch the list of VMs -Target                                               
app.get("/vms-target", (req, res) => {                                                            
  const scriptPath = "/root/listvmjsondr.sh";                                                
                                                                                           
  exec(scriptPath, (error, stdout, stderr) => {                                            
    if (error) {                                                                           
      console.error("Error executing VM list script:", stderr);                      
      return res.status(500).send({ success: false, message: "Error listing VMs" }); 
    }                                                                                
                                                                                     
    try {                                                                           
      const vmData = JSON.parse(stdout);                                            
      res.json({ success: true, vms: vmData });                                     
    } catch (err) {                                                                 
      res.status(500).send({ success: false, message: "Error parsing VM data" });   
    }                                                                               
  });                                                                               
});      





// Endpoint to fetch logs for a VM

app.get("/logs/:vmid/:timestamp", (req, res) => {
  const { vmid, timestamp } = req.params;     
  const logFilePath = `/kvmdr/log/${vmid}/events_${timestamp}.log`;
   
  if (fs.existsSync(logFilePath)) {
    res.sendFile(logFilePath);
  } else {                                                              
    // Return message indicating logs are being loaded
    res.status(404).json({ error: "Logs are being Created & Loaded. Please refresh." }); 
  }                                                      
});    


// Endpoint to download log file
app.get("/download-log/:vmid/:timestamp", (req, res) => {
  const { vmid, timestamp } = req.params;

  const timestampFile = `/tmp/timestamp_${vmid}.txt`;

  let effectiveTimestamp = timestamp;

  if (fs.existsSync(timestampFile)) {
    const fileTimestamp = fs.readFileSync(timestampFile, "utf8").trim();
    if (fileTimestamp) {
      effectiveTimestamp = fileTimestamp;
    }
  }

  const logFile = `/kvmdr/log/${vmid}/events_${effectiveTimestamp}.log`;

  if (fs.existsSync(logFile)) {
    res.download(logFile);
  } else {
    res.status(404).json({ error: "Log file not found" });
  }
});

app.get('/recovery-log-refresh/:vmid/:timestamp', (req, res) => {
  const { vmid, timestamp } = req.params;
  const logFilePath = `/kvmdr/log/restore/${vmid}/events_${timestamp}.log`;

  // Read the log file
  fs.readFile(logFilePath, 'utf8', (err, data) => {
    if (err) {
      console.error('Log file not found:', err);  // Log error on server side for visibility
      return res.json({
        success: false,
        message: 'Logs not found or could not be read',
      });
    }

    // Successfully read the log file
    return res.json({
      success: true,
      logs: data || 'No logs available',  // Default message if the file content is empty
    });
  });
});

app.get('/recoverylog-ready/:vmid/:timestamp', (req, res) => {

  const { vmid, timestamp } = req.params;
  const logFilePath = `/kvmdr/log/restore/${vmid}/events_${timestamp}.log`;

  if (fs.existsSync(logFilePath)) {
    res.json({ ready: true });
  } else {
    res.json({ ready: false });
  }
});
// Endpoint to run a script after saving settings

app.post("/run-script", (req, res) => {
  const { vmid } = req.body;

  if (!vmid) {
    return res.status(400).json({ success: false, message: "VMID is required" });
  }

  const scriptPath = "/root/fullbackup_v20.sh";
  const command = `${scriptPath} ${vmid}`;
  const timestampFile = `/tmp/timestamp_${vmid}.txt`;

  console.log(`Executing command: ${command}`);

  // Execute the backup script
  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Script execution error: ${stderr}`);
      return res.status(500).json({
        success: false,
        message: `Error running script for VMID ${vmid}`,
        error: stderr,
      });
    }

    console.log(`Script executed: ${stdout}`);
  });

  // Initialize a response flag to avoid duplicate responses
  let responseSent = false;

  let attempts = 0;
  const maxAttempts = 10;
  const retryDelay = 1000;

  // Check for the timestamp file at intervals
  const waitForFile = setInterval(() => {
    if (fs.existsSync(timestampFile)) {
      const timestamp = fs.readFileSync(timestampFile, "utf8").trim();
      clearInterval(waitForFile);

      fs.unlinkSync(timestampFile); // Cleanup timestamp file
      console.log(`Timestamp file processed and deleted: ${timestamp}`);

      if (!responseSent) {
        responseSent = true;
        return res.json({
          success: true,
          message: "Script executed successfully!",
          timestamp,
        });
      }
    } else if (++attempts >= maxAttempts) {
      clearInterval(waitForFile);

      if (!responseSent) {
        responseSent = true;
        console.error("Timeout waiting for timestamp file");
        return res.status(500).json({
          success: false,
          message: "Timeout waiting for script completion",
        });
      }
    }
  }, retryDelay);
});




// New Endpoint: /filtered-vms
app.get("/filtered-vms", (req, res) => {
  const backupDbPath = "/root/Backup_Index.db";
  const backupDb = new sqlite3.Database(backupDbPath, (err) => {
    if (err) {
      console.error("Error opening backup index database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to open backup database" });
    }
  });

  const query = `
    SELECT name 
    FROM sqlite_master 
    WHERE type='table' AND name LIKE 'Table_BI_%';
  `;

  backupDb.all(query, [], (err, rows) => {
    backupDb.close();
    if (err) {
      console.error("Error querying backup index database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to query backup database" });
    }

    const vmIDs = rows.map((row) => row.name.replace("Table_BI_", ""));
    res.json({ success: true, vmIDs });
  });
});

app.post("/terminate-vm", async (req, res) => {
    const { vmname } = req.body;
    console.log("Received vmname in Backend:", vmname);

    if (!vmname) {
        console.log("VM name is missing in the request.");
        return res.status(400).json({ success: false, message: "VM name required" });
    }

    // Step 1: Get VM ID from listvmjsondr.sh
    const process = spawn('/root/listvmjsondr.sh');
    let outputData = '';

    process.stdout.on('data', (data) => {
        outputData += data.toString();
        console.log("Output from listvmjsondr.sh:", data.toString()); 
    });

    process.on('close', async (code) => {
        if (code !== 0) {
            console.log("Error running listvmjsondr.sh, exit code:", code);
            return res.status(500).json({ success: false, message: "Error running listvmjsondr.sh" });
        }

        try {
            const vmList = JSON.parse(outputData);
            const vm = vmList.find(v => v.name === vmname);

            if (!vm) {
                console.error("VM not found in the list:", vmname);
                return res.status(404).json({ success: false, message: "VM not found" });
            }

            const vmID = vm.id; // Extract vmID from list
            console.log("Found vmID for", vmname, ":", vmID);

            // Step 2: Terminate VM
            const terminateProcess = spawn('/root/killsourcesimulator_v1.sh', [vmID], { shell: true });

            let terminateOutput = '';

            terminateProcess.stdout.on('data', (data) => {
                terminateOutput += data.toString();
                console.log("Termination script output:", data.toString());
            });

            terminateProcess.on('close', async (code) => {
                if (code !== 0) {
                    console.error("Termination script failed with exit code", code);
                    return res.status(500).json({ success: false, message: "VM termination failed" });
                }

                console.log("Termination script completed successfully");

                // Step 3: Read log file after termination
                const timestampFile = `/tmp/timestamp_killrecovery${vmID}.txt`;

                if (!fs.existsSync(timestampFile)) {
                    console.error("Timestamp file not found:", timestampFile);
                    return res.status(404).json({ success: false, message: "Timestamp file not found" });
                }

                const timestamp = fs.readFileSync(timestampFile, 'utf-8').trim();
                console.log("Timestamp read from file:", timestamp);

                const logFilePath = `/kvmdr/log/restore/${vmID}/events_${timestamp}.log`;
                console.log("Looking for log file at:", logFilePath);

                if (!fs.existsSync(logFilePath)) {
                    console.error("Log file not found:", logFilePath);
                    return res.status(404).json({ success: false, message: "Log file not found" });
                }

                // Step 4: Return only logs, NOT vmID
                fs.readFile(logFilePath, 'utf-8', (err, data) => {
                    if (err) {
                        console.error("Error reading log file:", err);
                        return res.status(500).json({ success: false, message: "Error reading log file" });
                    }

                    console.log("Log file successfully retrieved. Sending to frontend.");
                    res.json({
                        success: true,
                        message: "VM terminated successfully",
                        logs: data // Return logs, but NOT vmID
                    });
                });
            });
        } catch (error) {
            console.error("Error parsing VM list:", error);
            res.status(500).json({ success: false, message: "Error parsing VM data" });
        }
    });
});


// Endpoint to retrieve the termination log based on vm_id and timestamp
app.get("/terminate-logs", (req, res) => {
  const vmID = req.query.vmID;
  if (!vmID) {
    return res.status(400).json({ success: false, logs: "Missing vmID" });
  }

  const timestampFile = `/tmp/timestamp_killrecovery${vmID}.txt`;

  if (!fs.existsSync(timestampFile)) {
    return res.status(404).json({ success: false, logs: "Timestamp file not found." });
  }

  const timestamp = fs.readFileSync(timestampFile, "utf-8").trim();
  const logPath = `/kvmdr/log/restore/${vmID}/events_${timestamp}.log`;

  if (!fs.existsSync(logPath)) {
    return res.status(404).json({ success: false, logs: "Log file not found." });
  }

  try {
    const logs = fs.readFileSync(logPath, "utf-8");
    return res.json({ success: true, logs });
  } catch (err) {
    return res.status(500).json({ success: false, logs: "Error reading log file." });
  }
});



// Terminate VM to get vmid - for Refresh Log

router.post('/terminate-vmid', async (req, res) => {
  const { vmname } = req.body;
  if (!vmname) return res.status(400).json({ success: false, message: "Missing vmname" });

  exec(`/root/listvmjsondr.sh ${vmname}`, (error, stdout, stderr) => {
    if (error || stderr) {
      return res.status(500).json({ success: false, message: "Error fetching VMID", error: stderr || error.message });
    }

    try {
      const vmData = JSON.parse(stdout);
      if (!vmData.length) return res.status(404).json({ success: false, message: "VMID not found" });

      const vmid = vmData[0].id;
      console.log(`Fetched VMID: ${vmid} for VM Name: ${vmname}`);

      // Step 2: Fetch Log Path using VMID
      exec(`curl -s http://192.168.1.127:3000/terminate-logs -X POST -H "Content-Type: application/json" -d '{"vmid": "${vmid}"}'`, (logError, logStdout, logStderr) => {
        if (logError || logStderr) {
          return res.status(500).json({ success: false, message: "Error fetching log path", error: logStderr || logError.message });
        }

        const logPath = logStdout.trim();
        res.json({ success: true, vmid, logPath });
      });

    } catch (parseError) {
      return res.status(500).json({ success: false, message: "Error parsing VMID response", error: parseError.message });
    }
  });
});


// New Endpoint: /recovery-vm
app.get("/recovery-vm", (req, res) => {
  console.log("Request received for /recovery-vm");

  const backupDbPath = "/root/Backup_Index.db";
  const backupDb = new sqlite3.Database(backupDbPath, (err) => {
    if (err) {
      console.error("Error opening Backup_Index database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to open backup database" });
    }
  });

  const query = `
    SELECT name 
    FROM sqlite_master 
    WHERE type='table' AND name LIKE 'Table_BI_%';
  `;

  backupDb.all(query, [], (err, rows) => {
    backupDb.close();

    if (err) {
      console.error("Error querying Backup_Index database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to query backup database" });
    }

    console.log("Fetched VM tables from Backup_Index:", rows);

    const vmIDs = rows.map((row) => row.name.replace("Table_BI_", ""));
    console.log("Sanitized VM IDs:", vmIDs);

    res.json({ success: true, vmIDs });
  });
});

// New Endpoint: /recovery-logs

// Backend - Fix the response format for logs

app.get("/recovery-logs/:vmid/:timestamp", (req, res) => {
  const { vmid, timestamp } = req.params;
  const logFile = `/kvmdr/log/restore/${vmid}/events_${timestamp}.log`;

  if (fs.existsSync(logFile)) {
    res.sendFile(logFile);  // Send the log file back to the client
  } else {
    res.status(404).json({ error: "BE:Log file not found" });
  }
});

// Endpoint to fetch recovery datetimes for a VM


// Endpoint to fetch recovery datetimes for a VM
app.get("/recovery-datetimes/:vmid", (req, res) => {
  const { vmid } = req.params;
  console.log(`Fetching recovery datetimes for VMID: ${vmid}`);

  if (!vmid) {
    console.error("VMID not provided in /recovery-datetimes request");
    return res.status(400).json({ success: false, message: "VM ID is required" });
  }

  // Sanitize the VMID to match the table naming convention
  const sanitizedVMID = vmid.replace(/-/g, "");
  const tableName = `table_BI_${sanitizedVMID}`;
  console.log(`Sanitized VMID for table: ${tableName}`);

  const dbPath = "/root/Backup_Index.db";
  const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
      console.error("Error opening Backup_Index database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to open backup database" });
    }
  });

  // Query to fetch DateTime (combined Date and Time columns)
  const query = `SELECT Date || ' ' || Time AS DateTime FROM ${tableName} ORDER BY Date ASC, Time ASC;`;

  db.all(query, [], (err, rows) => {
    db.close(); // Always close the database connection at the end

    if (err) {
      console.error("Error executing query:", err.message);
      return res.status(500).json({ success: false, message: "Failed to fetch recovery datetimes" });
    }

    if (rows.length === 0) {
      return res.status(404).json({ success: false, message: "No recovery datetimes found" });
    }

    // Send the response only once after the query completes
    return res.json({ success: true, data: rows });
  });
});


app.post("/recover-NOW", (req, res) => {
  const { vmid, date, time } = req.body;

  // Log the incoming parameters for debugging
  console.log("Received parameters for /recover-NOW:");
  console.log("VMID:", vmid);
  console.log("Date:", date);
  console.log("Time:", time);

  // Validate the input parameters
  if (!vmid || !date || !time) {
    console.error("Missing required parameters for /recover-NOW");
    return res.status(400).json({ success: false, message: "VMID, Date, and Time are required" });
  }

  // Construct the command
  const scriptPath = "/root/commit_FO_recovery_v5.sh";
  const command = `${scriptPath} ${vmid} ${date} ${time}`;
  console.log("Executing command:", command);

  // Execute the script
  const process = spawn(command, { shell: true });

  let outputData = "";
  let errorData = "";

  // Capture stdout
  process.stdout.on("data", (data) => {
    console.log("STDOUT:", data.toString());
    outputData += data.toString();
  });

  // Capture stderr
  process.stderr.on("data", (data) => {
    console.error("STDERR:", data.toString());
    errorData += data.toString();
  });

  // Handle process close
  process.on("close", (code) => {
    console.log(`Process exited with code: ${code}`);
    if (code !== 0) {
      console.error("Recovery script failed with code:", code);
      return res.status(500).json({
        success: false,
        message: "Recovery script execution failed",
        error: errorData || `Exited with code ${code}`,
      });
    }
    console.log("Recovery script executed successfully");
    res.json({ success: true, message: "Recovery script executed successfully", output: outputData });
  });

  // Handle process errors
  process.on("error", (err) => {
    console.error("Error during script execution:", err.message);
    res.status(500).json({ success: false, message: "Script execution error", error: err.message });
  });
});

// Add these routes at the end of your script

app.get("/db/list", (req, res) => {
  const dbPath = "/root/"; // Change this to the correct location of your databases
  const fs = require("fs");
  
  fs.readdir(dbPath, (err, files) => {
    if (err) {
      console.error("Error reading database directory:", err.message);
      return res.status(500).json({ success: false, message: "Failed to read database directory" });
    }

    // You may need to filter for valid database files
    const validDbFiles = files.filter(file => file.endsWith(".db"));
    res.json({ success: true, databases: validDbFiles });
  });
});


app.get("/db/tables", (req, res) => {
  const dbPath = `/root/${req.query.db}`;
  const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
      console.error("Error opening database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to open database" });
    }
  });

  db.all("SELECT name FROM sqlite_master WHERE type='table'", [], (err, rows) => {
    db.close();
    if (err) {
      console.error("Error querying tables:", err.message);
      return res.status(500).json({ success: false, message: "Failed to query tables" });
    }
    res.json({ success: true, tables: rows.map((row) => row.name) });
  });
});

app.get("/db/schema/:tableName", (req, res) => {
  const { tableName } = req.params;
  const dbPath = `/root/${req.query.db}`;
  const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
      console.error("Error opening database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to open database" });
    }
  });

  db.all(`PRAGMA table_info(${tableName})`, [], (err, rows) => {
    db.close();
    if (err) {
      console.error("Error fetching schema:", err.message);
      return res.status(500).json({ success: false, message: "Failed to fetch schema" });
    }
    res.json({ success: true, schema: rows });
  });
});

// Run custom SQL query
app.post("/db/query", (req, res) => {
  const { query } = req.body;

  // Ensure the query is provided
  if (!query) {
    return res.status(400).json({ success: false, message: "Query is required" });
  }

  db.all(query, [], (err, rows) => {
    if (err) {
      return res.status(500).json({ success: false, message: err.message });
    }
    res.json({ success: true, result: rows });
  });
});

// Modify rows in a table
app.post("/db/:action", (req, res) => {
  const action = req.params.action.toLowerCase();
  const { table, data } = req.body;

  if (!table || !data) {
    return res.status(400).json({ success: false, message: "Table and data are required" });
  }

  let query;
  switch (action) {
    case "insert":
      const keys = Object.keys(data).join(", ");
      const values = Object.values(data).map((value) => `'${value}'`).join(", ");
      query = `INSERT INTO ${table} (${keys}) VALUES (${values})`;
      break;

    case "update":
      const updates = Object.keys(data)
        .map((key) => `${key} = '${data[key]}'`)
        .join(", ");
      query = `UPDATE ${table} SET ${updates} WHERE id = ${data.id}`;
      break;

    case "delete":
      query = `DELETE FROM ${table} WHERE id = ${data.id}`;
      break;

    default:
      return res.status(400).json({ success: false, message: "Invalid action" });
  }

  db.run(query, [], function (err) {
    if (err) {
      return res.status(500).json({ success: false, message: err.message });
    }
    res.json({ success: true, result: `${action} successful` });
  });
});


app.get("/db/databases", (req, res) => {
  const dbDir = "/root/"; // Directory where all DBs are stored
  fs.readdir(dbDir, (err, files) => {
    if (err) {
      console.error("Error reading database directory:", err);
      return res.status(500).json({ success: false, message: "Failed to list databases" });
    }
    const databases = files.filter((file) => file.endsWith(".db")); // Filter .db files
    res.json({ success: true, databases });
  });
});

// Backend endpoint to fetch contents from the selected table
app.get("/db/contents", (req, res) => {
  const { db, table } = req.query;
  const dbPath = `/root/${db}`;
  const sqlQuery = `SELECT * FROM ${table}`;

  const database = new sqlite3.Database(dbPath, (err) => {
    if (err) {
      return res.status(500).json({ success: false, message: "Failed to open database" });
    }
  });

  database.all(sqlQuery, [], (err, rows) => {
    database.close();
    if (err) {
      return res.status(500).json({ success: false, message: "Failed to fetch table contents" });
    }
    res.json({ success: true, contents: rows });
  });
});

// Endpoint to drop a specific table
app.post("/db/drop-table", (req, res) => {
  const { tableName } = req.body;
  const dbPath = `/root/${req.query.db}`;
  const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
      console.error("Error opening database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to open database" });
    }
  });

  db.run(`DROP TABLE IF EXISTS ${tableName}`, (err) => {
    if (err) {
      console.error(`Error dropping table ${tableName}:`, err.message);
      return res.status(500).json({ success: false, message: `Failed to drop table ${tableName}` });
    }
    res.json({ success: true, message: `Table ${tableName} dropped successfully` });
  });
});

// Endpoint to drop all tables
app.post("/db/drop-all-tables", (req, res) => {
  const dbPath = "/root/Backup_Index.db"; // Modify as per your DB path
  const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
      console.error("Error opening database:", err.message);
      return res.status(500).json({ success: false, message: "Failed to open database" });
    }
  });

  db.all(`SELECT name FROM sqlite_master WHERE type='table'`, [], (err, rows) => {
    if (err) {
      console.error("Error fetching tables:", err.message);
      return res.status(500).json({ success: false, message: "Failed to fetch tables" });
    }

    rows.forEach((row) => {
      if (row.name !== "sqlite_sequence") {
        db.run(`DROP TABLE IF EXISTS ${row.name}`, (err) => {
          if (err) {
            console.error(`Error dropping table ${row.name}:`, err.message);
            return res.status(500).json({ success: false, message: `Failed to drop table ${row.name}` });
          }
        });
      }
    });

    res.json({ success: true, message: "All tables dropped successfully" });
  });
});


// Endpoint to fetch the latest log timestamp for a given VMID
app.get("/recoverylog-timestamp/:vmid", (req, res) => {
  const { vmid } = req.params;
  console.log(`Fetching recovery log timestamp for VMID: ${vmid}`);

  if (!vmid) {
    console.error("VMID not provided in /recoverylog-timestamp request");
    return res.status(400).json({ success: false, message: "VM ID is required" });
  }

  // Path to the timestamp file
  const timestampFilePath = path.join("/tmp", `timestamp_recovery${vmid}.txt`);

  // Check if the file exists
  if (!fs.existsSync(timestampFilePath)) {
    console.error(`Timestamp file not found for VMID: ${vmid}`);
    return res.status(404).json({ success: false, message: "Timestamp file not found" });
  }

  // Read the timestamp from the file
  try {
    const timestamp = fs.readFileSync(timestampFilePath, "utf8").trim();
    console.log(`Latest timestamp for VMID ${vmid}: ${timestamp}`);
    return res.json({ success: true, timestamp });
  } catch (err) {
    console.error(`Error reading timestamp file for VMID ${vmid}:`, err.message);
    return res.status(500).json({ success: false, message: "Failed to read timestamp file" });
  }
});

app.get("/log-ready/:vmid/:timestamp", (req, res) => {
  const { vmid, timestamp } = req.params;
  const logFilePath = `/kvmdr/log/restore/${vmid}/events_${timestamp}.log`; // Corrected path

  if (fs.existsSync(logFilePath)) {
    res.json({ ready: true });
  } else {
    res.json({ ready: false });
  }
});


// Endpointe to display/refresh the log
app.get("/recovery-log-refresh/:vmid/:timestamp", (req, res) => {
  const { vmid, timestamp } = req.params;

  // Construct the log file path
  const logFilePath = `/kvmdr/log/restore/${vmid}/events_${timestamp}.log`;

  console.log("Checking recovery log at:", logFilePath);

  // Check if the log file exists
  if (fs.existsSync(logFilePath)) {
    console.log("Log file found:", logFilePath);

    // Send the log file content
    res.sendFile(logFilePath);
  } else {
    console.error("Log file not found at:", logFilePath);
    res.status(404).json({ error: "Log file not found" });
  }
});

// Endpoint to download recovery logs for a VM
app.get("/recovery-log-download/:vmid/:timestamp", (req, res) => {
  const { vmid, timestamp } = req.params;

  // Construct the log file path
  const logFilePath = `/kvmdr/log/restore/${vmid}/events_${timestamp}.log`;

  if (fs.existsSync(logFilePath)) {
    // Set headers for download
    res.setHeader("Content-Disposition", `attachment; filename=events_${timestamp}.log`);
    res.setHeader("Content-Type", "text/plain");

    // Send the log file
    res.sendFile(logFilePath);
  } else {
    res.status(404).json({ error: "Log file not found" });
  }
});


// Logs 

// Endpoint to fetch job details
app.get('/logs/jobid', (req, res) => {
  const jobId = req.query.jobid;
  
  if (!jobId) {
    return res.status(400).json({ error: "Job ID is required" });
  }

  console.log(`Received jobid: ${jobId}`); // For debugging purposes

  vmSettingsDb.all(
    "SELECT job_id, job_type, vm_id, timestamp, status, logs_path FROM table_jobid WHERE job_id = ?",
    [jobId],
    (err, rows) => {
      if (err) {
        console.error("Error fetching jobs by Job ID:", err.message);
        return res.status(500).json({ error: "Failed to fetch jobs" });
      }

      if (rows.length === 0) {
        return res.status(404).json({ error: "Job ID not found" }); // Handling case where no job found
      }

      res.json(rows);
    }
  );
});


// Endpoint to fetch jobs by VM Name

app.get('/logs/vmname', (req, res) => {
  const query = "SELECT DISTINCT vm_name FROM table_jobid";
  vmSettingsDb.all(query, (err, rows) => {
    if (err) {
      console.error("Error fetching VM names:", err.message);
      return res.status(500).json({ error: "Failed to fetch VM names" });
    }
    const vmNames = rows.map(row => row.vm_name); // Extract VM names
    res.json(vmNames); // Return only names as an array
  });
});

// Endpoint to fetch jobs by Job Type
app.get('/logs/jobtype', (req, res) => {
  vmSettingsDb.all(
    "SELECT DISTINCT job_type FROM table_jobid", // Fetch distinct job types
    (err, rows) => {
      if (err) {
        console.error("Error fetching job types:", err.message);
        return res.status(500).json({ error: "Failed to fetch job types" });
      }
      const jobTypes = rows.map(row => row.job_type); // Extract only job_type
      res.json(jobTypes); // Return list of job types
    }
  );
});

app.get('/logs/vmname_details', (req, res) => {
  const { vmname } = req.query; // Retrieve VM name from query params
  if (!vmname) {
    return res.status(400).json({ error: "VM name is required" });
  }

  // Step 1: Retrieve vmid from /vms endpoint from backupIndexDb based on vmname
  fetch("http://192.168.1.127:3000/vms")
    .then(response => response.json())
    .then(vms => {
      const vm = vms.vms.find(vm => vm.name === vmname);  // Find the VM by name
      if (!vm) {
        return res.status(404).json({ error: "VM not found" });
      }

      const vmid = vm.id; // Retrieved vmid from /vms
      console.log("Retrieved vmid for vmname:", vmname, "is", vmid); // Log the vmid

      // Step 2: Query from table_jobid using vmSettingsDb with the vmid
      const query = `
        SELECT job_id, job_type, vm_id, timestamp, status, logs_path
        FROM table_jobid
        WHERE vm_id = ?;
      `;
      console.log("Executing query:", query); // Log the query being executed

      vmSettingsDb.all(query, [vmid], (err, rows) => {
        if (err) {
          console.error("Error fetching job details for vmid:", err.message);
          return res.status(500).json({ error: "Failed to fetch job details" });
        }

        if (rows.length === 0) {
          return res.status(404).json({ error: "No job details found for this vmid" });
        }

        res.json(rows); // Send job details as response
      });
    })
    .catch(err => {
      console.error("Error fetching VM data from /vms:", err.message);
      res.status(500).json({ error: "Failed to fetch VM details" });
    });
});

app.get('/logs/jobtype_details', (req, res) => {
    const jobType = req.query.jobtype; // Get job type from query parameters

    // Validate input
    if (!jobType) {
        return res.status(400).json({ error: "Job type is required" });
    }

    // Query to fetch job details based on the job type
    const query = `
        SELECT job_id, job_type, vm_id, timestamp, status, logs_path
        FROM table_jobid
        WHERE job_type = ?
    `;
    const params = [jobType];

    vmSettingsDb.all(query, params, (err, rows) => {
        if (err) {
            console.error("Error fetching job type details:", err.message);
            return res.status(500).json({ error: "Failed to fetch job type details" });
        }
        res.json(rows); // Send back the details as a JSON response
    });
});


// Endpoint to fetch log file content
app.get('/logs/content', (req, res) => {
  const logPath = req.query.path;

  // Validate input
  if (!logPath) {
    return res.status(400).json({ error: "Log path is required" });
  }

  // Sanitize the log path (ensure it's within allowed directories)
  const sanitizedPath = path.normalize(logPath);
  if (!sanitizedPath.startsWith('/kvmdr/log')) {
    return res.status(403).json({ error: "Access to this log file is forbidden" });
  }

  // Read the file
  fs.readFile(sanitizedPath, 'utf8', (err, data) => {
    if (err) {
      console.error(`Error reading log file: ${err.message}`);
      return res.status(500).json({ error: "Failed to fetch log content" });
    }

    res.send(data); // Send the file content as plain text
  });
});

app.get('/logs/jobid_details', (req, res) => {
  const jobId = req.query.jobid;
  
  if (!jobId) {
    return res.status(400).json({ error: "Job ID is required" });
  }

  vmSettingsDb.all(
    "SELECT job_id, job_type, vm_id, timestamp, status, logs_path FROM table_jobid WHERE job_id = ?",
    [jobId],
    (err, rows) => {
      if (err) {
        console.error("Error fetching logs by Job ID:", err.message);
        return res.status(500).json({ error: "Failed to fetch logs" });
      }
      res.json(rows); // Send the job logs as the response
    }
  );
});

//Latest Log

app.get('/logs/latestlog', (req, res) => {
  const { searchBy, value } = req.query; // Extract search criteria and value from query parameters

  if (!searchBy || !value) {
    return res.status(400).json({ error: 'searchBy and value are required' });
  }

  let query = '';
  if (searchBy === 'vm_name') {
    query = `SELECT * FROM table_jobid WHERE vm_name = ? ORDER BY CAST(timestamp AS INTEGER) DESC LIMIT 1`;
  } else if (searchBy === 'job_type') {
    query = `SELECT * FROM table_jobid WHERE job_type = ? ORDER BY CAST(timestamp AS INTEGER) DESC LIMIT 1`;
  } else {
    return res.status(400).json({ error: 'Invalid searchBy value' });
  }

  // Query the database to get the logs for the most recent entry
  vmSettingsDb.get(query, [value], (err, row) => {
    if (err) {
      console.error("Error fetching logs:", err.message);
      return res.status(500).json({ error: 'Error fetching logs' });
    }

    if (row) {
      // Log path and other details from the row
      const logsPath = row.logs_path;
      const timestamp = row.timestamp;
      const jobId = row.job_id;
      const jobType = row.job_type;
      const vmId = row.vm_id;
      const status = row.status;

      // Create a response object with the details of the latest log
      const latestLog = {
        jobId,
        jobType,
        vmId,
        status,
        timestamp,
        logsPath
      };

      console.log("Latest log details:", latestLog);
      return res.json(latestLog); // Send the latest log details as a response
    } else {
      console.error("No logs found for the given criteria.");
      return res.status(404).json({ error: 'No logs found for the given criteria' });
    }
  });
});




//Replication Status 

// Endpoint to check pairing and retrieve date/time - InitialSync
app.get("/check-vm-pairing/:vmid", (req, res) => {
  const vmid = req.params.vmid;
  const sanitizedVMID = vmid.replace(/-/g, ""); // Remove dashes for sanitization
  const pairingTableName = `table_BI_${sanitizedVMID}`; // Table for pairing information

  // Step 1: Check if the pairing table exists
  const checkTableQuery = `SELECT name FROM sqlite_master WHERE type='table' AND name='${pairingTableName}'`;

  backupIndexDb.get(checkTableQuery, (err, row) => {
    if (err) {
      console.error("Database error while checking table existence:", err.message);
      return res.status(500).json({ message: "Database error", error: err });
    }

    if (!row) {
      // Table does not exist; VM is not protected
      return res.json({ paired: false, message: "VM is not Protected yet" });
    }

    // Step 2: If table exists, fetch Date and Time
     const fetchDateTimeQuery = `SELECT Date, Time FROM ${pairingTableName} WHERE Full_Backup = 1 ORDER BY id ASC LIMIT 1;`;


    backupIndexDb.get(fetchDateTimeQuery, (err, dateTimeRow) => {
      if (err) {
        console.error("Database error while fetching Date and Time:", err.message);
        return res.status(500).json({ message: "Database error", error: err });
      }

      if (dateTimeRow) {
        // Return the pairing status with Date and Time
        return res.json({
          paired: true,
          message: "VM is paired with Target",
          lastBackupDate: dateTimeRow.Date || "Unknown",
          lastBackupTime: dateTimeRow.Time || "Unknown",
        });
      } else {
        // Table exists but no Date/Time entries found
        return res.json({
          paired: true,
          message: "VM is paired with Target, but no backups found",
          lastBackupDate: "No backups found",
          lastBackupTime: "No backups found",
        });
      }
    });
  });
});


// Endpoint to fetch the last incremental backup date/time - CBT Delta

app.get("/check-incremental-backup/:vmid", (req, res) => {
  const vmid = req.params.vmid;
  const sanitizedVMID = vmid.replace(/-/g, ""); // Sanitize the VM ID by removing dashes
  const incrementalTableName = `incremental_${sanitizedVMID}`; // Incremental table name

  // Step 1: Check if the incremental table exists
  const checkTableQuery = `SELECT name FROM sqlite_master WHERE type='table' AND name='${incrementalTableName}'`;

  backupIndexDb.get(checkTableQuery, (err, row) => {
    if (err) {
      console.error("Database error while checking table existence:", err.message);
      return res.status(500).json({ message: "Database error", error: err });
    }

    if (!row) {
      // Table does not exist
      return res.json({
        success: false,
        message: "No incremental backups found for this VM",
      });
    }

    // Step 2: Fetch the most recent Date and Time from the incremental table
    const fetchDateTimeQuery = `SELECT Date, Time FROM ${incrementalTableName} ORDER BY rowid DESC LIMIT 1`;

    backupIndexDb.get(fetchDateTimeQuery, (err, dateTimeRow) => {
      if (err) {
        console.error("Database error while fetching Date and Time:", err.message);
        return res.status(500).json({ message: "Database error", error: err });
      }

      if (dateTimeRow) {
        // Return the latest Date and Time for the incremental backup
        res.json({
          success: true,
          lastBackupDate: dateTimeRow.Date,
          lastBackupTime: dateTimeRow.Time,
        });
      } else {
        // Table exists but no backup entries found
        res.json({
          success: false,
          message: "No incremental backups found",
        });
      }
    });
  });
});

app.get("/get-target-engineip", (req, res) => {
  const query = `SELECT engine_ip FROM Target LIMIT 1`;

  vmSettingsDb.get(query, (err, row) => {
    if (err) {
      console.error("Database error while fetching engine IP:", err.message);
      return res.status(500).json({ message: "Database error", error: err });
    }

    if (row) {
      res.json({ success: true, engine_ip: row.engine_ip });
    } else {
      res.json({ success: false, message: "No engine IP found in the database" });
    }
  });
});

//Simulator-Source

app.post("/simulation-source-DR", (req, res) => {
  console.log("Received a request for /simulation-source-DR");
  console.log("Request Body:", req.body);

  const { vmid, date, time } = req.body;

  if (!vmid || !date || !time) {
    console.error("Error: Missing required fields in the request body.");
    return res.status(400).json({
      success: false,
      message: "Missing required fields: vmid, date, time.",
    });
  }

  console.log(`Starting simulation for VMID: ${vmid}, Date: ${date}, Time: ${time}`);

  // Execute the simulation source recovery script with absolute path
  const command = `/root/sourcesimulator_v29.sh ${vmid} ${date} ${time}`;
  console.log("Executing Command:", command);

  const process = exec(command);

  let outputData = "";
  let errorData = "";

  // Collect output from the script
  process.stdout.on("data", (data) => {
    console.log("STDOUT:", data);
    outputData += data;
  });

  // Collect error data from the script
  process.stderr.on("data", (data) => {
    console.error("STDERR:", data);
    errorData += data;
  });

  // Handle process close
  process.on("close", (code) => {
    console.log(`Process exited with code: ${code}`);
    if (code !== 0) {
      console.error("Simulation Source DR script failed with code:", code);
      return res.status(500).json({
        success: false,
        message: "Simulation Source DR script execution failed",
        error: errorData || `Exited with code ${code}`,
      });
    }
    console.log("Simulation Source DR script executed successfully");
    res.json({
      success: true,
      message: "Simulation Source DR script executed successfully",
      output: outputData,
    });
  });

  // Log any unexpected errors in the request lifecycle
  process.on("error", (err) => {
    console.error("Error in processing request:", err);
    res.status(500).json({
      success: false,
      message: "Internal server error while executing simulation.",
      error: err.message,
    });
  });
});

app.get("/simulation-logs", (req, res) => {
  const vmID = req.query.vmID;
  if (!vmID) {
    return res.status(400).json({ success: false, logs: "Missing vmID" });
  }

  const timestampFile = `/tmp/timestamp_simulator${vmID}.txt`;

  if (!fs.existsSync(timestampFile)) {
    return res.status(404).json({ success: false, logs: "Timestamp file not found." });
  }

  const timestamp = fs.readFileSync(timestampFile, "utf-8").trim();
  const logPath = `/kvmdr/log/restore/${vmID}/events_${timestamp}.log`;

  if (!fs.existsSync(logPath)) {
    return res.status(404).json({ success: false, logs: "Log file not found." });
  }

  try {
    const logs = fs.readFileSync(logPath, "utf-8");
    return res.json({ success: true, logs });
  } catch (err) {
    return res.status(500).json({ success: false, logs: "Error reading log file." });
  }
});



app.get("/simulator-active", (req, res) => {
  console.log("Fetching currently active simulators...");

  const activeSimulators = [];

  // Step 1: Find all tables starting with "drsimulator_"
  const queryTables = `
    SELECT name
    FROM sqlite_master
    WHERE type='table' AND name LIKE 'drsimulator_%';
  `;

  backupIndexDb.all(queryTables, [], (err, rows) => {
    if (err) {
      console.error("Error fetching simulator tables:", err.message);
      return res.status(500).json({ success: false, message: "Failed to fetch simulator tables" });
    }

    if (rows.length === 0) {
      console.log("No active simulations found.");
      return res.json({ success: true, simulators: [] });
    }

    // Step 2: Fetch details from each table
    let processedTables = 0;
    rows.forEach((row) => {
      const tableName = row.name;
      const queryTableData = `
        SELECT 
          new_vmid,
          vmname,
          original_vmid,
          rewind_date,
          rewind_time
        FROM ${tableName};
      `;

      backupIndexDb.all(queryTableData, [], (err, tableRows) => {
        processedTables++;

        if (err) {
          console.error(`Error fetching data from table ${tableName}:`, err.message);
        } else {
          tableRows.forEach((data) => {
            activeSimulators.push({
              vmid: data.new_vmid,
              name: data.vmname,
              original_vmid: data.original_vmid,
              rewind_date: data.rewind_date,
              rewind_time: data.rewind_time,
              table: tableName,
            });
          });
        }

        // Respond once all tables are processed
        if (processedTables === rows.length) {
          console.log("Active simulators fetched:", activeSimulators);
          return res.json({ success: true, simulators: activeSimulators });
        }
      });
    });
  });
});


// Endpoint to terminate simulation
app.post('/simulator-terminate', (req, res) => {
  const { vmid } = req.body;

  if (!vmid) {
    console.error('[simulation-terminate] Missing vmid in request body');
    return res.status(400).json({
      success: false,
      message: 'Missing vmid',
    });
  }

  console.log(`[simulation-terminate] Received request to terminate VMID: ${vmid}`);

  // Call your termination script with the vmid as an argument
  exec(`/root/killsourcesimulator_v1.sh ${vmid}`, (error, stdout, stderr) => {
    if (error) {
      console.error(`[simulation-terminate] Failed to terminate VMID: ${vmid}`);
      console.error(`[simulation-terminate] Error: ${error.message}`);
      console.error(`[simulation-terminate] Stderr: ${stderr}`);
      return res.status(500).json({
        success: false,
        message: 'Error terminating simulation. Check server logs.',
      });
    }

    console.log(`[simulation-terminate] Successfully terminated VMID: ${vmid}`);
    console.log(`[simulation-terminate] Stdout: ${stdout}`);

    return res.json({
      success: true,
      message: 'Simulation terminated successfully.',
    });
  });
});


// Simulator Convert Recovery
app.post("/commitrecovery-simulation", (req, res) => {
  const { vmid, date, time } = req.body;

  if (!vmid || !date || !time) {
    return res.status(400).json({ success: false, message: "Missing required params" });
  }

  const cmd = `bash /root/sourcesim_commitrecovery_v7.sh ${vmid} ${date} ${time}`;
  const child = require("child_process").exec;

  console.log("Executing:", cmd); // Debug

  child(cmd, (error, stdout, stderr) => {
    console.log("STDOUT:", stdout);
    console.log("STDERR:", stderr);
    if (error) {
      return res.status(500).json({ success: false, message: "Commit recovery failed." });
    }
    return res.json({ success: true, message: "Commit recovery initiated." });
  });
});



app.get("/commitrecovery-logs", (req, res) => {
  const vmID = req.query.vmID;
  if (!vmID) return res.status(400).json({ success: false, logs: "Missing vmID" });

  const timestampFile = `/tmp/timestamp_commitrecovery${vmID}.txt`;

  if (!fs.existsSync(timestampFile)) {
    return res.status(404).json({ success: false, logs: "Timestamp file not found." });
  }

  const timestamp = fs.readFileSync(timestampFile, "utf-8").trim();
  const logPath = `/kvmdr/log/restore/${vmID}/events_${timestamp}.log`;

  if (!fs.existsSync(logPath)) {
    return res.status(404).json({ success: false, logs: "Log file not found." });
  }

  try {
    const logs = fs.readFileSync(logPath, "utf-8");
    return res.json({ success: true, logs });
  } catch (err) {
    return res.status(500).json({ success: false, logs: "Error reading log file." });
  }
});





// Start HTTP server
app.listen(3000, "192.168.1.127", () => {
  console.log("HTTP Server running on http://192.168.1.127:3000");
});


// Create a WebSocket server
const wss = new WebSocket.Server({ port: 3001 });

console.log('WebSocket Server running on ws://192.168.1.127:3001');

// Handle new connections
wss.on('connection', (ws) => {
  console.log('WebSocket connection established.');

  // Listen for messages from clients
  ws.on('message', (message) => {
    const messageString = message.toString(); // Convert Buffer to string
    console.log('Server received:', messageString);

    // Broadcast the message to all connected clients
    wss.clients.forEach((client) => {
      if (client.readyState === WebSocket.OPEN) {
        client.send(messageString); // Send the message as a string
      }
    });
  });

  // Handle client disconnections
  ws.on('close', () => {
    console.log('WebSocket connection closed.');
  });

  // Handle errors
  ws.on('error', (error) => {
    console.error('WebSocket error:', error);
  });
});

//Tasks

app.get("/tasks", (req, res) => {
    vmSettingsDb.all("SELECT * FROM table_jobid WHERE status = 'Running'", (err, rows) => {
        if (err) {
            console.error("Error fetching tasks:", err.message);
            return res.status(500).json({ error: "Failed to fetch tasks" });
        }
        res.json(rows);
    });
});

// Archive Recovery

app.get("/archive/vms", (req, res) => {
  const query = `
    SELECT
      vmId AS vm_id,
      vmName AS vm_name,
      archive_recovery,
      archive_retention,
      archive_target  -- Include this field here
    FROM vmAttribs
    WHERE archive_recovery = 'on';
  `;

  vmSettingsDb.all(query, [], (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });

    const backupIndexDb = new sqlite3.Database(backupIndexDbPath);
    const finalResults = [];

    backupIndexDb.all(
      `SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'table_BI_%'`,
      [],
      (err2, tableRows) => {
        if (err2) return res.status(500).json({ error: err2.message });

        const validTables = tableRows.map((t) => t.name);

        rows.forEach((vm) => {
          const sanitized = vm.vm_id.replace(/-/g, "");
          const expectedTable = `table_BI_${sanitized}`;
          if (validTables.includes(expectedTable)) {
            finalResults.push({
              ...vm,
              protected: 1, // Mark as protected if matching table is found
            });
          }
        });

        res.json(finalResults); // Return results with archive_target included
      }
    );
  });
});

app.post("/archive/save-settings", (req, res) => {
  const { vm_id, archive_retention, archive_target } = req.body;

  if (!vm_id || archive_retention == null || !archive_target) {
    return res.status(400).json({ error: "Missing required fields" });
  }

  const updateQuery = `
    UPDATE vmAttribs
    SET archive_retention = ?, archive_target = ?  -- Update this field to archive_target
    WHERE vmId = ?
  `;

  vmSettingsDb.run(updateQuery, [archive_retention, archive_target, vm_id], function (err) {
    if (err) {
      console.error("Error updating settings:", err.message);
      return res.status(500).json({ error: "Failed to update settings" });
    }

    if (this.changes === 0) {
      return res.status(404).json({ error: "VM not found" });
    }

    res.json({ message: "Settings updated" });
  });
});

// Fetch archive date and time
app.get("/archive-fetchtimedate/:vmid", (req, res) => {
  const { vmid } = req.params;

  if (!vmid) {
    return res.status(400).json({ success: false, message: "VMID is required" });
  }

  const sanitizedVMID = vmid.replace(/-/g, ""); // Sanitize VMID
  const tableName = `archive_table_BI_${sanitizedVMID}`;  // Correct table name

  // Query to fetch all recovery Date and Time for this VM
  const query = `SELECT Date, Time FROM ${tableName} ORDER BY Date DESC, Time DESC;`;

  backupIndexDb.all(query, [], (err, rows) => {
    if (err) {
      console.error("Error fetching recovery date and time:", err.message);
      return res.status(500).json({ success: false, message: "Failed to fetch recovery date and time" });
    }

    if (rows.length === 0) {
      return res.status(404).json({ success: false, message: "No recovery data found for this VM" });
    }

    // Send back all fetched Date and Time entries
    return res.json({
      success: true,
      message: "Recovery date and time fetched successfully",
      data: rows // rows should now contain all Date and Time entries
    });
  });
});




//Migration

app.get('/migration/targets', (req, res) => {
  vmSettingsDb.all('SELECT engine_ip FROM Target', [], (err, rows) => {
    if (err) {
      console.error('Error fetching targets:', err.message);
      return res.status(500).json({ success: false, error: err.message });
    }
    res.json({ success: true, targets: rows.map(row => row.engine_ip) });
  });
});

const fetch = require("node-fetch");

// Start Migration

app.post("/migration/start", async (req, res) => {
  const { vmName } = req.body;

  if (!vmName) {
    console.error("Error: VM name not provided");
    return res.status(400).json({ success: false, error: "VM name is required" });
  }

  console.log(`Received request for VM migration: vmName = ${vmName}`);

  try {
    // Fetch VM list from /vms
    const response = await fetch("http://192.168.1.127:3000/vms");
    const data = await response.json();

    if (!data.success || !data.vms) {
      console.error("Error fetching VM list");
      return res.status(500).json({ success: false, error: "Failed to retrieve VM list" });
    }

    // Find the VM by name
    const vm = data.vms.find((v) => v.name === vmName);
    if (!vm) {
      console.error(`Error: VM not found - ${vmName}`);
      return res.status(404).json({ success: false, error: "VM not found" });
    }

    const vmId = vm.id;
    console.log(`Found VM: vmName = ${vmName}, vmId = ${vmId}`);

    // Execute migration script
    const command = `/root/migration_v2.sh ${vmId}`;
    console.log(`Executing: ${command}`);

    exec(command, (error, stdout, stderr) => {
      if (error) {
        console.error(`Migration error: ${stderr}`);
        return res.status(500).json({ success: false, error: stderr.trim() });
      }

      console.log(`Migration successful: ${stdout}`);
      res.json({ success: true, message: stdout.trim() });
    });

  } catch (err) {
    console.error("Unhandled error:", err);
    res.status(500).json({ success: false, error: "Unexpected error occurred" });
  }
});

// Log Migration

app.use(express.json());

const LOG_DIR = "/kvmdr/log/migration/";
const TIMESTAMP_DIR = "/tmp/";

// 📌 NEW: Fetch Migration Logs API
app.get("/migration/logs/:vm_id", (req, res) => {
  const vmId = req.params.vm_id;
  const timestampFile = path.join(TIMESTAMP_DIR, `timestamp_migration${vmId}.txt`);

  // Check if timestamp file exists
  if (!fs.existsSync(timestampFile)) {
    return res.status(404).json({ success: false, error: `Timestamp file for VM ${vmId} not found` });
  }

  // Read the timestamp from the file
  fs.readFile(timestampFile, "utf8", (err, timestamp) => {
    if (err) {
      console.error("Error reading timestamp:", err.message);
      return res.status(500).json({ success: false, error: "Failed to read timestamp" });
    }

    const logFilePath = path.join(LOG_DIR, vmId, `events_${timestamp.trim()}.log`);

    // Check if log file exists
    if (!fs.existsSync(logFilePath)) {
      return res.status(404).json({ success: false, error: `Log file not found: ${logFilePath}` });
    }

    // Read and return logs
    fs.readFile(logFilePath, "utf8", (err, logData) => {
      if (err) {
        console.error("Error reading log file:", err.message);
        return res.status(500).json({ success: false, error: "Failed to read logs" });
      }

      const logs = logData.split("\n").filter((line) => line.trim() !== "");
      res.json({ success: true, logs });
    });
  });
});

// Archive Recovery with diff recovery script

app.post("/archive-recovery", (req, res) => {
  const { vmid, date, time } = req.body;

  // Log the incoming parameters for debugging
  console.log("Received parameters for /recover-NOW:");
  console.log("VMID:", vmid);
  console.log("Date:", date);
  console.log("Time:", time);

  // Validate the input parameters
  if (!vmid || !date || !time) {
    console.error("Missing required parameters for /recover-NOW");
    return res.status(400).json({ success: false, message: "VMID, Date, and Time are required" });
  }

  // Construct the command
  const scriptPath = "/root/archive_recovery_v1.sh";
  const command = `${scriptPath} ${vmid} ${date} ${time}`;
  console.log("Executing command:", command);

  // Execute the script
  const process = spawn(command, { shell: true });

  let outputData = "";
  let errorData = "";

  // Capture stdout
  process.stdout.on("data", (data) => {
    console.log("STDOUT:", data.toString());
    outputData += data.toString();
  });

  // Capture stderr
  process.stderr.on("data", (data) => {
    console.error("STDERR:", data.toString());
    errorData += data.toString();
  });

  // Handle process close
  process.on("close", (code) => {
    console.log(`Process exited with code: ${code}`);
    if (code !== 0) {
      console.error("Recovery script failed with code:", code);
      return res.status(500).json({
        success: false,
        message: "Recovery script execution failed",
        error: errorData || `Exited with code ${code}`,
      });
    }
    console.log("Recovery script executed successfully");
    res.json({ success: true, message: "Recovery script executed successfully", output: outputData });
  });

  // Handle process errors
  process.on("error", (err) => {
    console.error("Error during script execution:", err.message);
    res.status(500).json({ success: false, message: "Script execution error", error: err.message });
  });
});


//Dashboard Return Values-RPO

app.get("/rpo", (req, res) => {
  vmSettingsDb.get("SELECT rpo FROM Source LIMIT 1", (err, row) => {
    if (err) {
      console.error("Error retrieving RPO from Source:", err.message);
      return res.status(500).json({ success: false, message: "Database error" });
    }

    if (!row) {
      return res.status(404).json({ success: false, message: "No RPO found" });
    }

    res.json({ success: true, rpo: row.rpo });
  });
});

app.get("/report/protection-rpo-json", async (req, res) => {
  const fetch = require("node-fetch");
  const normalizeVmId = (id) => id.replace(/-/g, "").toLowerCase();
  const rpoTarget = parseInt(req.query.rpo) || 10;
  const windowHours = parseInt(req.query.window) || 24;

  const getIncrementals = (vmid, windowHours) => {
    return new Promise((resolve) => {
      const table = `table_BI_${normalizeVmId(vmid)}`;
      const query = `
        SELECT date, time
        FROM ${table}
        WHERE Full_Backup IN (0, 25)
          AND datetime(date || ' ' || time) >= datetime('now', '-${windowHours} hours')
        ORDER BY rowid ASC
      `;
      backupIndexDb.all(query, [], (err, rows) => {
        if (err) {
          if (err.message.includes("no such table")) {
            console.warn(`Table not found for VM ${vmid}, skipping.`);
            return resolve([]);
          }
          console.error(`SQLite error for VM ${vmid}:`, err.message);
          return resolve([]);
        }
        if (!rows || rows.length < 2) return resolve([]);
        const timestamps = rows.map((r) => new Date(`${r.date}T${r.time}`));
        resolve(timestamps);
      });
    });
  };

  const checkRpoMet = async (vmid, rpo, window) => {
    const times = await getIncrementals(vmid, window);
    if (times.length < 2) return false;
    for (let i = 1; i < times.length; i++) {
      const gap = (times[i] - times[i - 1]) / (1000 * 60);
      if (gap > rpo) return false;
    }
    return true;
  };

  try {
    console.log("Fetching only protected VMs from /filtered-vms...");
    const protectedRes = await fetch("http://192.168.1.127:3000/filtered-vms").then((r) => r.json());
    const protectedIDs = (protectedRes?.vmIDs || []).map((id) => id.replace("table_BI_", ""));

    const vmsRes = await fetch("http://192.168.1.127:3000/vms").then((r) => r.json());
    const allVMs = vmsRes?.vms || [];

    const reportData = [];

    for (const normId of protectedIDs) {
      const vm = allVMs.find((v) => normalizeVmId(v.id) === normId);
      if (!vm) {
        console.warn(`VM with ID ${normId} not found in /vms, skipping`);
        continue;
      }

      const rpoMet = await checkRpoMet(vm.id, rpoTarget, windowHours);

      reportData.push({
        name: vm.name,
        id: vm.id,
        status: vm.status,
        protected: true,
        rpoTarget,
        rpoMet,
      });
    }

    res.json({ success: true, data: reportData });
  } catch (err) {
    console.error("Fatal error generating report:", err.message);
    res.status(500).json({ success: false, message: "Failed to generate report" });
  }
});

app.get("/report/last-sync/:vmid", (req, res) => {
  const { vmid } = req.params;

  if (!vmid) {
    return res.status(400).json({ success: false, message: "VMID is required" });
  }

  const tableName = `table_BI_${vmid.replace(/-/g, "").toLowerCase()}`;
  const query = `
    SELECT Date, Time, Duration 
    FROM ${tableName}
    WHERE Full_Backup = 25
    ORDER BY rowid DESC
    LIMIT 1;
  `;

  backupIndexDb.get(query, [], (err, row) => {
    if (err) {
      console.error(`Error accessing ${tableName}:`, err.message);
      return res.status(500).json({ success: false, message: "Database error" });
    }

    if (!row) {
      return res.status(404).json({ success: false, message: "No sync record found" });
    }

    const { Date, Time, Duration } = row;
    return res.json({
      success: true,
      lastSyncTime: `${Date} ${Time}`,
      duration: Duration,
    });
  });
});

// HE Backup in Settings

app.post("/backup/HE/:host", (req, res) => {
  const { host } = req.params;
  const { backup_time } = req.body;

  if (!host) {
    return res.status(400).json({ success: false, message: "Host is required" });
  }

  // Validate and default time
  const timeRegex = /^([01]\d|2[0-3]):([0-5]\d)$/;
  const timeToUse = timeRegex.test(backup_time) ? backup_time : "02:00";

  const scriptPath = "/root/HE_backup_v5.sh";
  const command = `${scriptPath} ${host} "${timeToUse}"`;  // ✅ PASS THE TIME ARGUMENT

  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Backup script error: ${error.message}`);
      return res.status(500).json({ success: false, message: "Backup failed", error: error.message });
    }

    if (stderr) {
      console.warn(`Backup script stderr: ${stderr}`);
    }

    console.log(`Backup script output: ${stdout}`);
    return res.json({ success: true, message: `Backup initiated for ${host} at ${timeToUse}`, log: stdout });
  });
});

// Update he_protection_enabled flag in Source or Target table
app.post("/update-he-protection", (req, res) => {
  const { hostType, enabled, backup_time } = req.body;

  if (!hostType || (hostType !== "source" && hostType !== "target")) {
    return res.status(400).json({ success: false, message: "Invalid hostType. Must be 'source' or 'target'." });
  }

  const table = hostType === "source" ? "Source" : "Target";
  const value = enabled ? 1 : 0;
  const time = backup_time || "02:00";

  const sqlite3 = require("sqlite3").verbose();
  const db = new sqlite3.Database("/root/vmSettings.db");

  db.run(
    `UPDATE ${table} SET he_protection_enabled = ?, he_backup_time = ? WHERE id = 1`,
    [value, time],
    function(err) {
      db.close();
      if (err) {
        console.error("DB Update Error:", err.message);
        return res.status(500).json({ success: false, message: "Failed to update HE Protection setting." });
      }
      console.log(`[INFO] Updated HE ${hostType.toUpperCase()}: enabled=${value}, time=${time}`);
      return res.json({ success: true, message: "HE Protection + Time updated." });
    }
  );
});



// List available HE Recovery Hosts
app.get('/recovery/hosts', (req, res) => {
  const query = `
    SELECT 'Source' AS type, host_ip AS host
    FROM Source
    WHERE he_protection_enabled = 1
    UNION ALL
    SELECT 'Target' AS type, host_ip AS host
    FROM Target
    WHERE he_protection_enabled = 1;
  `;

  vmSettingsDb.all(query, [], (err, rows) => {
    if (err) {
      console.error("Error querying HE recovery hosts:", err.message);
      res.status(500).json({ success: false, message: "Failed to fetch recovery hosts." });
    } else {
      res.json({ success: true, data: rows });
    }
  });
});

// List available backups for a selected host (under he_recovery)
app.get('/he_recovery/backups/:host', (req, res) => {
  const { host } = req.params;

  if (!host) {
    return res.status(400).json({ success: false, message: "Host parameter is required." });
  }

  const query = `
    SELECT 
      id AS backup_id,
      backup_date,
      backup_time,
      engine_backup_file,
      ova_file,
      dom_md_available,
      dom_md_path,
      answers_conf_path,
      hosted_engine_conf_path
    FROM he_backups
    WHERE host = ?
    ORDER BY backup_date DESC, backup_time DESC;
  `;

  backupIndexDb.all(query, [host], (err, rows) => {
    if (err) {
      console.error("Error querying backups:", err.message);
      return res.status(500).json({ success: false, message: "Failed to fetch backups." });
    }
    res.json({ success: true, data: rows });
  });
});

//HE_recovery


function logMessage(logFilePath, message) {
  const timestamp = new Date().toISOString();
  const fullMessage = `[${timestamp}] ${message}\n`;
  fs.appendFileSync(logFilePath, fullMessage);
}


// POST /he_recovery/start
router.post("/he_recovery/start", (req, res) => {
  const { host, backup_date, backup_time, selected_files, timestamp } = req.body;

  if (!host || !backup_date || !backup_time || !Array.isArray(selected_files) || !timestamp) {
    return res.status(400).json({ success: false, message: "Missing required fields or invalid data." });
  }

  const targetRecoveryBase = `/backup/tmp/he_recovery/${host}`;
  const timestampFolder = `${targetRecoveryBase}/${timestamp}`;
  const recoveryLogDir = `/kvmdr/log/${host}_HE_recovery/`;
  const traceLog = `${recoveryLogDir}/trace_${timestamp}.log`;
  const eventLog = `${recoveryLogDir}/events_${timestamp}.log`;

  backupIndexDb.get(
    `SELECT * FROM he_backups WHERE host = ? AND backup_date = ? AND backup_time = ?`,
    [host, backup_date, backup_time],
    async (err, backup) => {
      if (err) {
        console.error("DB error during recovery:", err);
        return res.status(500).json({ success: false, message: "Database query error." });
      }
      if (!backup) {
        return res.status(404).json({ success: false, message: "Backup record not found." });
      }

      try {
        await fse.ensureDir(recoveryLogDir);
        await fse.ensureDir(targetRecoveryBase);
        await fse.ensureDir(timestampFolder);

        logMessage(traceLog, "[INFO] Starting Hosted Engine Recovery");
        logMessage(eventLog, "[INFO] Starting Hosted Engine Recovery");

        // ➡️ Register job in vmSettings.db
        const vmid = host;
        const job_type = "HE Recovery";
        const status = "Running";
        const logs_path = eventLog;

        await new Promise((resolve, reject) => {
          vmSettingsDb.run(
            `
            INSERT INTO table_jobid (job_type, vm_id, timestamp, status, logs_path)
            VALUES (?, ?, ?, ?, ?)
            `,
            [job_type, vmid, timestamp, status, logs_path],
            function (dbErr) {
              if (dbErr) {
                console.error("Failed to insert job into vmSettings.db:", dbErr);
                reject(dbErr);
              } else {
                logMessage(traceLog, `[INFO] Registered Job ID for ${host}`);
                logMessage(eventLog, `[INFO] Registered Job ID for ${host}`);
                resolve();
              }
            }
          );
        });

        // Copy selected files
        if (selected_files.includes("answers") || selected_files.includes("hosted-engine")) {
          const answerFolder = path.dirname(backup.answers_conf_path);
          const dest = `${targetRecoveryBase}/answer/`;
          await fse.ensureDir(dest);
          await fse.copy(answerFolder, dest);
          logMessage(traceLog, "[COPY] answers.conf and hosted-engine.conf copied");
        }

        if (selected_files.includes("ova") && backup.ova_file) {
          const ovaFolder = path.dirname(backup.ova_file);
          const dest = `${targetRecoveryBase}/ova/`;
          await fse.ensureDir(dest);
          await fse.copy(ovaFolder, dest);
          logMessage(traceLog, "[COPY] OVA copied");
        }

        if (selected_files.includes("engine-db") && backup.engine_backup_file && await fse.pathExists(backup.engine_backup_file)) {
          await fse.copy(backup.engine_backup_file, `${timestampFolder}/${path.basename(backup.engine_backup_file)}`);
          logMessage(traceLog, "[COPY] Engine DB copied");
        }

        if (selected_files.includes("dom_md") && backup.dom_md_path && await fse.pathExists(backup.dom_md_path)) {
          const dest = `${timestampFolder}/dom_md/`;
          await fse.ensureDir(dest);
          await fse.copy(backup.dom_md_path, dest);
          logMessage(traceLog, "[COPY] dom_md directory copied");
        }

        // 🏁 Job Complete — Update status to "Completed"
        await new Promise((resolve, reject) => {
          vmSettingsDb.run(
            `UPDATE table_jobid SET status = 'Completed' WHERE vm_id = ? AND job_type = ? AND timestamp = ?`,
            [vmid, job_type, timestamp],
            function (updateErr) {
              if (updateErr) {
                console.error("Failed to update job status:", updateErr);
                reject(updateErr);
              } else {
                logMessage(traceLog, `[SUCCESS] Hosted Engine Recovery completed`);
                logMessage(eventLog, `[SUCCESS] Hosted Engine Recovery completed`);
                resolve();
              }
            }
          );
        });

        return res.json({ success: true, message: "Selected recovery files prepared successfully." });
      } catch (copyErr) {
        console.error("Recovery copying error:", copyErr);
        logMessage(traceLog, "[ERROR] Recovery failed: " + copyErr.message);
        logMessage(eventLog, "[ERROR] Recovery failed: " + copyErr.message);
        return res.status(500).json({ success: false, message: "Failed to prepare recovery." });
      }
    }
  );
});


app.get("/he_recovery/hosts", (req, res) => {
  vmSettingsDb.all(
    `SELECT 'Source' AS type, host_ip AS host FROM Source WHERE he_protection_enabled = 1
     UNION
     SELECT 'Target' AS type, host_ip AS host FROM Target WHERE he_protection_enabled = 1;`,
    (err, rows) => {
      if (err) {
        console.error("Failed to fetch HE hosts:", err.message);
        res.status(500).json({ success: false, message: "Failed to fetch HE hosts." });
      } else {
        res.json({ success: true, data: rows });
      }
    }
  );
});

router.get("/he_recovery/log/:host/:timestamp", async (req, res) => {
  const { host, timestamp } = req.params;
  const logFilePath = `/kvmdr/log/${host}_HE_recovery/events_${timestamp}.log`;

  try {
    if (await fse.pathExists(logFilePath)) {
      const logContent = await fse.readFile(logFilePath, "utf8");
      return res.send(logContent);
    } else {
      return res.status(404).send("Log file not found.");
    }
  } catch (error) {
    console.error("Error reading HE recovery log:", error);
    return res.status(500).send("Internal Server Error");
  }
});

// GET backup times
app.get("/he-backup-times", (req, res) => {
  const db = new sqlite3.Database("/root/vmSettings.db");
  const result = { source: [], target: [] };

  db.all("SELECT host_ip, he_backup_time FROM Source", [], (err, rows) => {
    if (err) return res.json({ success: false, message: err.message });
    result.source = rows;

    db.all("SELECT host_ip, he_backup_time FROM Target", [], (err2, rows2) => {
      if (err2) return res.json({ success: false, message: err2.message });
      result.target = rows2;
      return res.json({ success: true, data: result });
    });
  });
});

// POST to update backup time
// Update HE Backup Time
router.post("/he-backup-time", (req, res) => {
  const { host_ip, backup_time } = req.body;

  if (!host_ip || !backup_time) {
    return res.status(400).json({ success: false, message: "Missing host_ip or backup_time" });
  }

  const db = new sqlite3.Database(vmSettingsDbPath);
  const updateQuery = `
    UPDATE Source SET he_backup_time = ?
    WHERE host_ip = ?
    UNION
    SELECT he_backup_time FROM Target WHERE host_ip = ?
  `;

  // First try updating Source
  db.run("UPDATE Source SET he_backup_time = ? WHERE host_ip = ?", [backup_time, host_ip], function (err) {
    if (err) {
      console.error("DB update error (Source):", err.message);
      return res.status(500).json({ success: false, message: "Database error" });
    }

    // If no rows were updated in Source, try Target
    if (this.changes === 0) {
      db.run("UPDATE Target SET he_backup_time = ? WHERE host_ip = ?", [backup_time, host_ip], function (err2) {
        db.close();
        if (err2) {
          console.error("DB update error (Target):", err2.message);
          return res.status(500).json({ success: false, message: "Database error" });
        }
        return res.json({ success: true, message: "Backup time updated (Target)" });
      });
    } else {
      db.close();
      return res.json({ success: true, message: "Backup time updated (Source)" });
    }
  });
});


//Replication Active Card
app.get("/replication/active", (req, res) => {
  const query = `
    SELECT vmid, vm_name, source_host, target_host,
           last_synced_date, last_synced_time, rpo, status
    FROM active_replications
    WHERE status LIKE 'Active:%'
    ORDER BY last_synced_date DESC, last_synced_time DESC
  `;

  vmSettingsDb.all(query, [], (err, rows) => {
    if (err) {
      console.error("Error fetching active replication data:", err.message);
      return res.status(500).json({ success: false, message: "Failed to fetch data" });
    }

    res.json({ success: true, data: rows });
  });
});

