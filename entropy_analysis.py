import sqlite3
import pandas as pd
import numpy as np
import subprocess
import os
import shutil
from tabulate import tabulate
from decimal import Decimal, getcontext, ROUND_HALF_UP
import datetime
import sys
import requests
from requests.auth import HTTPBasicAuth
import xml.etree.ElementTree as ET


getcontext().prec = 30  # Higher precision for large numbers

def get_metrics_from_ovirt(vm_id):
    engine_url = "https://engine.local/ovirt-engine"
    api_url = f"{engine_url}/api"
    sso_url = f"{engine_url}/sso/oauth/token"
    username = "admin@ovirt@internalsso"
    password = "ravi001"

    # Step 1: Get SSO token
    try:
        token_resp = requests.post(
            sso_url,
            headers={"Accept": "application/json"},
            data={
                "grant_type": "password",
                "username": username,
                "password": password,
                "scope": "ovirt-app-api"
            },
            verify=False
        )
        if token_resp.status_code != 200:
            print(f"[ERROR] Token fetch failed: {token_resp.status_code}")
            return 0.0, 0, 0
        access_token = token_resp.json().get("access_token")
    except Exception as e:
        print(f"[ERROR] Token request failed: {e}")
        return 0.0, 0, 0

    # Step 2: Query VM statistics using the token
    try:
        response = requests.get(
            f"{api_url}/vms/{vm_id}/statistics",
            headers={
                "Authorization": f"Bearer {access_token}",
                "Accept": "application/xml"
            },
            verify=False
        )
        if response.status_code != 200:
            print(f"[ERROR] Failed to fetch stats: {response.status_code}")
            return 0.0, 0, 0

        root = ET.fromstring(response.content)
        stats = {}
        for stat in root.findall("statistic"):
            name = stat.find("name").text
            datum = stat.find("values/value/datum")
            value = datum.text if datum is not None else None
            if value is not None:
                stats[name] = value

        cpu = float(stats.get("cpu.current.total", 0))
        mem_free = int(stats.get("memory.free", 0))
        swap_used = int(stats.get("memory.used", 0))  # approximate

        return cpu, mem_free, swap_used

    except Exception as e:
        print(f"[ERROR] oVirt API stats failed: {e}")
        return 0.0, 0, 0


##############################
# 0) SYSTEM METRICS COLLECTOR
##############################

def get_sys_metrics(vm_id_input):
    try:
        cpu_usage, mem_free_kb, mem_used_kb = get_metrics_from_ovirt(vm_id_input)
    except Exception as e:
        print(f"[ERROR] Failed to get system metrics from oVirt: {e}")
        cpu_usage = 0.0
        mem_free_kb = 0
        mem_used_kb = 0

    return cpu_usage, mem_free_kb, mem_used_kb



##############################
# 1) HELPER: GET RAW PATHS
##############################
def get_backup_paths(vm_id_input):
    """
    Fetch the 'Backup_path' from table_BI_{vm_id_input} 
    where Full_Backup=25 and Checkpoint IS NOT NULL.
    Returns a comma-separated string of .raw paths.
    """
    sanitized_vm_id = vm_id_input.replace('-', '')
    table_name = f"table_BI_{sanitized_vm_id}"

    conn = sqlite3.connect('/root/Backup_Index.db')
    cursor = conn.cursor()
    paths_str = None
    try:
        cursor.execute(f"""
            SELECT Backup_path FROM {table_name}
            WHERE Full_Backup=25
              AND Checkpoint IS NOT NULL
            ORDER BY Date DESC, Time DESC
            LIMIT 1
        """)
        row = cursor.fetchone()
        if row:
            paths_str = row[0]
    except Exception as e:
        print(f"[ERROR] get_backup_paths: {e}")
    finally:
        conn.close()

    return paths_str

##############################
# 2) FILE COPY & LIST
##############################
def copy_and_list_files(paths_str):
    """
    Splits comma-separated .raw paths, copies them to /backup/tmp,
    returns the list of copied file paths.
    """
    if not paths_str:
        print("[WARNING] No .raw path string.")
        return []

    raw_paths = [p.strip() for p in paths_str.split(',')]
    
    print("[INFO] The following .raw files will be copied into /backup/tmp/:")
    for path in raw_paths:
        print(f"   {path}")

    copied_files = []
    for src in raw_paths:
        if not os.path.isfile(src):
            print(f"[WARNING] Source file not found: {src}")
            continue
        dst = os.path.join("/backup/tmp", os.path.basename(src))
        try:
            shutil.copy2(src, dst)
            print(f"[INFO] Copied {src} -> {dst}")
            copied_files.append(dst)
        except Exception as e:
            print(f"[ERROR] Copy failed: {src}: {e}")

    print("\n[INFO] /backup/tmp/ contents:\n")
    try:
        subprocess.run(["ls", "-lh", "/backup/tmp"], check=True)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] listing /backup/tmp: {e}")

    return copied_files

##############################
# 3) LENGTH-BASED ANALYSIS
##############################
def calculate_entropy(values):
    prob = pd.Series(values).value_counts(normalize=True)
    return -np.sum(prob * np.log2(prob))

def process_data(df):
    df['Dirty'] = df['Dirty'].astype(str).str.lower().map({'true': True, 'false': False})
    df['Zero'] = df['Zero'].astype(str).str.lower().map({'true': True, 'false': False})
    df['Length'] = pd.to_numeric(df['Length'], errors='coerce')
    df['Start'] = pd.to_numeric(df['Start'], errors='coerce')
    df.dropna(subset=['Length','Start'], inplace=True)

    total_size = df["Length"].sum() or 0
    mean_block_size = df["Length"].mean() or 0
    variance = df["Length"].var() or 0
    std_deviation = df["Length"].std() or 0
    zeroed_block_ratio = 0.0
    dirty_block_ratio = 0.0
    if total_size>0:
        zeroed_block_ratio = df[df["Zero"]]["Length"].sum()/total_size
        dirty_block_ratio = df[df["Dirty"]]["Length"].sum()/total_size

    length_entropy = 0.0
    if not df.empty:
        length_entropy = calculate_entropy(df["Length"])

    return (
        length_entropy,     # 0
        mean_block_size,    # 1
        variance,           # 2
        std_deviation,      # 3
        zeroed_block_ratio, # 4
        dirty_block_ratio   # 5
    )


def weighted_entropy_score(shannon_entropy_length, mean_block_size, variance,
                           std_deviation, zeroed_block_ratio, dirty_block_ratio,
                           cpu_usage, mem_free_kb, mem_used_kb):
    # Updated weights
    w_dirty_block_ratio   = 0.85
    w_shannon_entropy     = 0.05
    w_zeroed_block_ratio  = 0.03
    w_variance            = 0.02
    w_std_deviation       = 0.02
    w_mean_block_size     = 0.01
    w_cpu_usage           = 0.01
    w_swap_used           = 0.005
    w_mem_free_inverse    = 0.005

    # Normalized inputs
    normalized_shannon = shannon_entropy_length / 8 if shannon_entropy_length > 0 else 0
    normalized_mbsize   = 1.0
    normalized_var      = 1.0
    normalized_std      = 1.0
    normalized_cpu      = cpu_usage / 100.0 if cpu_usage > 0 else 0
    normalized_swap     = min(mem_used_kb / 1024**2, 1.0)  # scale to <=1 if <1GB
    normalized_mem      = 1.0 - min(mem_free_kb / (8 * 1024 * 1024), 1.0)  # inverse of free mem if total ~8GB

    # Final score
    score = round(
        (w_dirty_block_ratio * dirty_block_ratio) +
        (w_shannon_entropy * normalized_shannon) +
        (w_zeroed_block_ratio * zeroed_block_ratio) +
        (w_variance * normalized_var) +
        (w_std_deviation * normalized_std) +
        (w_mean_block_size * normalized_mbsize) +
        (w_cpu_usage * normalized_cpu) +
        (w_swap_used * normalized_swap) +
        (w_mem_free_inverse * normalized_mem),
        5
    )
    return score



##############################
# 4) R COMPARISON
##############################
def run_r_script(input_file):
    try:
        output = subprocess.check_output(["Rscript","/root/ransomware_analysis.R",input_file], universal_newlines=True)
        return output
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] R script: {e}")
        return None

def calculate_average(val1, val2):
    from decimal import Decimal, ROUND_HALF_UP
    try:
        d1 = Decimal(str(val1))
        d2 = Decimal(str(val2))
        avg = (d1 + d2)/2
        if avg<1:
            return float(avg.quantize(Decimal('0.00000'), rounding=ROUND_HALF_UP))
        elif avg<1e5:
            return float(avg.quantize(Decimal('1.00000'), rounding=ROUND_HALF_UP))
        else:
            return float(avg)
    except Exception as e:
        print(f"[ERROR] Average Calculation: {e}")
        return 0.0

##############################
# 5) DB STORAGE
##############################
def create_table_and_update_db(vm_id_input,
                               entropy_score, 
                               mean_block_size,
                               variance,
                               std_deviation,
                               zeroed_block_ratio,
                               dirty_block_ratio,
                               shannon_entropy,
                               delta_entropy,
                               byte_entropy,
                               chi_square,
                               cpu_usage,
                               mem_free_kb,
                               mem_used_kb):
    """
    Single table for everything. 
    We'll add new columns (delta_entropy, byte_entropy, chi_square) 
    to the existing 'entropy_scores_{vm_id_input}' table.
    """
    try:
        db_path = "/root/aspar.db"
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        table_name = f"entropy_scores_{vm_id_input}"
        # We'll assume you already did:
        # ALTER TABLE <vm_id_input> ADD COLUMN delta_entropy REAL, etc.
        # But let's do CREATE with all columns. If they exist, great.
        cursor.execute(f'''
            CREATE TABLE IF NOT EXISTS {table_name} (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                vm_id_input TEXT,
                timestamp TEXT,
                entropy_score REAL,
                mean_block_size REAL,
                variance REAL,
                std_deviation REAL,
                zeroed_block_ratio REAL,
                dirty_block_ratio REAL,
                shannon_entropy REAL,
                delta_entropy REAL,
                byte_entropy REAL,
                chi_square REAL,
                cpu_usage REAL,
                mem_free_kb INTEGER,
                mem_used_kb INTEGER
            )
        ''')

        timestamp = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        # Insert all columns
        cursor.execute(f'''
            INSERT INTO {table_name} (
                vm_id_input,
                timestamp,
                entropy_score,
                mean_block_size,
                variance,
                std_deviation,
                zeroed_block_ratio,
                dirty_block_ratio,
                shannon_entropy,
                delta_entropy,
                byte_entropy,
                chi_square,
                cpu_usage, 
                mem_free_kb, 
                mem_used_kb
            )
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ''', (
            vm_id_input,
            timestamp,
            entropy_score,
            mean_block_size,
            variance,
            std_deviation,
            zeroed_block_ratio,
            dirty_block_ratio,
            shannon_entropy,
            delta_entropy,
            byte_entropy,
            chi_square,
            cpu_usage,
            mem_free_kb,
           mem_used_kb
        ))
        conn.commit()
        conn.close()

        print(f"[INFO] Inserted row into {table_name}, including delta_entropy, byte_entropy, chi_square.")
    except Exception as e:
        print(f"[ERROR] create_table_and_update_db: {e}")

##############################
# 6) MAIN
##############################
def main(vm_id_input):
    sanitized_vm_id = vm_id_input.replace('-', '')
    incremental_table = f"incremental_{sanitized_vm_id}"

    # 1) fetch block-level data for length-based analysis
    try:
        conn = sqlite3.connect('/root/Backup_Index.db')
        df = pd.read_sql(f"""
            SELECT Start,Length,Dirty,Zero,Date,Time
            FROM "{incremental_table}"
            WHERE Checkpoint IS NOT NULL
        """, conn)
        conn.close()
    except Exception as e:
        print(f"[ERROR] reading incremental data: {e}")
        return

    # 2) Process length-based
    length_metrics = process_data(df)  # (len_entropy, mean_bs, var, std_dev, zero_ratio, dirty_ratio)
    length_entropy = length_metrics[0]
    cpu_usage, mem_free_kb, mem_used_kb = get_sys_metrics(vm_id_input)
   
    print("\n[INFO] oVirt VM Metrics:")
    print(f"  CPU Usage         : {cpu_usage} %")
    print(f"  Free Memory       : {mem_free_kb} KB")
    print(f"  Approx. Memory Used : {mem_used_kb} KB\n") 

    py_entropy_score = weighted_entropy_score(
        *length_metrics,
         cpu_usage,
         mem_free_kb,
         mem_used_kb
    )    



    # 3) Export for R
    r_file = f"/tmp/data_{sanitized_vm_id}.txt"
    df.to_csv(r_file, index=False, header=False)

    # 4) R script
    r_output = run_r_script(r_file)
    r_metrics = {}
    if r_output:
        for line in r_output.split('\n'):
            if ":" in line:
                parts=line.split(':',1)
                if len(parts)==2:
                    key,val=parts
                    key=key.strip()
                    val=val.strip()
                    try:
                        r_metrics[key]=float(val)
                    except:
                        pass

    # 5) show table comparing Python vs. R
    def safe_div(n,d): return n/d if d else 0
    table = [
        ["Metric","Python Output","R Output","% Difference","Average (P+R)/2"],
        [
            "Shannon Entropy (Length)",
            round(length_metrics[0],5),
            r_metrics.get("Shannon Entropy (Length)",0),
            round(safe_div(abs(length_metrics[0]-r_metrics.get("Shannon Entropy (Length)",0)),length_metrics[0])*100,5) if length_metrics[0] else 0,
            calculate_average(length_metrics[0],r_metrics.get("Shannon Entropy (Length)",0))
        ],
        [
            "Mean Block Size",
            "{:.5e}".format(length_metrics[1]),
            "{:.5e}".format(r_metrics.get("Mean Block Size",0)),
            round(safe_div(abs(length_metrics[1]-r_metrics.get("Mean Block Size",0)),length_metrics[1])*100,5) if length_metrics[1] else 0,
            "{:.5e}".format(calculate_average(length_metrics[1],r_metrics.get("Mean Block Size",0)))
        ],
        [
            "Variance",
            "{:.5e}".format(length_metrics[2]),
            "{:.5e}".format(r_metrics.get("Variance",0)),
            round(safe_div(abs(length_metrics[2]-r_metrics.get("Variance",0)),length_metrics[2])*100,5) if length_metrics[2] else 0,
            "{:.5e}".format(calculate_average(length_metrics[2],r_metrics.get("Variance",0)))
        ],
        [
            "Standard Deviation",
            round(length_metrics[3],5),
            r_metrics.get("Standard Deviation",0),
            round(safe_div(abs(length_metrics[3]-r_metrics.get("Standard Deviation",0)),length_metrics[3])*100,5) if length_metrics[3] else 0,
            calculate_average(length_metrics[3],r_metrics.get("Standard Deviation",0))
        ],
        [
            "Zeroed Block Ratio",
            round(length_metrics[4],5),
            r_metrics.get("Zeroed Block Ratio",0),
            round(safe_div(abs(length_metrics[4]-r_metrics.get("Zeroed Block Ratio",0)),length_metrics[4])*100,5) if length_metrics[4] else 0,
            calculate_average(length_metrics[4],r_metrics.get("Zeroed Block Ratio",0))
        ],
        [
            "Dirty Block Ratio",
            round(length_metrics[5],5),
            r_metrics.get("Dirty Block Ratio",0),
            round(safe_div(abs(length_metrics[5]-r_metrics.get("Dirty Block Ratio",0)),length_metrics[5])*100,5) if length_metrics[5] else 0,
            calculate_average(length_metrics[5],r_metrics.get("Dirty Block Ratio",0))
        ],
        [
            "Weighted Entropy Score",
            py_entropy_score,
            r_metrics.get("Weighted Entropy Score",0),
            round(safe_div(abs(py_entropy_score-r_metrics.get("Weighted Entropy Score",0)),py_entropy_score)*100,5) if py_entropy_score else 0,
            calculate_average(py_entropy_score, r_metrics.get("Weighted Entropy Score",0))
        ]
    ]
    print(tabulate(table, headers="firstrow", tablefmt="grid"))

    # 6) Now we store the length-based metrics in the table (no delta, byte, chi yet)
    #    We'll finalize all at the end once we get them.
    #    Actually, let's do it in the same step. So let's just keep it but pass placeholders for now.
    #    We'll do a second call with real metrics, or we can do it once at the end. 
    #    We'll do it once at the end for a single row storing everything.

    # 7) get .raw file paths
    db_paths_str = get_backup_paths(vm_id_input)
    if not db_paths_str:
        print("[WARNING] No Backup_path found -> no Byte Ent / Chi-Square.")
        # We'll store length-based in DB anyway
        
        cpu_usage, mem_free_kb, mem_used_kb = get_sys_metrics(vm_id_input)

        create_table_and_update_db(
            sanitized_vm_id,
            py_entropy_score,
            length_metrics[1],
            length_metrics[2],
            length_metrics[3],
            length_metrics[4],
            length_metrics[5],
            length_metrics[0],
            0.0,   # delta
            0.0,   # byte
            0.0,    # chi
            cpu_usage,
            mem_free_kb,
            mem_used_kb
        )
        return

    # 8) copy .raw -> /backup/tmp
    copied_files = copy_and_list_files(db_paths_str)
    if not copied_files:
        print("[INFO] No .raw files found -> no Byte Ent / Chi-Sq.")
        # store length-based anyway
        create_table_and_update_db(
            sanitized_vm_id,
            py_entropy_score,
            length_metrics[1],
            length_metrics[2],
            length_metrics[3],
            length_metrics[4],
            length_metrics[5],
            length_metrics[0],
            0.0,   # delta
            0.0,   # byte
            0.0,    # chi
            cpu_usage,
            mem_free_kb,
            mem_used_kb

        )
        return

    # 9) Merge for Byte Ent + Chi-Square
    all_bytes = bytearray()
    for cf in copied_files:
        with open(cf,'rb') as f:
            all_bytes += f.read()

    for cf in copied_files:
        try:
            os.remove(cf)
        except OSError:
            pass

    arr = np.frombuffer(all_bytes, dtype=np.uint8)
    if len(arr)==0:
        print("[INFO] .raw data empty.")
        # store length-based anyway
        create_table_and_update_db(
            sanitized_vm_id,
            py_entropy_score,
            length_metrics[1],
            length_metrics[2],
            length_metrics[3],
            length_metrics[4],
            length_metrics[5],
            length_metrics[0],
            0.0,
            0.0,
            0.0
        )
        return

    # compute byte_entropy
    freq = np.bincount(arr,minlength=256)
    probs = freq/len(arr)
    nz = probs[probs>0]
    byte_entropy = -np.sum(nz*np.log2(nz))

    # compute chi-square
    expected = len(arr)/256.0
    chi_sq = np.sum((freq-expected)**2 / expected)

    # Delta = |Byte - Length|
    delta_entropy = abs(byte_entropy - length_entropy)

    print(f"\n[INFO] Byte Entropy: {byte_entropy:.5f}, Chi-Square: {chi_sq:.5f}, Delta Entropy: {delta_entropy:.5f}\n")

    # Now store everything in the same table
    create_table_and_update_db(
        sanitized_vm_id,
        py_entropy_score,        # length-based Weighted Entropy
        length_metrics[1],       # mean_block_size
        length_metrics[2],       # variance
        length_metrics[3],       # std_deviation
        length_metrics[4],       # zeroed_block_ratio
        length_metrics[5],       # dirty_block_ratio
        length_metrics[0],       # length_entropy
        delta_entropy,           # new
        byte_entropy,            # new
        chi_sq,                   # new
        cpu_usage,
        mem_free_kb,
        mem_used_kb
    )

    print("[INFO] Done with single-table storage.\n")


##################################
# Script Entry
##################################
if __name__ == "__main__":
    if len(sys.argv)!=2:
        print("Usage: python entropy_analysis.py <VM_ID>")
        sys.exit(1)
    main(sys.argv[1])
