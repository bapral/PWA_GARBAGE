import json

MASTER_MAP = 'taichung_master_map.json'
ROUTE_FILE = 'assets/taichung_route.json'

def finalize():
    print(f"--- 啟動 SOP 原子化回填 ---")
    
    # 1. 載入資料
    with open(MASTER_MAP, 'r', encoding='utf-8') as f:
        master_map = json.load(f)
    with open(ROUTE_FILE, 'r', encoding='utf-8') as f:
        route_data = json.load(f)
    
    initial_count = len(route_data)
    updated_to_precise = 0
    
    # 2. 執行回填
    for item in route_data:
        addr = f"台中市{item.get('area', '')}{item.get('village', '')}{item.get('caption', '')}"
        
        if addr in master_map and master_map[addr]['status'] == 'done':
            item['X'] = str(master_map[addr]['lon'])
            item['Y'] = str(master_map[addr]['lat'])
            item['coord_source'] = 'arcgis_precise'
            updated_to_precise += 1

    # 3. 儲存
    with open(ROUTE_FILE, 'w', encoding='utf-8') as f:
        json.dump(route_data, f, ensure_ascii=False, indent=2)
    
    # 4. 三重驗證
    print(f"✅ 回填結果：")
    print(f"   - 總筆數檢查: {len(route_data)} (預期 {initial_count})")
    print(f"   - 標記為精準座標的總筆數: {updated_to_precise}")
    
    # 抽查
    sample_idx = 1500 # 抽查中間的一筆
    if sample_idx < initial_count:
        sample = route_data[sample_idx]
        print(f"   - 抽查驗證 [{sample_idx}]: {sample.get('caption')} -> Source: {sample.get('coord_source')}")

if __name__ == "__main__":
    finalize()
