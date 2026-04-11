/// [整體程式說明]
/// 本文件定義了台北市（Taipei）的垃圾清運服務實作。
/// 支援串流下載以即時顯示下載進度與筆數。

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
    final String time = item['抵達時間']?.toString() ?? item['time']?.toString() ?? '';
    
    if (lat != null && lng != null && time.isNotEmpty) {
      points.add(GarbageRoutePoint(
        lineId: item['路線編號']?.toString() ?? item['lineid']?.toString() ?? '',
        lineName: item['路線名稱']?.toString() ?? item['linename']?.toString() ?? '',
        rank: int.tryParse(item['序號']?.toString() ?? item['rank']?.toString() ?? '0') ?? 0,
        name: item['地點名稱']?.toString() ?? item['name']?.toString() ?? '',
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
      String targetUrl = routeUrl + '&limit=20000';
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      
      onProgress?.call('正在從雲端獲取最新班表...');
      const int timeoutSeconds = 15;
      String content;
      try {
        content = await _downloadWithProgress(onProgress, targetUrl, timeoutSeconds);
      } catch (e) {
        if (e is TimeoutException) {
          onProgress?.call('連線超過 $timeoutSeconds 秒已 Timeout，改用原內建資料...');
        } else {
          onProgress?.call('雲端連線失敗，切換至備援資產...');
        }
        content = await rootBundle.loadString('assets/taipei_route.json');
      }
      
      onProgress?.call('解析數據結構中...');
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
      onProgress?.call('台北市資料同步失敗。');
    }
  }

  Future<String> _downloadWithProgress(void Function(String)? onProgress, String url, int timeout) async {
    final request = http.Request('GET', Uri.parse(url));
    final streamedResponse = await _client.send(request).timeout(Duration(seconds: timeout));
    if (streamedResponse.statusCode != 200) throw Exception('HTTP Error');

    final int totalBytes = streamedResponse.contentLength ?? 0;
    int receivedBytes = 0;
    final List<int> bytes = [];

    await for (var chunk in streamedResponse.stream.timeout(Duration(seconds: timeout))) {
      bytes.addAll(chunk);
      receivedBytes += chunk.length;
      if (totalBytes > 0) {
        onProgress?.call('下載中: ${(receivedBytes / 1024).toStringAsFixed(1)} KB / ${(totalBytes / 1024).toStringAsFixed(1)} KB');
      } else {
        onProgress?.call('下載中: ${(receivedBytes / 1024).toStringAsFixed(1)} KB');
      }
    }
    return utf8.decode(bytes);
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      String targetUrl = truckUrl + '&limit=1000';
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        final List<dynamic> results = root['result']?['results'] ?? [];
        return results.map((item) => GarbageTruck(
          carNumber: item['車號']?.toString() ?? '未知',
          lineId: item['路線編號']?.toString() ?? '',
          location: item['位置描述']?.toString() ?? '',
          position: LatLng(double.tryParse(item['緯度']?.toString() ?? '0') ?? 0, double.tryParse(item['經度']?.toString() ?? '0') ?? 0),
          updateTime: DateTime.now(),
        )).toList();
      }
    } catch (_) {}
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'taipei');
    return points.map((p) => GarbageTruck(
      carNumber: '預定車', lineId: p.lineId, location: p.name, position: p.position, updateTime: DateTime.now(),
    )).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'taipei');
}
