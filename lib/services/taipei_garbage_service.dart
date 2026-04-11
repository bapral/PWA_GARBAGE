/// [整體程式說明]
/// 本文件定義了台北市（Taipei）的垃圾清運服務實作。
/// 支援手動強制更新（分頁抓取）與自動強制版本升級（Assets）。

import 'dart:convert';
import 'dart:async';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'base_garbage_service.dart';
import '../utils/time_utils.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 內部使用的解析封裝物件，用於台北市 Isolate 溝通。
class _TaipeiParseInput { final String body; const _TaipeiParseInput(this.body); }

/// 解析台北市 JSON 資料的 Isolate 函式。
List<GarbageRoutePoint> _parseTaipeiJsonIsolate(_TaipeiParseInput input) {
  final dynamic decoded = json.decode(input.body);
  List<dynamic> results = [];
  if (decoded is Map && decoded.containsKey('result')) results = decoded['result']['results'] ?? [];
  else if (decoded is List) results = decoded;

  List<GarbageRoutePoint> points = [];
  for (var item in results) {
    // 兼容多種座標欄位名稱
    final double? lat = double.tryParse(item['緯度']?.toString() ?? item['latitude']?.toString() ?? item['ç·¯åº¦']?.toString() ?? '');
    final double? lng = double.tryParse(item['經度']?.toString() ?? item['longitude']?.toString() ?? item['ç¶åº¦']?.toString() ?? '');
    
    // 兼容多種時間與名稱欄位
    String timeRaw = (item['抵達時間'] ?? item['time'] ?? item['æµéæé'] ?? '').toString();
    
    if (lat != null && lng != null && timeRaw.isNotEmpty) {
      if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;
      
      final String lineName = (item['路線'] ?? item['路線名稱'] ?? item['linename'] ?? item['è·¯ç·'] ?? '').toString();
      final String carNo = (item['車號'] ?? item['car'] ?? item['è»è'] ?? '').toString();
      final String siteName = (item['地點'] ?? item['地點名稱'] ?? item['name'] ?? item['å°é»'] ?? '').toString();
      
      points.add(GarbageRoutePoint(
        lineId: carNo.isNotEmpty ? '$lineName ($carNo)' : lineName, 
        lineName: lineName,
        rank: int.tryParse(item['序號']?.toString() ?? item['rank']?.toString() ?? '0') ?? 0,
        name: siteName, 
        position: LatLng(lat, lng),
        arrivalTime: TimeUtils.formatTo24Hour(timeRaw),
      ));
    }
  }
  return points;
}

/// 內部使用的即時車輛解析封裝物件。
class _TaipeiTruckParseInput { final String body; const _TaipeiTruckParseInput(this.body); }

/// 解析台北市即時車輛 JSON 資料的 Isolate 函式。
List<GarbageTruck> _parseTaipeiTrucksIsolate(_TaipeiTruckParseInput input) {
  final Map<String, dynamic> root = json.decode(input.body);
  final List<dynamic> results = root['result']?['results'] ?? [];
  
  List<GarbageTruck> allTrucks = [];
  for (var item in results) {
    final double? lat = double.tryParse(item['緯度']?.toString() ?? '0');
    final double? lng = double.tryParse(item['經度']?.toString() ?? '0');
    
    if (lat != null && lng != null && lat > 22 && lat < 26 && item['車號'] != null) {
      final String lineName = (item['路線'] ?? item['路線名稱'] ?? '').toString();
      final String carNo = item['車號'].toString();
      
      allTrucks.add(GarbageTruck(
        carNumber: carNo, 
        lineId: '$lineName ($carNo)',
        location: (item['地點'] ?? item['位置描述'] ?? '').toString(), 
        position: LatLng(lat, lng), 
        updateTime: DateTime.now(), 
        isRealTime: true,
      ));
    }
  }
  return allTrucks;
}

class TaipeiGarbageService extends BaseGarbageService {
  static const String routeUrl = 'https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire';
  static const String truckUrl = 'https://data.taipei/api/v1/dataset/d394142f-7634-4b4f-8b54-7f4f6e63289a?scope=resourceAcknowledge';

  // [重要] 資產版本號，每次更新 assets/*.json 後增加此數字可強制所有使用者升級
  static const String requiredAssetVersion = '20260411_v4'; 

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  TaipeiGarbageService({required super.localSourceDir, http.Client? client}) : _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress}) async {
    final String? storedVersion = await _dbService.getStoredVersion('taipei');
    final int currentCount = await _dbService.getTotalCount('taipei');

    // [優化邏輯]：若版本不符或資料筆數不足 4000 (台北市正常應為 4015 筆)
    if (!force && (storedVersion == requiredAssetVersion && currentCount >= 4000)) {
      return;
    }

    onProgress?.call('正在從台北市政府 API 獲取最新班表...');
    List<GarbageRoutePoint> allPoints = [];
    bool apiSuccess = false;
    const int pageSize = 1000;
    
    try {
      // 台北市資料約 4100 筆，我們抓取 5 頁確保完整
      for (int offset = 0; offset <= 5000; offset += pageSize) {
        onProgress?.call('下載中: $offset ~ ${offset + pageSize}...');
        String targetUrl = '$routeUrl&limit=$pageSize&offset=$offset';
        if (kIsWeb) targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
        
        final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) break;
        
        final List<GarbageRoutePoint> pagePoints = await compute(_parseTaipeiJsonIsolate, _TaipeiParseInput(response.body));
        if (pagePoints.isEmpty) break;
        
        allPoints.addAll(pagePoints);
        if (pagePoints.length < 500) break; // 若最後一頁資料不足，提前結束
      }

      if (allPoints.isNotEmpty && allPoints.length >= 3000) {
        onProgress?.call('正在更新資料庫 (${allPoints.length} 筆)...');
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'taipei', (saved, total) => onProgress?.call('資料寫入中: $saved / $total 筆'));
        apiSuccess = true;
      }
    } catch (e) {
      DatabaseService.log('Taipei API Sync Failed', error: e);
    }

    if (apiSuccess) {
      await _dbService.updateVersion(requiredAssetVersion, 'taipei');
      onProgress?.call('台北市班表更新成功！');
    } else {
      // 只有在 API 完全失敗且本地完全沒資料時才載入資產檔 (墊底方案)
      if (currentCount < 100) {
        onProgress?.call('雲端連線失敗，改從備援資料恢復...');
        if (await _importFromLocalJson(onProgress)) {
          await _dbService.updateVersion('fallback_asset', 'taipei');
        }
      } else {
        onProgress?.call('連線失敗，保留現有本地資料。');
      }
    }
  }

  Future<bool> _importFromLocalJson(void Function(String)? onProgress) async {
    try {
      final String content = await rootBundle.loadString('assets/taipei_route.json');
      final List<GarbageRoutePoint> points = await compute(_parseTaipeiJsonIsolate, _TaipeiParseInput(content));
      if (points.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(points, 'taipei', (saved, total) => onProgress?.call('載入內建資料: ${points.length} 筆'));
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      // 根據 REALTIME_GARBAGE_API_GUIDE.md，台北市即時與班表整合在同一 API
      // 必須加上 limit=20000 以取得全量資料
      String targetUrl = '$routeUrl&limit=20000';
      
      if (kIsWeb) {
        // [修正]：處理 PWA 模式下的代理響應格式
        targetUrl = 'https://api.allorigins.win/get?url=' + Uri.encodeComponent(targetUrl);
        final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 15));
        
        if (response.statusCode == 200) {
          final Map<String, dynamic> proxyData = json.decode(response.body);
          final String realBody = proxyData['contents'] ?? '';
          
          if (realBody.isNotEmpty) {
            final List<GarbageTruck> allTrucks = await compute(
              _parseTaipeiTrucksIsolate, 
              _TaipeiTruckParseInput(realBody)
            );
            if (allTrucks.isNotEmpty) return allTrucks;
          }
        }
      } else {
        final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final List<GarbageTruck> allTrucks = await compute(
            _parseTaipeiTrucksIsolate, 
            _TaipeiTruckParseInput(response.body)
          );
          if (allTrucks.isNotEmpty) return allTrucks;
        }
      }
    } catch (e) {
      DatabaseService.log('Taipei Realtime Fetch Failed', error: e);
    }
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'taipei');
    return points.map((p) => GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: p.name, position: p.position, updateTime: DateTime.now(), isRealTime: false)).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'taipei');
}
