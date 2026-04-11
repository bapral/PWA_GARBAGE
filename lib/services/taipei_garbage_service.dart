/// [整體程式說明]
/// 本文件定義了台北市（Taipei）的垃圾清運服務實作。
/// 遵循 GARBAGE_DATA_GUIDE.md 實作複合 Key、時間格式化與座標範圍驗證。

import 'dart:convert';
import 'dart:async';
import 'package:latlong2/latlong.dart';
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
  final dynamic decoded = json.decode(input.body);
  List<dynamic> results = [];
  
  if (decoded is Map && decoded.containsKey('result')) {
    results = decoded['result']['results'] ?? [];
  } else if (decoded is List) {
    results = decoded;
  }

  List<GarbageRoutePoint> points = [];
  for (var item in results) {
    final double? lat = double.tryParse(item['緯度']?.toString() ?? item['latitude']?.toString() ?? '');
    final double? lng = double.tryParse(item['經度']?.toString() ?? item['longitude']?.toString() ?? '');
    String time = (item['抵達時間'] ?? item['time'] ?? '').toString();
    
    // [指南要求]：處理時間格式，將 "2030" 轉換為 "20:30"
    if (time.length == 4 && !time.contains(':')) {
      time = '${time.substring(0, 2)}:${time.substring(2, 4)}';
    }

    if (lat != null && lng != null && time.isNotEmpty) {
      // [指南要求]：座標範圍驗證 (22-26, 120-122)
      if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;

      final String lineName = (item['路線名稱'] ?? item['linename'] ?? '').toString();
      final String carNo = (item['車號'] ?? item['car'] ?? '').toString();

      points.add(GarbageRoutePoint(
        // [指南要求]：台北市使用「路線名稱 + 車號」作為唯一識別，避免同一路線多台車造成跳動
        lineId: carNo.isNotEmpty ? '$lineName ($carNo)' : lineName,
        lineName: lineName,
        rank: int.tryParse(item['序號']?.toString() ?? item['rank']?.toString() ?? '0') ?? 0,
        name: (item['地點名稱'] ?? item['name'] ?? '').toString(),
        position: LatLng(lat, lng),
        arrivalTime: time,
      ));
    }
  }
  return points;
}

class TaipeiGarbageService extends BaseGarbageService {
  static const String routeUrl = 'https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire';
  static const String truckUrl = 'https://data.taipei/api/v1/dataset/d394142f-7634-4b4f-8b54-7f4f6e63289a?scope=resourceAcknowledge';

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  TaipeiGarbageService({required super.localSourceDir, http.Client? client}) 
      : _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  Future<void> syncDataIfNeeded({void Function(String)? onProgress}) async {
    String currentAppVersion = '1.0.0+1';
    try {
      if (!kIsWeb) {
        final PackageInfo packageInfo = await PackageInfo.fromPlatform();
        currentAppVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
      }
    } catch (_) {}
    
    final String? storedVersion = await _dbService.getStoredVersion('taipei');
    if (storedVersion == currentAppVersion && (await _dbService.hasData('taipei'))) {
      onProgress?.call('台北市資料已就緒...');
      return;
    }

    onProgress?.call('正在初始化台北市資料更新...');
    
    try {
      // [指南要求]：台北市請求必須包含 limit=20000 否則資料不全
      String targetUrl = routeUrl + '&limit=20000';
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      
      onProgress?.call('正在從雲端獲取最新班表...');
      const int timeoutSeconds = 20;
      final String content = await _downloadWithProgress(onProgress, targetUrl, timeoutSeconds);
      
      onProgress?.call('正在背景解析數據...');
      final List<GarbageRoutePoint> allPoints = await compute(_parseTaipeiJsonIsolate, _TaipeiParseInput(content));
      
      if (allPoints.isNotEmpty) {
        onProgress?.call('正在存入資料庫...');
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'taipei', (saved, total) {
          onProgress?.call('資料庫寫入中: $saved / $total 筆');
        });
        await _dbService.updateVersion(currentAppVersion, 'taipei');
        onProgress?.call('台北市同步完成！');
        return;
      }
      throw Exception('無有效數據');
    } catch (e) {
      DatabaseService.log('台北市同步失敗', error: e);
      if (await _importFromLocalJson(onProgress)) {
        await _dbService.updateVersion(currentAppVersion, 'taipei');
        onProgress?.call('台北市內建資料載入成功。');
      }
    }
  }

  Future<String> _downloadWithProgress(void Function(String)? onProgress, String url, int timeout) async {
    final request = http.Request('GET', Uri.parse(url));
    final streamedResponse = await _client.send(request).timeout(Duration(seconds: timeout));
    if (streamedResponse.statusCode != 200) throw Exception('HTTP Error');

    int receivedBytes = 0;
    final List<int> bytes = [];
    await for (var chunk in streamedResponse.stream.timeout(Duration(seconds: timeout))) {
      bytes.addAll(chunk);
      receivedBytes += chunk.length;
      onProgress?.call('下載中: ${(receivedBytes / 1024).toStringAsFixed(1)} KB');
    }
    return utf8.decode(bytes);
  }

  Future<bool> _importFromLocalJson(void Function(String)? onProgress) async {
    try {
      final String content = await rootBundle.loadString('assets/taipei_route.json');
      final List<GarbageRoutePoint> points = _parseTaipeiJsonIsolate(_TaipeiParseInput(content));
      if (points.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(points, 'taipei', (saved, total) {
          onProgress?.call('載入內建資料: $saved / $total 筆');
        });
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      // 即時 API 同樣建議加 limit
      String targetUrl = truckUrl + '&limit=1000';
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        final List<dynamic> results = root['result']?['results'] ?? [];
        
        List<GarbageTruck> trucks = [];
        for (var item in results) {
          final double? lat = double.tryParse(item['緯度']?.toString() ?? '0');
          final double? lng = double.tryParse(item['經度']?.toString() ?? '0');
          
          if (lat != null && lng != null) {
            // 座標合法性檢查
            if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;

            final String lineName = (item['路線名稱'] ?? '').toString();
            final String carNo = (item['車號'] ?? '未知').toString();

            trucks.add(GarbageTruck(
              carNumber: carNo,
              // [指南要求]：即時資料也採用複合 Key 邏輯
              lineId: carNo != '未知' ? '$lineName ($carNo)' : lineName,
              location: (item['位置描述'] ?? '').toString(),
              position: LatLng(lat, lng),
              updateTime: DateTime.now(),
              isRealTime: true,
            ));
          }
        }
        return trucks;
      }
    } catch (_) {}
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
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
      isRealTime: false,
    )).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'taipei');
}
