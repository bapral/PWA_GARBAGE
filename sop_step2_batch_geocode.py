import json
import time
import re
import concurrent.futures
import datetime
from geopy.geocoders import ArcGIS

MASTER_MAP = 'taichung_master_map.json'
LOG_FILE = 'geocoding_sop.log'
MAX_WORKERS = 5
BATCH_SIZE = 2000 # 本次只跑 2000 筆

def log_msg(msg):
    t = datetime.datetime.now().strftime("%H:%M:%S")
    s = f"[{t}] {msg}"
    print(s)
    with open(LOG_FILE, 'a', encoding='utf-8') as f:
        f.write(s + "\n")

def clean_addr(addr):
    addr = re.sub(r'\(.*?\)|（.*?）|\d{2}:\d{2}.*', '', addr)
    return addr.strip()

def geocode_worker(addr):
    cleaned = clean_addr(addr)
    try:
        geolocator = ArcGIS()
        loc = geolocator.geocode(cleaned, timeout=10)
        if loc:
            return addr, loc.latitude, loc.longitude, "done"
        return addr, None, None, "failed"
    except:
        return addr, None, None, "error"

def main():
    with open(MASTER_MAP, 'r', encoding='utf-8') as f:
        master_map = json.load(f)

    pending = [a for a, v in master_map.items() if v['status'] == 'pending'][:BATCH_SIZE]
    if not pending:
        print("所有地址皆已處理完畢！")
        return

    log_msg(f"--- 啟動 SOP 批次轉檔 ({len(pending)} 筆) ---")
    
    completed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(geocode_worker, addr): addr for addr in pending}
        
        for future in concurrent.futures.as_completed(futures):
            addr, lat, lon, status = future.result()
            if status == "done":
                master_map[addr] = {"lat": lat, "lon": lon, "status": "done"}
            else:
                master_map[addr]["status"] = status
            
            completed += 1
            if completed % 100 == 0:
                with open(MASTER_MAP, 'w', encoding='utf-8') as f:
                    json.dump(master_map, f, ensure_ascii=False, indent=2)
                log_msg(f"進度: {completed}/{len(pending)} ({(completed/len(pending))*100:.1f}%)")

    with open(MASTER_MAP, 'w', encoding='utf-8') as f:
        json.dump(master_map, f, ensure_ascii=False, indent=2)
    log_msg(f"🏁 批次結束。已更新 Master Map。")

if __name__ == "__main__":
    main()
