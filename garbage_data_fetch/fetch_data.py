import requests
import os
import json
import urllib3
import time

# 停用 SSL 警告
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def fetch_taipei(data_dir):
    print("正在下載 Taipei 的完整資料 (分頁處理)...")
    base_url = "https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire"
    limit = 1000
    offset = 0
    all_results = []
    
    while True:
        url = f"{base_url}&limit={limit}&offset={offset}"
        try:
            response = requests.get(url, timeout=30, verify=False)
            if response.status_code == 200:
                data = response.json()
                results = data.get("result", {}).get("results", [])
                all_results.extend(results)
                
                count = data.get("result", {}).get("count", 0)
                print(f"已下載 {len(all_results)} / {count} 筆資料...")
                
                if len(results) < limit or len(all_results) >= count:
                    break
                offset += limit
                time.sleep(1) # 避免請求過快
            else:
                print(f"下載 Taipei 資料失敗，狀態碼: {response.status_code}")
                break
        except Exception as e:
            print(f"處理 Taipei 時發生錯誤: {e}")
            break
            
    if all_results:
        filepath = os.path.join(data_dir, "taipei_route_new.json")
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(all_results, f, ensure_ascii=False, indent=2)
        print(f"成功儲存 Taipei 完整資料到 {filepath}")

def fetch_other_cities(data_dir):
    apis = {
        "ntpc": {
            "url": "https://data.ntpc.gov.tw/api/datasets/edc3ad26-8ae7-4916-a00b-bc6048d19bf8/csv?size=100000",
            "filename": "ntpc_route_new.csv",
            "headers": {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
                'Referer': 'https://data.ntpc.gov.tw/',
                'Accept': 'text/csv, application/json'
            }
        },
        "taichung": {
            "url": "https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=68d1a87f-7baa-4b50-8408-c36a3a7eda68",
            "filename": "taichung_route_new.csv",
            "headers": {}
        },
        "tainan": {
            "url": "https://soa.tainan.gov.tw/Api/Service/Get/84df8cd6-8741-41ed-919c-5105a28ecd6d",
            "filename": "tainan_route_new.json",
            "headers": {}
        },
        "kaohsiung": {
            "url": "https://api.kcg.gov.tw/api/service/Get/b1044aa2-e994-49f8-9731-df935d512893",
            "filename": "kaohsiung_route_new.json",
            "headers": {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36'
            }
        }
    }

    for city, config in apis.items():
        print(f"正在下載 {city} 的最新資料...")
        try:
            response = requests.get(config["url"], headers=config["headers"], timeout=60, verify=False)
            if response.status_code == 200:
                filepath = os.path.join(data_dir, config["filename"])
                with open(filepath, "wb") as f:
                    f.write(response.content)
                print(f"成功儲存 {city} 資料到 {filepath}")
                
                if os.path.getsize(filepath) < 5000:
                    print(f"警告: {city} 資料大小僅 {os.path.getsize(filepath)} bytes，可能抓取不完整。")
            else:
                print(f"下載 {city} 資料失敗，狀態碼: {response.status_code}")
        except Exception as e:
            print(f"處理 {city} 時發生錯誤: {e}")

def main():
    data_dir = "garbage_data_fetch"
    if not os.path.exists(data_dir):
        os.makedirs(data_dir)
    
    fetch_taipei(data_dir)
    fetch_other_cities(data_dir)

if __name__ == "__main__":
    main()
