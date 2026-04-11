# 台灣五大直轄市即時垃圾車 API 串接教學

本教學文件整合了台北市、新北市、台中市、台南市及高雄市的垃圾車即時位置 API 資料，提供開發者快速介接。

---

## 1. 台北市 (Taipei City)

*   **API 網址**: `https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire`
*   **請求方式**: `GET`
*   **資料格式**: `JSON`
*   **分頁/數量限制**: 預設回傳筆數極少。**必須**加上 `limit=20000` 或更大值以取得全量資料。
*   **關鍵欄位**:
    *   `車號`: 垃圾車牌號碼。
    *   `緯度` / `經度`: 即時座標。
    *   `地點`: 目前清運站點名稱。
    *   `點位日期時間`: 資料更新時間 (格式: `yyyy-MM-dd HH:mm:ss`)。

### Sample Code (Dart)
```dart
Future<void> fetchTaipeiRealtime() async {
  final url = 'https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire&limit=20000';
  final response = await http.get(Uri.parse(url));
  
  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    final List results = data['result']['results'];
    print('台北市即時車輛數: ${results.length}');
    
    for (var truck in results) {
      final lat = double.tryParse(truck['緯度'].toString());
      final lon = double.tryParse(truck['經度'].toString());
      print('車號 ${truck['車號']} 目前在: $lat, $lon');
    }
  }
}
```

---

## 2. 新北市 (New Taipei City)

*   **API 網址**: `https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/csv`
*   **請求方式**: `GET`
*   **資料格式**: `CSV`
*   **特殊要求**: 
    1. 必須設定 `User-Agent` 標頭模擬瀏覽器。
    2. 建議加上 `size=20000` 獲取更多紀錄。
*   **關鍵欄位**: `car` (車號), `latitude`, `longitude`, `location`, `time`.

### Sample Code (Dart)
```dart
Future<void> fetchNtpcRealtime() async {
  final url = 'https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/csv?size=20000';
  final response = await http.get(Uri.parse(url), headers: {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36...',
    'Referer': 'https://data.ntpc.gov.tw/'
  });
  
  if (response.statusCode == 200) {
    // 推薦使用 csv 套件解析
    List<List<dynamic>> rows = const CsvToListConverter(eol: '\n').convert(response.body);
    // index 0 是標頭，資料從 index 1 開始
    print('新北市即時車輛數: ${rows.length - 1}');
  }
}
```

---

## 3. 台中市 (Taichung City)

*   **API 網址**: `https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc`
*   **請求方式**: `GET`
*   **資料格式**: `JSON`
*   **輪詢頻率**: 建議每 30 秒呼叫一次 (目前專案採用之設定)。
*   **關鍵細節**: 
    *   經緯度欄位名為大寫 `X` (經度) 與 `Y` (緯度)。
    *   時間格式為連續數字字串如 `20240411T093000`。

### Sample Code (Dart)
```dart
Future<void> fetchTaichungRealtime() async {
  final url = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc';
  final response = await http.get(Uri.parse(url));
  
  if (response.statusCode == 200) {
    final List results = json.decode(response.body);
    for (var truck in results) {
      print('車號 ${truck['car']} 位置: ${truck['Y']}, ${truck['X']}');
    }
  }
}
```

---

## 4. 台南市 (Tainan City)

*   **API 網址**: `https://soa.tainan.gov.tw/Api/Service/Get/2c8a70d5-06f2-4353-9e92-c40d33bcd969`
*   **請求方式**: `GET`
*   **資料格式**: `JSON`
*   **關鍵細節**: 需手動處理 UTF-8 解碼，否則中文會變亂碼。
*   **欄位名稱**: `car` (車號), `x` (經度), `y` (緯度)。

### Sample Code (Dart)
```dart
Future<void> fetchTainanRealtime() async {
  final url = 'https://soa.tainan.gov.tw/Api/Service/Get/2c8a70d5-06f2-4353-9e92-c40d33bcd969';
  final response = await http.get(Uri.parse(url));
  
  if (response.statusCode == 200) {
    // 解決中文亂碼關鍵：utf8.decode
    final data = json.decode(utf8.decode(response.bodyBytes));
    final List records = data['data'];
    for (var truck in records) {
      print('車號: ${truck['car']}, 座標: ${truck['y']}, ${truck['x']}');
    }
  }
}
```

---

## 5. 高雄市 (Kaohsiung City)

*   **主要 API (班表與座標)**: `https://api.kcg.gov.tw/api/service/get/7c80a17b-ba6c-4a07-811e-feae30ff9210`
*   **請求方式**: `GET`
*   **資料格式**: `JSON`
*   **關鍵細節**: 
    *   高雄市 API 經常將經緯度合併為一個字串欄位 `經緯度` (例如 `"22.6,120.3"`)。
    *   必須自行使用 `split(',')` 進行切割。

### Sample Code (Dart)
```dart
Future<void> fetchKaohsiungInfo() async {
  final url = 'https://api.kcg.gov.tw/api/service/get/7c80a17b-ba6c-4a07-811e-feae30ff9210';
  final response = await http.get(Uri.parse(url));
  
  if (response.statusCode == 200) {
    final data = json.decode(utf8.decode(response.bodyBytes));
    final List records = data['data'];
    for (var item in records) {
      final String coord = item['經緯度'] ?? '';
      if (coord.contains(',')) {
        final pts = coord.split(',');
        print('路線: ${item['清運路線名稱']}, 座標: ${pts[0]}, ${pts[1]}');
      }
    }
  }
}
```

---

## 總結開發注意事項

1.  **頻率限制**: 政府 API 雖然是開放的，但短時間內過於頻繁的請求 (例如每 1 秒一次) 可能會導致 IP 被暫時封鎖。建議設定 15-30 秒以上的更新間隔。
2.  **資料解析效能**: 新北 (CSV) 與台北 (JSON) 的回傳資料體積較大，若在手機端開發，請務必使用 `compute()` 函式將解析工作交給背景執行緒，避免 UI 凍結。
3.  **座標偏移**: 某些政府 API 回傳的座標可能是舊有的 TWD97 格式而非 WGS84（Google Maps 使用的格式），若發現位置偏移數百公尺，需進行座標轉換（本文件所述 API 目前多已採 WGS84）。
