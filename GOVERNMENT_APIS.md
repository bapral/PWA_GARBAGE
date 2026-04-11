# 台灣垃圾車政府 API 整合文件 (API Reference)

本文件匯整了目前專案中所對接的各縣市政府開放資料接口，提供維護者參考其參數設定與回傳結構。

---

## 1. 台北市 (Taipei City)
*   **班表資料**: `https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire`
*   **即時動態**: (同上，包含緯度/經度欄位)
*   **關鍵參數**: `limit=20000` (必須設定，否則僅回傳 20 筆)
*   **資料特性**: 支援關鍵字搜尋 (`q=`)，目前應用於 PWA 分區輪詢。

## 2. 新北市 (New Taipei City)
*   **即時動態 (JSON)**: `https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/json`
*   **路線班表 (CSV)**: `https://data.ntpc.gov.tw/api/datasets/edc3ad26-8ae7-4916-a00b-bc6048d19bf8/csv`
*   **必要條件**: 標頭必須包含 `User-Agent` 與 `Referer`。

## 3. 台中市 (Taichung City)
*   **班表資料 (rid=68d1)**: `https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=68d1a87f-7baa-4b50-8408-c36a3a7eda68`
*   **即時動態 (rid=c923)**: `https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc`
*   **資料特性**: 即時資料使用 `X` 代表經度，`Y` 代表緯度。

## 4. 台南市 (Tainan City)
*   **即時動態**: `https://soa.tainan.gov.tw/Api/Service/Get/2c8a70d5-06f2-4353-9e92-c40d33bcd969`
*   **班表資料**: `https://soa.tainan.gov.tw/Api/Service/Get/84df8cd6-8741-41ed-919c-5105a28ecd6d`
*   **資料特性**: 需手動處理 UTF-8 解碼。

## 5. 高雄市 (Kaohsiung City)
*   **官方主 API**: `https://api.kcg.gov.tw/api/service/get/7c80a17b-ba6c-4a07-811e-feae30ff9210`
*   **官方備援**: `https://api.kcg.gov.tw/ServiceList/GetFullList/074c805a-00e1-4fc5-b5f8-b2f4d6b64aa4`
*   **即時位置**: `https://api.kcg.gov.tw/api/service/get/be19a02a-954f-4828-84a1-97ca035bc383`
*   **資料特性**: 座標格式高度不穩定，需容錯處理合併字串與獨立欄位。

---

## 通用技術說明
*   **超時設定**: 建議 15-30 秒。
*   **頻率限制**: 請遵守政府開放平台規範，單一 IP 建議更新頻率不低於 30 秒/次。
*   **CORS Proxy**: Web 端優先使用 `webFetch` 工具函式進行自動代理切換。
