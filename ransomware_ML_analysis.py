import sqlite3
import pandas as pd
import logging
from sklearn.ensemble import IsolationForest
import numpy as np
from datetime import datetime

# Set up logging
logging.basicConfig(level=logging.INFO)

# Function to create the table if it doesn't exist
def create_table_if_not_exists():
    db_path = '/root/aspar.db'
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    create_table_query = """
    CREATE TABLE IF NOT EXISTS ransomware_analysis_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        vmid TEXT,
        timestamp TEXT,
        anomaly_raw_data TEXT,
        anomaly_percentage REAL
    );
    """
    cursor.execute(create_table_query)
    conn.commit()
    conn.close()

# Function to fetch entropy data from the database
def fetch_entropy_data(vmid):
    db_path = '/root/aspar.db'
    query = f"""
        SELECT timestamp, entropy_score, mean_block_size, variance, std_deviation,
               zeroed_block_ratio, dirty_block_ratio, shannon_entropy
        FROM entropy_scores_{vmid.replace('-', '')}  -- Removing hyphens for sanitized VM ID
        ORDER BY timestamp;
    """
    conn = sqlite3.connect(db_path)
    data = pd.read_sql_query(query, conn)
    conn.close()
    return data

# Function to run Isolation Forest on the data
def run_isolation_forest(data):
    model = IsolationForest(n_estimators=100, contamination=0.05)
    predictions = model.fit_predict(data)
    
    # Calculate anomaly percentage
    anomaly_percentage = np.mean(predictions == -1)
    
    # Store raw anomaly data (1 = normal, -1 = anomaly)
    anomaly_raw_data = predictions.tolist()
    
    return anomaly_raw_data, anomaly_percentage

# Function to insert the results into the database
def insert_analysis_results(vmid, timestamp, anomaly_raw_data, anomaly_percentage):
    db_path = '/root/aspar.db'
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Create an insert query with the results
    insert_query = """
    INSERT INTO ransomware_analysis_results (vmid, timestamp, anomaly_raw_data, anomaly_percentage)
    VALUES (?, ?, ?, ?)
    """
    
    # Prepare anomaly data as a string of raw results
    anomaly_raw_data_str = ', '.join(map(str, anomaly_raw_data))
    
    cursor.execute(insert_query, (vmid, timestamp, anomaly_raw_data_str, anomaly_percentage))
    conn.commit()
    conn.close()

# Main function to run the analysis
def run_ransomware_analysis(vmid):
    logging.info(f"Running ransomware analysis for VM ID: {vmid}")
    
    # Fetch the data from the database
    data = fetch_entropy_data(vmid)
    logging.info(f"Data fetched for VMID: {vmid}, Rows: {len(data)}")

    # Drop the 'timestamp' column for model processing
    model_data = data.drop(columns=['timestamp'])
    
    # Run the Isolation Forest model
    logging.info("Running Isolation Forest model...")
    anomaly_raw_data, anomaly_percentage = run_isolation_forest(model_data)
    
    # Current timestamp
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    # Insert results into the database
    insert_analysis_results(vmid, timestamp, anomaly_raw_data, anomaly_percentage)
    
    logging.info(f"Anomaly detection completed. Anomaly percentage: {anomaly_percentage:.2f}")
    logging.info(f"Data inserted into ransomware_analysis_results table.")

# Example usage
if __name__ == "__main__":
    create_table_if_not_exists()  # Ensure the table exists
    vmid_input = "c05c2a4a-aa00-44ed-a92e-8a68869543a0"  # Replace with the VM ID input
    run_ransomware_analysis(vmid_input)
