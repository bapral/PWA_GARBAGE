import json
import os

ROUTE_FILE = 'assets/taichung_route.json'
MASTER_MAP = 'taichung_master_map.json'

def build_master():
    print(f"--- 正在分析 {ROUTE_FILE} 狀態 ---")
    with open(ROUTE_FILE, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    master_map = {}
    precise_count = 0
    fallback_count = 0
    
    for item in data:
        addr = f"台中市{item.get('area', '')}{item.get('village', '')}{item.get('caption', '')}"
        
        # 判斷是否已經具備精準座標 (檢查標記)
        is_precise = item.get('coord_source') == 'arcgis_precise'
        
        if addr not in master_map:
            if is_precise:
                master_map[addr] = {"lat": float(item['Y']), "lon": float(item['X']), "status": "done"}
                precise_count += 1
            else:
                master_map[addr] = {"lat": None, "lon": None, "status": "pending"}
                fallback_count += 1
    
    with open(MASTER_MAP, 'w', encoding='utf-8') as f:
        json.dump(master_map, f, ensure_ascii=False, indent=2)
    
    print(f"✅ Master Map 已建立：")
    print(f"   - 總獨特地址數: {len(master_map)}")
    print(f"   - 現有精準筆數: {precise_count}")
    print(f"   - 待處理筆數: {fallback_count}")

if __name__ == "__main__":
    build_master()
