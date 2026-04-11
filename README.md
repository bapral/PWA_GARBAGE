# 台灣垃圾車即時地圖 (Taiwan Garbage Map)

[![Flutter](https://img.shields.io/badge/Flutter-v3.22+-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Web%20%7C%20iOS%20%7C%20Android-lightgrey)](#)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

本專案是一個基於 Flutter 開發的跨平台應用程式，旨在整合台灣五大直轄市（台北、新北、台中、台南、高雄）的垃圾清運開放資料。透過即時 API 串接與本地 SQLite 班表預測，提供使用者最直觀、流暢的垃圾車位置追蹤體驗。

---

## 🌟 核心功能

*   **五都資料整合**：一鍵切換台北市、新北市、台中市、台南市及高雄市。
*   **即時 GPS 追蹤**：每 30 秒自動更新 API 資料，掌握垃圾車當前精確座標。
*   **智能路徑預測**：當 API 斷訊或處於非即時時段時，系統自動切換至「資料庫預估模式」，利用本地班表計算理論位置。
*   **多樣化搜尋模式**：
    *   **相對時間預測**：查看 30 分鐘或 1 小時後垃圾車預計出現在哪裡。
    *   **絕對時間查詢**：指定特定時間點（例如：今晚 8 點），檢索全市班表動態。
*   **定位導航輔助**：支援自動 GPS 定位與手動點擊地圖指定地點，一鍵搜尋最近的垃圾車並估算步行時間。
*   **PWA 高可用性支援**：針對 Web 平台整合多重代理伺服器（CORS Proxy），確保在瀏覽器環境也能穩定抓取政府資料。

---

## 🛠️ 技術架構

### 前端框架 (Frontend)
*   **Flutter (Dart)**: 跨平台 UI 引擎。
*   **Riverpod**: 響應式狀態管理，處理城市切換與資料流同步。
*   **Flutter Map (Leaflet/OSM)**: 輕量化地圖渲染與標記處理。

### 資料處理 (Data Layer)
*   **Sqflite (SQLite)**: 本地快取數萬筆清運站點，支援 Web (FFI-Wasm) 與 Native 雙平台。
*   **Isolate (Multi-threading)**: 針對新北、台北等巨量 JSON/CSV 資料進行背景異步解析，確保 UI 零卡頓。
*   **Http Client**: 封裝自定義 User-Agent 與代理輪詢邏輯。

---

## 📂 專案結構說明

```text
lib/
├── models/          # 資料模型 (GarbageTruck, GarbageRoutePoint, CityConfig)
├── providers/       # Riverpod 狀態管理中心
├── screens/         # 主要 UI 畫面 (MapScreen)
├── services/        # 核心服務 (API 串接、SQLite 封裝、各縣市專屬 Service)
└── utils/           # 工具類別 (時間格式標準化)
assets/              # 內建備援班表資產 (JSON/CSV)
web/                 # PWA 設定與 SQLite WASM 檔案
```

---

## 🚀 快速上手

### 環境需求
*   Flutter SDK 3.22.0 或以上版本
*   Dart SDK 3.4.0 或以上版本

### 安裝步驟
1.  **複製專案**
    ```bash
    git clone https://github.com/your-repo/pwa-garbage.git
    cd pwa-garbage
    ```
2.  **取得套件**
    ```bash
    flutter pub get
    ```
3.  **運行程式**
    *   **Native**: `flutter run -d <your-device>`
    *   **Web**: `flutter run -d chrome`

---

## 📝 開發者文件

關於各縣市 API 的詳細處理細節與資料格式轉換，請參閱：
*   [台灣五都垃圾車整合指南 (GARBAGE_DATA_GUIDE.md)](GARBAGE_DATA_GUIDE.md)
*   [政府 API 串接文件 (GOVERNMENT_APIS.md)](GOVERNMENT_APIS.md)
*   [即時動態 API 教學 (REALTIME_GARBAGE_API_GUIDE.md)](REALTIME_GARBAGE_API_GUIDE.md)

---

## 🤝 貢獻與反饋

如果您在使用過程中發現資料偏移、API 失效或有新的功能建議，歡迎提交 Issue 或 Pull Request。

*   **資料更新**：本專案班表版本 `20260411`。若政府資料更新，請協助更新 `assets/` 下的原始檔並提高 `requiredAssetVersion`。

---

## ⚖️ 授權協議

本專案採用 **MIT License** 授權。
資料來源均取自政府資料開放平臺，資料正確性以各地方環保局官網為準。
