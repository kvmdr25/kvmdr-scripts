import requests
import xml.etree.ElementTree as ET

# oVirt Engine details
ENGINE_URL = "https://engine.local/ovirt-engine"
API_URL = f"{ENGINE_URL}/api"
USERNAME = "admin@ovirt@internalsso"
PASSWORD = "ravi001"
VM_ID = "c05c2a4a-aa00-44ed-a92e-8a68869543a0"

# Disable SSL warnings (for self-signed certs)
requests.packages.urllib3.disable_warnings()

def get_sso_token():
    token_url = f"{ENGINE_URL}/sso/oauth/token"
    payload = {
        "grant_type": "password",
        "username": USERNAME,
        "password": PASSWORD,
        "scope": "ovirt-app-api"
    }
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded"
    }
    try:
        response = requests.post(token_url, data=payload, headers=headers, verify=False)
        response.raise_for_status()
        return response.json().get("access_token")
    except Exception as e:
        print(f"[ERROR] Token fetch failed: {e}")
        return None

def fetch_vm_statistics(token, vm_id):
    url = f"{API_URL}/vms/{vm_id}/statistics"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/xml"
    }
    response = requests.get(url, headers=headers, verify=False)
    if response.status_code != 200:
        print(f"[ERROR] Failed to fetch stats: {response.status_code}")
        return None
    return response.content

def parse_statistics(xml_data):
    root = ET.fromstring(xml_data)
    print("\nVM STATISTICS:\n" + "-"*40)
    for stat in root.findall("statistic"):
        name_elem = stat.find("name")
        datum_elem = stat.find("values/value/datum")

        name = name_elem.text if name_elem is not None else "Unnamed"
        value = datum_elem.text if datum_elem is not None else "N/A"

        print(f"{name}: {value}")

def main():
    token = get_sso_token()
    if not token:
        return
    stats_xml = fetch_vm_statistics(token, VM_ID)
    if stats_xml:
        parse_statistics(stats_xml)

if __name__ == "__main__":
    main()
