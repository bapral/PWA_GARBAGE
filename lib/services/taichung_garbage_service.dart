/// [整體程式說明]
/// 本文件定義了台中市（Taichung）的垃圾清運服務實作。
/// 遵循 GARBAGE_DATA_GUIDE.md 實作 ISO T 時間格式化、車牌映射與座標範圍驗證。

import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'base_garbage_service.dart';
import '../utils/time_utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

class TaichungGarbageService extends BaseGarbageService {
  static const String routeApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=68d1a87f-7baa-4b50-8408-c36a3a7eda68';
  static const String dynamicApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc';

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  TaichungGarbageService({required super.localSourceDir, http.Client? client}) : _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress}) async {
    final bool hasData = await _dbService.hasData('taichung');

    if (!force) {
      if (!hasData) {
        onProgress?.call('初次啟動，正在快速載入台中市預設班表...');
        await _importFromLocalAssets(onProgress);
      }
      return;
    }

    onProgress?.call('正在更新台中市資料...');
    try {
      onProgress?.call('正在獲取 API 動態快照...');
      String targetDynamicUrl = '$dynamicApiUrl&limit=20000';
      if (kIsWeb) targetDynamicUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetDynamicUrl);
      final dynamicResponse = await _client.get(Uri.parse(targetDynamicUrl)).timeout(const Duration(seconds: 10));
      Map<String, LatLng> carPositions = {};
      if (dynamicResponse.statusCode == 200) {
        final List<dynamic> dynamicData = json.decode(dynamicResponse.body);
        for (var item in dynamicData) {
          final String carNo = item['car']?.toString() ?? '';
          final double? lng = double.tryParse(item['X']?.toString() ?? '');
          final double? lat = double.tryParse(item['Y']?.toString() ?? '');
          if (carNo.isNotEmpty && lat != null && lng != null) {
            if (lat >= 22 && lat <= 26 && lng >= 120 && lng <= 122) carPositions[carNo] = LatLng(lat, lng);
          }
        }
      }

      onProgress?.call('正在從雲端下載班表...');
      final String content = await _downloadWithProgress(onProgress, routeApiUrl, 20);
      final List<GarbageRoutePoint> allPoints = _parseTaichungJson(content, carPositions);
      
      if (allPoints.isNotEmpty) {
        onProgress?.call('正在儲存至資料庫...');
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'taichung', (saved, total) => onProgress?.call('資料庫寫入中: $saved / $total 筆'));
        onProgress?.call('台中市同步完成！');
      }
    } catch (e) {
      onProgress?.call('同步異常，改從內建資料恢復...');
      await _importFromLocalAssets(onProgress);
    }
  }

  List<GarbageRoutePoint> _parseTaichungJson(String content, Map<String, LatLng> carPositions) {
    final List<dynamic> scheduleData = json.decode(content);
    List<GarbageRoutePoint> allPoints = [];
    int dayOfWeek = DateTime.now().weekday;
    for (int i = 0; i < scheduleData.length; i++) {
      final item = scheduleData[i];
      final String carNo = item['car_licence']?.toString() ?? '';
      String rawTime = item['g_d${dayOfWeek}_time_s']?.toString() ?? '';
      if (rawTime.isEmpty) {
        for (int d = 1; d <= 7; d++) {
          rawTime = item['g_d${d}_time_s']?.toString() ?? '';
          if (rawTime.isNotEmpty) break;
        }
      }
      if (rawTime.isEmpty) continue;
      allPoints.add(GarbageRoutePoint(
        lineId: carNo, lineName: '${item['area'] ?? ''}${item['village'] ?? ''} ($carNo)',
        rank: i, name: item['caption']?.toString() ?? '未知站點',
        position: carPositions[carNo] ?? const LatLng(24.147, 120.673),
        arrivalTime: TimeUtils.formatTo24Hour(rawTime),
      ));
    }
    return allPoints;
  }

  Future<void> _importFromLocalAssets(void Function(String)? onProgress) async {
    try {
      final String content = await rootBundle.loadString('assets/taichung_route.json');
      final List<GarbageRoutePoint> allPoints = _parseTaichungJson(content, {});
      if (allPoints.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'taichung', (saved, total) => onProgress?.call('載入預設點位: $saved / $total 筆'));
      }
    } catch (_) {}
  }

  Future<String> _downloadWithProgress(void Function(String)? onProgress, String url, int timeout) async {
    String t = url; if (kIsWeb) t = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(url);
    final req = http.Request('GET', Uri.parse(t));
    final res = await _client.send(req).timeout(Duration(seconds: timeout));
    if (res.statusCode != 200) throw Exception('API Error');
    int received = 0; final List<int> bytes = [];
    await for (var chunk in res.stream.timeout(Duration(seconds: timeout))) {
      bytes.addAll(chunk); received += chunk.length;
      onProgress?.call('下載中: ${(received / 1024).toStringAsFixed(1)} KB');
    }
    return utf8.decode(bytes);
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      String t = '$dynamicApiUrl&limit=20000&_t=${DateTime.now().millisecondsSinceEpoch}';
      if (kIsWeb) t = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(t);
      final res = await _client.get(Uri.parse(t)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final List<dynamic> results = json.decode(res.body);
        return results.map((item) {
          final String carNo = item['car']?.toString() ?? '未知車號';
          final double lat = double.tryParse(item['Y']?.toString() ?? '0') ?? 0;
          final double lng = double.tryParse(item['X']?.toString() ?? '0') ?? 0;
          DateTime updateTime = DateTime.now();
          final String? timeStr = item['time']?.toString();
          if (timeStr != null && timeStr.contains('T')) {
            try {
              final String f = '${timeStr.substring(0, 4)}-${timeStr.substring(4, 6)}-${timeStr.substring(6, 8)} ${timeStr.substring(9, 11)}:${timeStr.substring(11, 13)}:${timeStr.substring(13, 15)}';
              updateTime = DateTime.tryParse(f) ?? DateTime.now();
            } catch (_) {}
          }
          return GarbageTruck(carNumber: carNo, lineId: carNo, location: item['location']?.toString() ?? '移動中', position: LatLng(lat, lng), updateTime: updateTime, isRealTime: true);
        }).where((t) => t.position.latitude >= 22 && t.position.latitude <= 26).toList();
      }
    } catch (_) {}
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'taichung');
    return points.map((p) => GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: '${p.lineName} - ${p.name}', position: p.position, updateTime: DateTime.now(), isRealTime: false)).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'taichung');
}
