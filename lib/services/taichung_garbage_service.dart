/// [整體程式說明]
/// 本文件定義了台中市（Taichung）的垃圾清運服務實作。
/// 支援串流下載以顯示下載進度，並提供明確的資料庫儲存筆數回報。

import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'ntpc_garbage_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

class TaichungGarbageService extends BaseGarbageService {
  static const String routeApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=68d1a87f-7baa-4b50-8408-c36a3a7eda68';
  static const String dynamicApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc';

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  TaichungGarbageService({required super.localSourceDir, http.Client? client}) 
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

    final String? storedVersion = await _dbService.getStoredVersion('taichung');
    if (storedVersion == currentAppVersion && (await _dbService.hasData('taichung'))) {
      onProgress?.call('台中市資料已就緒...');
      return;
    }

    onProgress?.call('正在初始化台中市資料更新...');
    
    try {
      // 步驟一：下載即時座標快照
      onProgress?.call('正在獲取 API 動態快照...');
      String targetDynamicUrl = '$dynamicApiUrl&limit=20000';
      if (kIsWeb) {
        targetDynamicUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetDynamicUrl);
      }
      
      final dynamicResponse = await _client.get(Uri.parse(targetDynamicUrl)).timeout(const Duration(seconds: 10));
      Map<String, LatLng> carPositions = {};
      if (dynamicResponse.statusCode == 200) {
        final List<dynamic> dynamicData = json.decode(dynamicResponse.body);
        for (var item in dynamicData) {
          final String carNo = item['car']?.toString() ?? '';
          final double? lng = double.tryParse(item['X']?.toString() ?? '');
          final double? lat = double.tryParse(item['Y']?.toString() ?? '');
          if (carNo.isNotEmpty && lat != null && lng != null) {
            carPositions[carNo] = LatLng(lat, lng);
          }
        }
      }

      // 步驟二：串流下載班表 JSON (如果雲端可用)
      onProgress?.call('正在從雲端下載班表資產...');
      String content;
      bool apiSuccess = false;
      try {
        content = await _downloadWithProgress(onProgress, routeApiUrl);
        apiSuccess = true;
      } catch (e) {
        onProgress?.call('雲端下載失敗，切換至內建資產...');
        content = await rootBundle.loadString('assets/taichung_route.json');
      }

      onProgress?.call('解析數據結構中...');
      final List<dynamic> scheduleData = json.decode(content);
      
      List<GarbageRoutePoint> allPoints = [];
      int dayOfWeek = DateTime.now().weekday;
      
      for (int i = 0; i < scheduleData.length; i++) {
        final item = scheduleData[i];
        final String carNo = item['car_licence']?.toString() ?? '';
        String arrivalTime = item['g_d${dayOfWeek}_time_s']?.toString() ?? '';
        if (arrivalTime.isEmpty) {
          for (int d = 1; d <= 7; d++) {
            arrivalTime = item['g_d${d}_time_s']?.toString() ?? '';
            if (arrivalTime.isNotEmpty) break;
          }
        }
        if (arrivalTime.isEmpty) continue;

        LatLng pos = carPositions[carNo] ?? const LatLng(24.147, 120.673);
        allPoints.add(GarbageRoutePoint(
          lineId: carNo,
          lineName: '${item['area'] ?? ''}${item['village'] ?? ''} ($carNo)',
          rank: i,
          name: item['caption']?.toString() ?? '未知站點',
          position: pos,
          arrivalTime: arrivalTime,
        ));
      }
      
      onProgress?.call('正在儲存至資料庫...');
      await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'taichung', (saved, total) {
        onProgress?.call('資料庫寫入中: $saved / $total 筆');
      });
      
      await _dbService.updateVersion(currentAppVersion, 'taichung');
      onProgress?.call('台中市同步完成！');
      
    } catch (e) {
      onProgress?.call('同步失敗: $e');
    }
  }

  Future<String> _downloadWithProgress(void Function(String)? onProgress, String url) async {
    String targetUrl = url;
    if (kIsWeb) {
      targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(url);
    }
    
    final request = http.Request('GET', Uri.parse(targetUrl));
    final streamedResponse = await _client.send(request).timeout(const Duration(seconds: 20));
    
    if (streamedResponse.statusCode != 200) throw Exception('API Error');

    final int totalBytes = streamedResponse.contentLength ?? 0;
    int receivedBytes = 0;
    final List<int> bytes = [];

    await for (var chunk in streamedResponse.stream) {
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
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      String targetUrl = '$dynamicApiUrl&limit=20000&_t=$timestamp';
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final List<dynamic> results = json.decode(response.body);
        return results.map((item) {
          final String carNo = item['car']?.toString() ?? '未知車號';
          final String latStr = item['Y']?.toString() ?? '0';
          final String lonStr = item['X']?.toString() ?? '0';
          return GarbageTruck(
            carNumber: carNo, lineId: item['lineid']?.toString() ?? '', location: item['location']?.toString() ?? '移動中',
            position: LatLng(double.tryParse(latStr) ?? 0, double.tryParse(lonStr) ?? 0),
            updateTime: DateTime.now(),
          );
        }).toList();
      }
    } catch (_) {}
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'taichung');
    return points.map((p) => GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: '${p.lineName} - ${p.name}', position: p.position, updateTime: DateTime.now())).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'taichung');
}
