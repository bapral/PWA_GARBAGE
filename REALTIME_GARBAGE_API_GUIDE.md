# 垃圾車即時動態 API 實戰教學 (Dart/Flutter)

本文件專為開發者提供各縣市即時 API 的調用範例，包含處理 PWA 代理與 Isolate 解析的實作技巧。

---

## 1. 台北市：分區輪詢策略 (PWA 最佳化)

由於全量資料體積較大，在 Web 端建議分區抓取：

```dart
// 範例：抓取特定行政區的即時動態
Future<void> fetchTaipeiRealtime(String districts) async {
  // districts 如: "松山區 信義區"
  final url = "https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire&limit=2000&q=$districts";
  
  // 在 Web 端應使用專用的代理工具
  final body = await service.webFetch(client, url);
  if (body != null) {
    final data = json.decode(body);
    // 執行解析...
  }
}
```

---

## 2. 新北市：安全標頭與 Isolate 解析

處理新北市資料時，必須處理 403 錯誤與主線程效能問題：

```dart
// 新北即時動態 API (JSON 格式較小)
const String apiUrl = "https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/json";

Future<void> fetchNtpc() async {
  final res = await http.get(Uri.parse(apiUrl), headers: {
    'User-Agent': 'Mozilla/5.0...', // 模擬瀏覽器
    'Referer': 'https://data.ntpc.gov.tw/'
  });
  
  if (res.statusCode == 200) {
    // 針對大量 JSON 資料，使用 compute 交給 Isolate 解析
    final trucks = await compute(_parseJson, res.body);
  }
}
```

---

## 3. 台中市：時間格式標準化

台中市 API 回傳的 `T` 格式時間處理：

```dart
// 時間字串: 20240411T093000
DateTime parseTaichungTime(String raw) {
  if (raw.contains('T')) {
    final year = raw.substring(0, 4);
    final month = raw.substring(4, 6);
    final day = raw.substring(6, 8);
    final hour = raw.substring(9, 11);
    final min = raw.substring(11, 13);
    return DateTime.parse("$year-$month-$day $hour:$min:00");
  }
  return DateTime.now();
}
```

---

## 4. 通用開發小撇步 (Pro-Tips)

1.  **資料防抖 (Debounce)**: 不要讓使用者快速點擊刷新按鈕，設定 5 秒以上的按鈕 Cold-down。
2.  **Web 渲染器**: 在 PWA 模式下使用 `flutter build web --web-renderer html`，可以有效減少 Wasm 體積並提高低階手機瀏覽器的開啟速度。
3.  **錯誤回退**: 當 `fetchTrucks` 拋出異常時，請務必 `return findTrucksByTime()`，這能確保地圖上永遠有車（預測車），提升使用者心理安全感。
