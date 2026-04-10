/// [整體程式說明]
/// 本文件定義了 [TaipeiGarbageService] 類別，專門處理台北市的垃圾清運資料。
/// 支援台北市 Open Data 平台提供的 JSON API，並整合了 CSV 本地備援方案。
/// 該服務負責解析台北市複雜的清運點位資訊，包含路線、車號、以及格式多樣的時間字串。
///
/// [執行順序說明]
/// 1. 呼叫 `syncDataIfNeeded`：首先嘗試連線至台北市 Open Data API。
/// 2. 若 API 回傳正常，解析 JSON 數組，並使用 `_formatTime` 工具將時間標準化。
/// 3. 將資料組合為 `GarbageRoutePoint` 並透過 `DatabaseService` 批量存入。
/// 4. 若雲端 API 同步失敗，自動轉向讀取 `localSourceDir` 下的 CSV 資源檔案。
/// 5. 呼叫 `fetchTrucks` 時，優先嘗試即時 API，若失敗則回退至資料庫班表推估。

import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'package:csv/csv.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'ntpc_garbage_service.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 內部使用的解析封裝物件，用於台北市 Isolate 溝通。
class _TaipeiParseInput {
  final String body;
  const _TaipeiParseInput(this.body);
}

/// 解析台北市 JSON 資料的 Isolate 函式。
List<GarbageRoutePoint> _parseTaipeiJsonIsolate(_TaipeiParseInput input) {
  final List<dynamic> data = json.decode(input.body);
  List<GarbageRoutePoint> points = [];

  for (var item in data) {
    final double? lat = double.tryParse(item['latitude']?.toString() ?? '');
    final double? lng = double.tryParse(item['longitude']?.toString() ?? '');
    final String time = item['time']?.toString() ?? '';
    
    if (lat != null && lng != null && time.isNotEmpty) {
      points.add(GarbageRoutePoint(
        lineId: item['lineid']?.toString() ?? '',
        lineName: item['linename']?.toString() ?? '',
        rank: int.tryParse(item['rank']?.toString() ?? '0') ?? 0,
        name: item['name']?.toString() ?? '',
        position: LatLng(lat, lng),
        arrivalTime: time,
      ));
    }
  }
  return points;
}

/// [TaipeiGarbageService] 負責台北市清運資料同步與即時動態。
class TaipeiGarbageService extends BaseGarbageService {
  /// 台北市路線 API (JSON)
  static const String routeUrl = 'https://data.taipei/api/v1/dataset/fb66099b-00a4-44a5-9273-51616c68e98f?scope=resourceAcknowledge';
  /// 台北市即時位置 API (JSON)
  static const String truckUrl = 'https://data.taipei/api/v1/dataset/d394142f-7634-4b4f-8b54-7f4f6e63289a?scope=resourceAcknowledge';

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  TaipeiGarbageService({required super.localSourceDir, http.Client? client}) 
      : _client = client ?? http.Client() {
    DatabaseService.log('TaipeiGarbageService 已建立');
  }

  @override
  void dispose() {
    _client.close();
    DatabaseService.log('TaipeiGarbageService 已釋放資源');
  }

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
    
    final String? storedVersion = await _dbService.getStoredVersion('taipei');

    if (storedVersion == currentAppVersion && (await _dbService.hasData('taipei'))) {
      onProgress?.call('台北市資料已為最新...');
      return;
    }

    onProgress?.call('同步台北市資料中...');
    
    try {
      String targetUrl = routeUrl;
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 20));
      
      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        final List<dynamic> results = root['result']?['results'] ?? [];
        
        onProgress?.call('成功解析 ${results.length} 筆資料，寫入中...');
        
        List<GarbageRoutePoint> allPoints = [];
        for (var item in results) {
          final double? lat = double.tryParse(item['緯度']?.toString() ?? '');
          final double? lng = double.tryParse(item['經度']?.toString() ?? '');
          if (lat != null && lng != null) {
            allPoints.add(GarbageRoutePoint(
              lineId: item['路線編號']?.toString() ?? '',
              lineName: item['路線名稱']?.toString() ?? '',
              rank: int.tryParse(item['序號']?.toString() ?? '0') ?? 0,
              name: item['地點名稱']?.toString() ?? '',
              position: LatLng(lat, lng),
              arrivalTime: item['抵達時間']?.toString() ?? '',
            ));
          }
        }
        
        await _dbService.clearAndSaveRoutePoints(allPoints, 'taipei');
        await _dbService.updateVersion(currentAppVersion, 'taipei');
        onProgress?.call('台北市資料同步完成！');
      } else {
        throw Exception('API 回傳錯誤');
      }
    } catch (e) {
      DatabaseService.log('台北市 API 同步失敗，嘗試本地備援', error: e);
      if (await _importFromLocalCSV(onProgress)) {
        await _dbService.updateVersion(currentAppVersion, 'taipei');
        onProgress?.call('台北市資料同步完成 (本地備援)！');
      } else {
        onProgress?.call('台北市資料同步失敗。');
      }
    }
  }

  Future<bool> _importFromLocalCSV(void Function(String)? onProgress) async {
    try {
      String csvContent;
      try {
        csvContent = await rootBundle.loadString('assets/taipei_route.csv');
      } catch (e) {
        DatabaseService.log('無法載入台北市本地 CSV: $e');
        return false;
      }
      
      final List<List<dynamic>> fields = const CsvToListConverter().convert(csvContent);
      if (fields.length <= 1) return false;

      List<GarbageRoutePoint> points = [];
      for (int i = 1; i < fields.length; i++) {
        final row = fields[i];
        points.add(GarbageRoutePoint(
          lineId: row[0].toString(),
          lineName: row[1].toString(),
          rank: int.tryParse(row[2].toString()) ?? 0,
          name: row[3].toString(),
          position: LatLng(double.tryParse(row[4].toString()) ?? 0, double.tryParse(row[5].toString()) ?? 0),
          arrivalTime: row[6].toString(),
        ));
      }
      await _dbService.clearAndSaveRoutePoints(points, 'taipei');
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      String targetUrl = truckUrl;
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      
      final response = await _client.get(Uri.parse(targetUrl));
      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        final List<dynamic> results = root['result']?['results'] ?? [];
        
        return results.map((item) => GarbageTruck(
          carNumber: item['車號']?.toString() ?? '未知',
          lineId: item['路線編號']?.toString() ?? '',
          location: item['位置描述']?.toString() ?? '',
          position: LatLng(double.tryParse(item['緯度']?.toString() ?? '0') ?? 0, double.tryParse(item['經度']?.toString() ?? '0') ?? 0),
          updateTime: DateTime.tryParse(item['最後更新時間']?.toString() ?? '') ?? DateTime.now(),
        )).toList();
      }
    } catch (_) {}
    
    final now = DateTime.now();
    return await findTrucksByTime(now.hour, now.minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'taipei');
    return points.map((p) => GarbageTruck(
      carNumber: '預定車',
      lineId: p.lineId,
      location: p.name,
      position: p.position,
      updateTime: DateTime.now(),
    )).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async {
    return await _dbService.getRoutePoints(lineId, 'taipei');
  }
}
