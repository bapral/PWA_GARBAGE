# 台灣各縣市垃圾車政府 API 整合文件

本文件記錄了目前專案中使用的各縣市政府垃圾車開放資料 API，包含其功能、請求方式、資料格式及開發注意事項。

---

## 1. 台北市 (Taipei City)

*   **API 網址**: `https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire`
*   **功能**: 整合台北市垃圾車即時位置與清運站點班表。
*   **資料格式**: JSON
*   **用法備註**:
    *   `limit` 參數建議設為 `20000` 或更大，以確保獲取完整動態。
    *   **時間解析**: 抵達時間格式多變（如 "2030" 或 "20:30"），需進行標準化處理。
    *   **唯一識別**: 建議使用 `路線 + 車號` 作為複合鍵。

---

## 2. 新北市 (New Taipei City)

*   **即時動態 API**: `https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/csv`
*   **清運路線 API**: `https://data.ntpc.gov.tw/api/datasets/edc3ad26-8ae7-4916-a00b-bc6048d19bf8/csv`
*   **功能**: 提供垃圾車經緯度、車號、以及詳細的清運站點與表定時間。
*   **資料格式**: CSV
*   **安全性要求**: 
    *   必須包含 `User-Agent` 標頭（模擬瀏覽器），否則可能會被政府伺服器拒絕。
    *   範例 Header: `{'User-Agent': 'Mozilla/5.0...', 'Referer': 'https://data.ntpc.gov.tw/'}`
*   **處理技巧**: 由於 CSV 資料量龐大（數萬筆），建議使用背景執行緒 (Isolate) 解析，避免 UI 凍結。

---

## 3. 台中市 (Taichung City)

*   **即時動態 API**: `https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc`
*   **清運班表 API**: `https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=68d1a87f-7baa-4b50-8408-c36a3a7eda68`
*   **功能**: 提供垃圾車車牌、即時座標及定時定點收運位置。
*   **資料格式**: JSON
*   **用法備註**:
    *   **時間格式**: API 回傳的時間字串包含特有的 `T` 格式（如 `20240411T093000`），解析時需自行切割轉換。
    *   **班表關聯**: 本專案目前採取「本地預載 JSON 班表 + 即時 API 座標映射」的模式進行優化。

---

## 4. 台南市 (Tainan City)

*   **即時動態 API**: `https://soa.tainan.gov.tw/Api/Service/Get/2c8a70d5-06f2-4353-9e92-c40d33bcd969`
*   **清運點位 API**: `https://soa.tainan.gov.tw/Api/Service/Get/84df8cd6-8741-41ed-919c-5105a28ecd6d`
*   **功能**: 查詢台南市行政區、路線 ID、即時座標與班表順序。
*   **資料格式**: JSON (UTF-8 編碼)
*   **欄位說明**: 
    *   `LATITUDE` / `LONGITUDE`: 大寫欄位名。
    *   `ROUTEORDER`: 代表該站點在路線中的順序編號。

---

## 5. 高雄市 (Kaohsiung City)

*   **主要 API**: `https://api.kcg.gov.tw/api/service/get/7c80a17b-ba6c-4a07-811e-feae30ff9210`
*   **備援 API**: `https://api.kcg.gov.tw/ServiceList/GetFullList/074c805a-00e1-4fc5-b5f8-b2f4d6b64aa4`
*   **功能**: 高雄市清運路線、行政區、村里與停留時間。
*   **資料格式**: JSON
*   **特殊格式處理**: 
    *   **經緯度合併**: 高雄 API 經常將經緯度合併為一個字串（例如 `"22.6123,120.3012"`），需要使用 `split(',')` 進行切割。
    *   **結構變動**: 該政府平台外層包裝常更動（有時在 `data` 下，有時在 `records` 下），需實作彈性的解析邏輯。

---

## 通用開發建議與最佳實踐

1.  **快取機制 (Caching)**: 
    由於政府 API 穩定性不一，務必實作 SQLite 或本地存儲。僅在版本更新或資料庫為空時才執行大規模的 `syncDataIfNeeded` 同步。
2.  **超時處理 (Timeout)**: 
    政府伺服器響應時間可能較長，網路請求應設定至少 15-30 秒的超時時間。
3.  **座標解析**: 
    務必處理 `null` 或非數值的異常座標（`0.0` 或空字串），防止地圖組件崩潰。
4.  **備援方案**: 
    當即時 API 斷訊時，應能自動切換至「班表推估模式」，利用本地資料庫計算當前時間點應出現的車輛位置。
