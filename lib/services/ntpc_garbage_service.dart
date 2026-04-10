/// [整體程式說明]
/// 本文件定義了垃圾清運服務的基底架構以及新北市（NTPC）的具體實作。
/// [BaseGarbageService] 確立了城市服務的統一介面，支援多城市擴充。
/// [NtpcGarbageService] 則實作了新北市開放資料的 CSV 解析邏輯，
/// 包含即時動態 API、路線班表 API 以及本地 CSV 備援方案。
///
/// [執行順序說明]
/// 1. 呼叫 `syncDataIfNeeded`：比對版本後，優先從雲端 API 下載 CSV 路線資料。
/// 2. 若 API 失敗，則嘗試讀取本地目錄中的 CSV 檔案進行匯入。
/// 3. 解析過程中使用 `CsvToListConverter` 將字串轉換為 `GarbageRoutePoint` 並批次存入資料庫。
/// 4. 呼叫 `fetchTrucks`：定期從 API 獲取最新的垃圾車 GPS 座標。
/// 5. 若即時 API 暫無資料，則自動回退至 `findTrucksByTime` 進行班表推估。

import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:csv/csv.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// [BaseGarbageService] 是所有城市垃圾清運服務的基底抽象類別。
/// 
/// 定義了統一的介面，確保各城市的實作皆包含資料同步、車輛抓取、時間查詢等功能。
abstract class BaseGarbageService {
  /// 存放該城市本地資源檔案（如預載 CSV/JSON）的目錄路徑。
  final String localSourceDir; 
  
  /// 建構子：初始化服務基類。
  BaseGarbageService({required this.localSourceDir});

  /// 抽象方法：檢查版本並同步清運點位資料至資料庫。
  /// [onProgress] 同步進度回調函式。
  Future<void> syncDataIfNeeded({void Function(String)? onProgress});

  /// 抽象方法：獲取該城市目前的垃圾車動態（API 或 班表）。
  /// 回傳即時 [GarbageTruck] 清單。
  Future<List<GarbageTruck>> fetchTrucks();

  /// 抽象方法：根據指定的時間點，從資料庫中檢索預計出現的垃圾車。
  /// [hour] 小時，[minute] 分鐘。
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute);

  /// 抽象方法：獲取特定路線編號的完整點位序列。
  /// [lineId] 路線編號。
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId);

  /// 釋放資源（如關閉 HTTP 用戶端）。
  void dispose();
}

/// 內部使用的解析封裝物件，用於 Isolate 溝通。
class _CsvParseInput {
  final String csvBody;
  const _CsvParseInput(this.csvBody);
}

/// 在獨立 Isolate 中執行的 CSV 解析函式。
List<GarbageRoutePoint> _parseCsvIsolate(_CsvParseInput input) {
  final List<List<dynamic>> fields = const CsvToListConverter(
    shouldParseNumbers: false, 
    eol: '\n'
  ).convert(input.csvBody);

  if (fields.length <= 1) return [];

  // 解析 CSV 標頭欄位索引
  final header = fields[0].map((e) => e.toString().toLowerCase().trim()).toList();
  int idxLineId = header.indexOf('lineid');
  int idxLat = header.indexOf('latitude');
  int idxLng = header.indexOf('longitude');
  int idxTime = header.indexOf('time');
  int idxLineName = header.indexOf('linename');
  int idxName = header.indexOf('name');
  int idxRank = header.indexOf('rank');

  List<GarbageRoutePoint> result = [];
  for (int i = 1; i < fields.length; i++) {
    final row = fields[i];
    if (row.length < 4) continue;

    result.add(GarbageRoutePoint(
      lineId: row[idxLineId].toString(),
      lineName: idxLineName != -1 ? row[idxLineName].toString() : '',
      rank: idxRank != -1 ? (int.tryParse(row[idxRank].toString()) ?? 0) : i,
      name: idxName != -1 ? row[idxName].toString() : '',
      position: LatLng(
        double.tryParse(row[idxLat].toString()) ?? 0, 
        double.tryParse(row[idxLng].toString()) ?? 0
      ),
      arrivalTime: row[idxTime].toString(),
    ));
  }
  return result;
}

/// [NtpcGarbageService] 負責新北市垃圾清運資料的處理。
/// 
/// 支援從新北市政府開放資料平台下載 CSV 格式的即時位置與路線班表。
class NtpcGarbageService extends BaseGarbageService {
  /// 即時位置 API (CSV 格式)
  static const String apiUrl = 'https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/csv';
  /// 路線班表 API (CSV 格式)
  static const String routeUrl = 'https://data.ntpc.gov.tw/api/datasets/edc3ad26-8ae7-4916-a00b-bc6048d19bf8/csv';

  /// 模擬瀏覽器的請求標頭，避免觸發政府伺服器的防爬蟲機制。
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/csv, application/json',
    'Referer': 'https://data.ntpc.gov.tw/',
  };

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  /// 建構子：初始化新北市服務。
  /// [localSourceDir] 資源路徑，[client] 可選傳入 http.Client。
  NtpcGarbageService({required super.localSourceDir, http.Client? client}) 
      : _client = client ?? http.Client() {
    DatabaseService.log('NtpcGarbageService 已建立');
  }

  @override
  void dispose() {
    _client.close();
    DatabaseService.log('NtpcGarbageService 已釋放資源 (Client closed)');
  }

  /// 新北市資料同步邏輯。
  /// 
  /// 優先級：雲端 API > 本地 CSV 備份 > 硬編碼模擬資料。
  /// [onProgress] 進度回報。
  @override
  Future<void> syncDataIfNeeded({void Function(String)? onProgress}) async {
    String currentAppVersion = '1.0.0+1';
    try {
      if (!kIsWeb) {
        final PackageInfo packageInfo = await PackageInfo.fromPlatform();
        currentAppVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
      }
    } catch (e) {
      DatabaseService.log('PackageInfo error: $e');
    }
    
    final String? storedVersion = await _dbService.getStoredVersion('ntpc');

    // 檢查是否需要更新
    bool needsUpdate = storedVersion != currentAppVersion || !(await _dbService.hasData('ntpc'));

    if (!needsUpdate) {
      onProgress?.call('新北市快取資料已為最新...');
      return;
    }

    onProgress?.call('嘗試從新北市政府 Open Data 更新路線...');
    
    // Web 端使用代理繞過 CORS
    String targetUrl = routeUrl;
    if (kIsWeb) {
      targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent('$routeUrl?size=100000');
      DatabaseService.log('CORS Proxy: $targetUrl');
    }

    bool apiSuccess = await _syncFromApi(onProgress, customUrl: kIsWeb ? targetUrl : null);

    if (apiSuccess) {
      await _dbService.updateVersion(currentAppVersion, 'ntpc');
      onProgress?.call('新北市路線同步完成 (雲端)。');
    } else {
      onProgress?.call('雲端 API 同步失敗，嘗試讀取本地 CSV 備援檔案...');
      if (await _importFromLocalCSV(onProgress)) {
        await _dbService.updateVersion(currentAppVersion, 'ntpc');
        onProgress?.call('新北市路線同步完成 (本地 CSV)。');
      } else {
        onProgress?.call('本地 CSV 讀取失敗，使用內建模擬資料。');
        await _insertMockRouteData();
      }
    }
  }

  /// 從雲端 API 下載並解析 CSV 路線資料。
  /// [onProgress] 進度回報。
  /// [customUrl] 可選的自定義 URL (用於代理)。
  /// 回傳是否成功。
  Future<bool> _syncFromApi(void Function(String)? onProgress, {String? customUrl}) async {
    try {
      final String url = customUrl ?? '$routeUrl?size=100000';
      final response = await _client.get(Uri.parse(url), headers: _headers);
      
      if (response.statusCode == 200) {
        onProgress?.call('獲取原始 CSV 資料，正在解析...');
        
        List<GarbageRoutePoint> allPoints;
        if (kIsWeb) {
          allPoints = _parseCsvIsolate(_CsvParseInput(response.body.trim()));
        } else {
          allPoints = await compute(_parseCsvIsolate, _CsvParseInput(response.body.trim()));
        }

        if (allPoints.isNotEmpty) {
          onProgress?.call('解析完成，共有 ${allPoints.length} 筆點位，正在清理舊資料並寫入...');
          await _dbService.clearAllRoutePoints('ntpc');
          
          // 增加批次寫入的大小 (從 1000 提升到 5000) 以減少與 SQLite 的互動頻率
          const int batchSize = 5000;
          for (int i = 0; i < allPoints.length; i += batchSize) {
            int end = (i + batchSize < allPoints.length) ? i + batchSize : allPoints.length;
            await _dbService.saveRoutePoints(allPoints.sublist(i, end), 'ntpc');
            onProgress?.call('資料庫寫入進度: $end / ${allPoints.length}...');
          }
          return true;
        }
      } else {
        DatabaseService.log('新北市 API 回傳錯誤碼: ${response.statusCode}');
      }
    } catch (e) {
      DatabaseService.log('新北市 API 同步錯誤', error: e);
    }
    return false;
  }

  /// 備援方案：從開發者預放在本地目錄的 CSV 匯入。
  /// [onProgress] 進度回報。
  /// 回傳是否成功。
  Future<bool> _importFromLocalCSV(void Function(String)? onProgress) async {
    if (kIsWeb) return false;
    try {
      final directory = Directory(localSourceDir);
      if (!await directory.exists()) return false;
      final files = await directory.list().toList();
      final csvFile = files.firstWhere((f) => f.path.toLowerCase().endsWith('.csv')) as File;
      final String csvContent = await csvFile.readAsString();
      final List<List<dynamic>> fields = const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(csvContent);
      if (fields.isEmpty) return false;

      // 標頭解析邏輯
      final header = fields[0].map((e) => e.toString().toLowerCase().trim()).toList();
      int findIndex(List<String> keywords) {
        for (var k in keywords) {
          int idx = header.indexOf(k.toLowerCase());
          if (idx != -1) return idx;
        }
        return -1;
      }

      final int idxLineId = findIndex(['lineid', '路線編號']);
      final int idxLat = findIndex(['latitude', '緯度', 'lat']);
      final int idxLng = findIndex(['longitude', '經度', 'lng', 'lon']);
      final int idxTime = findIndex(['time', '抵達時間']);
      final int idxLineName = findIndex(['linename', '路線名稱']);
      final int idxName = findIndex(['name', '清運點名稱']);
      final int idxRank = findIndex(['rank', '順序']);

      List<GarbageRoutePoint> batch = [];
      int totalRows = fields.length - 1;
      for (int i = 1; i < fields.length; i++) {
        final row = fields[i];
        if (row.length < 4) continue;
        batch.add(GarbageRoutePoint(
          lineId: row[idxLineId].toString(),
          lineName: idxLineName != -1 ? row[idxLineName].toString() : '',
          rank: idxRank != -1 ? (int.tryParse(row[idxRank].toString()) ?? 0) : i,
          name: idxName != -1 ? row[idxName].toString() : '',
          position: LatLng(double.tryParse(row[idxLat].toString()) ?? 0, double.tryParse(row[idxLng].toString()) ?? 0),
          arrivalTime: row[idxTime].toString(),
        ));
        if (batch.length >= 1000) { 
          await _dbService.saveRoutePoints(batch, 'ntpc'); 
          batch.clear(); 
          onProgress?.call('已匯入 $i / $totalRows 筆 (本地)...');
        }
      }
      if (batch.isNotEmpty) await _dbService.saveRoutePoints(batch, 'ntpc');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 抓取新北市即時位置 CSV 並解析。
  /// 
  /// 回傳即時 [GarbageTruck] 清單，若失敗則回退至班表。
  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String requestUrl = '$apiUrl?size=20000&_t=$timestamp';
      
      final response = await _client.get(Uri.parse(requestUrl), headers: _headers);
      if (response.statusCode == 200) {
        final String body = response.body.trim();
        final List<List<dynamic>> rows = const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(body);
        
        if (rows.length > 1) {
          final header = rows[0].map((e) => e.toString().toLowerCase().trim()).toList();
          final int idxLineId = header.indexOf('lineid');
          final int idxCar = header.indexOf('car');
          final int idxLat = header.indexOf('latitude');
          final int idxLng = header.indexOf('longitude');
          final int idxTime = header.indexOf('time');
          final int idxLoc = header.indexOf('location');

          List<GarbageTruck> trucks = [];
          for (int i = 1; i < rows.length; i++) {
            final row = rows[i];
            if (row.length < 5) continue;

            trucks.add(GarbageTruck(
              carNumber: row[idxCar].toString(),
              lineId: row[idxLineId].toString(),
              location: row[idxLoc].toString(),
              position: LatLng(
                double.tryParse(row[idxLat].toString()) ?? 0,
                double.tryParse(row[idxLng].toString()) ?? 0,
              ),
              updateTime: DateTime.tryParse(row[idxTime].toString()) ?? DateTime.now(),
            ));
          }
          return trucks;
        }
      }
    } catch (e) {
      DatabaseService.log('新北市即時 CSV 解析失敗，切換為班表查詢模式', error: e);
    }

    // 若 API 失敗，退回搜尋班表
    final now = DateTime.now();
    return await findTrucksByTime(now.hour, now.minute);
  }

  /// 根據指定時間點查詢新北市班表預估。
  /// [hour] 小時，[minute] 分鐘。
  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'ntpc');
    final now = DateTime.now();
    return points.map((p) {
      DateTime scheduledTime = now;
      try {
        final parts = p.arrivalTime.split(':');
        if (parts.length == 2) scheduledTime = DateTime(now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]));
      } catch (_) {}
      return GarbageTruck(
        carNumber: scheduledTime.isBefore(now) ? '已過站' : '預定車', 
        lineId: p.lineId, 
        location: '${p.lineName} - ${p.name}', 
        position: p.position, 
        updateTime: scheduledTime
      );
    }).toList();
  }

  /// 獲取特定路線的點位清單。
  /// [lineId] 路線編號。
  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async {
    return await _dbService.getRoutePoints(lineId, 'ntpc');
  }

  /// 極端狀況下的模擬點位插入。
  Future<void> _insertMockRouteData() async {
    await _dbService.saveRoutePoints([
      GarbageRoutePoint(lineId: 'MOCK-01', lineName: '測試路線', rank: 1, name: '測試站點', position: LatLng(25.0, 121.5), arrivalTime: '20:30'),
    ], 'ntpc');
  }
}
