/// [整體程式說明]
/// 本文件定義了台北市（Taipei）的垃圾清運服務實作。
/// 支援手動強制更新（透過分頁 API 獲取完整 4000+ 筆資料）與啟動自動載入（Assets）。

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
    final double? lat = double.tryParse(item['緯度']?.toString() ?? item['latitude']?.toString() ?? '');
    final double? lng = double.tryParse(item['經度']?.toString() ?? item['longitude']?.toString() ?? '');
    String timeRaw = (item['抵達時間'] ?? item['time'] ?? '').toString();
    if (lat != null && lng != null && timeRaw.isNotEmpty) {
      if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;
      final String lineName = (item['路線名稱'] ?? item['linename'] ?? '').toString();
      final String carNo = (item['車號'] ?? item['car'] ?? '').toString();
      points.add(GarbageRoutePoint(
        lineId: carNo.isNotEmpty ? '$lineName ($carNo)' : lineName, lineName: lineName,
        rank: int.tryParse(item['序號']?.toString() ?? item['rank']?.toString() ?? '0') ?? 0,
        name: (item['地點名稱'] ?? item['name'] ?? '').toString(), position: LatLng(lat, lng),
        arrivalTime: TimeUtils.formatTo24Hour(timeRaw),
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

  TaipeiGarbageService({required super.localSourceDir, http.Client? client}) : _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress}) async {
    final bool hasData = await _dbService.hasData('taipei');

    if (!force) {
      if (!hasData) {
        onProgress?.call('初次啟動，正在載入台北市預設點位...');
        await _importFromLocalJson(onProgress);
      }
      return;
    }

    onProgress?.call('正在連線台北市政府 API 執行完整同步...');
    
    // [優化]：台北市 API 限制單次 1000 筆，我們必須執行分頁抓取
    List<GarbageRoutePoint> allPoints = [];
    bool apiSuccess = false;
    const int pageSize = 1000;
    
    try {
      for (int offset = 0; offset <= 6000; offset += pageSize) {
        onProgress?.call('正在獲取分頁數據: $offset ~ ${offset + pageSize}...');
        String targetUrl = '$routeUrl&limit=$pageSize&offset=$offset';
        if (kIsWeb) targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
        
        final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) break;
        
        final List<GarbageRoutePoint> pagePoints = await compute(_parseTaipeiJsonIsolate, _TaipeiParseInput(response.body));
        if (pagePoints.isEmpty) break;
        
        allPoints.addAll(pagePoints);
        onProgress?.call('已累積獲取: ${allPoints.length} 筆點位');
        
        // 如果該頁不滿 1000 筆，代表拿完了
        if (pagePoints.length < 500) break; 
      }

      if (allPoints.isNotEmpty) {
        onProgress?.call('正在存入資料庫 (${allPoints.length} 筆)...');
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'taipei', (saved, total) {
          onProgress?.call('資料庫更新中: $saved / $total 筆');
        });
        apiSuccess = true;
      }
    } catch (e) {
      DatabaseService.log('台北市分頁同步失敗', error: e);
    }

    if (!apiSuccess) {
      onProgress?.call('雲端連線失敗，正在載入備援資料...');
      await _importFromLocalJson(onProgress);
    }
  }

  Future<String> _downloadWithProgress(void Function(String)? onProgress, String url, int timeout) async {
    final request = http.Request('GET', Uri.parse(url));
    final streamedResponse = await _client.send(request).timeout(Duration(seconds: timeout));
    if (streamedResponse.statusCode != 200) throw Exception('HTTP Error');
    int receivedBytes = 0; final List<int> bytes = [];
    await for (var chunk in streamedResponse.stream.timeout(Duration(seconds: timeout))) {
      bytes.addAll(chunk); receivedBytes += chunk.length;
      onProgress?.call('下載中: ${(receivedBytes / 1024).toStringAsFixed(1)} KB');
    }
    return utf8.decode(bytes);
  }

  Future<bool> _importFromLocalJson(void Function(String)? onProgress) async {
    try {
      final String content = await rootBundle.loadString('assets/taipei_route.json');
      final List<GarbageRoutePoint> points = _parseTaipeiJsonIsolate(_TaipeiParseInput(content));
      if (points.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(points, 'taipei', (saved, total) => onProgress?.call('載入預設點位: $saved / $total 筆'));
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      String targetUrl = truckUrl + '&limit=1000';
      if (kIsWeb) targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        final List<dynamic> results = root['result']?['results'] ?? [];
        List<GarbageTruck> trucks = [];
        for (var item in results) {
          final double? lat = double.tryParse(item['緯度']?.toString() ?? '0');
          final double? lng = double.tryParse(item['經度']?.toString() ?? '0');
          if (lat != null && lng != null) {
            if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;
            final String lineName = (item['路線名稱'] ?? '').toString();
            final String carNo = (item['車號'] ?? '未知').toString();
            trucks.add(GarbageTruck(
              carNumber: carNo, lineId: carNo != '未知' ? '$lineName ($carNo)' : lineName,
              location: (item['位置描述'] ?? '').toString(), position: LatLng(lat, lng), updateTime: DateTime.now(), isRealTime: true,
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
    return points.map((p) => GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: p.name, position: p.position, updateTime: DateTime.now(), isRealTime: false)).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'taipei');
}
