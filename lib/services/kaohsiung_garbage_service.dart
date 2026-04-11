/// [整體程式說明]
/// 本文件定義了高雄市（Kaohsiung）的垃圾清運服務實作。
/// 支援手動強制更新（API）與啟動自動載入（Assets）。

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
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

class KaohsiungGarbageService extends BaseGarbageService {
  static const List<String> routeApiUrls = [
    'https://api.kcg.gov.tw/api/service/get/7c80a17b-ba6c-4a07-811e-feae30ff9210',
    'https://api.kcg.gov.tw/ServiceList/GetFullList/074c805a-00e1-4fc5-b5f8-b2f4d6b64aa4'
  ];

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  KaohsiungGarbageService({required super.localSourceDir, http.Client? client}) 
      : _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress}) async {
    final bool hasData = await _dbService.hasData('kaohsiung');

    if (!force) {
      if (!hasData) {
        onProgress?.call('初次啟動，正在快速載入高雄市預設班表...');
        await _importFromLocalJson(onProgress);
      }
      return;
    }

    onProgress?.call('正在連線高雄市政府 API 獲取最新班表...');
    
    bool apiSuccess = false;
    const int timeoutSeconds = 20;

    for (String url in routeApiUrls) {
      try {
        String targetUrl = url;
        if (kIsWeb) {
          targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(url);
        }
        
        onProgress?.call('連線至高雄 API (${routeApiUrls.indexOf(url) + 1}/${routeApiUrls.length})...');
        final String content = await _downloadWithProgress(onProgress, targetUrl, timeoutSeconds);
        
        onProgress?.call('解析數據結構中...');
        final List<GarbageRoutePoint> allPoints = _parseKaohsiungJson(content);

        if (allPoints.isNotEmpty) {
          onProgress?.call('正在寫入資料庫...');
          await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'kaohsiung', (saved, total) {
            onProgress?.call('資料庫寫入中: $saved / $total 筆');
          });
          apiSuccess = true;
          break;
        }
      } catch (e) {
        if (e is TimeoutException) {
          onProgress?.call('連線超過 $timeoutSeconds 秒已 Timeout...');
        }
        DatabaseService.log('Kaohsiung Sync API Attempt Failed', error: e);
      }
    }

    if (apiSuccess) {
      await _dbService.updateVersion('manual_sync', 'kaohsiung');
      onProgress?.call('高雄市同步完成！');
    } else {
      onProgress?.call('雲端連線失敗，正在載入內部備援資料...');
      if (await _importFromLocalJson(onProgress)) {
        await _dbService.updateVersion('asset_sync', 'kaohsiung');
        onProgress?.call('高雄市內建資料載入成功。');
      }
    }
  }

  List<GarbageRoutePoint> _parseKaohsiungJson(String content) {
    final dynamic decoded = json.decode(content);
    List<dynamic> records = [];
    if (decoded is List) records = decoded;
    else if (decoded is Map) records = decoded['data'] ?? decoded['records'] ?? [];

    List<GarbageRoutePoint> points = [];
    for (int i = 0; i < records.length; i++) {
      final item = records[i];
      double? lat; double? lng;
      final String coordStr = (item['經緯度'] ?? item['coordinate'] ?? '').toString();
      if (coordStr.contains(',')) {
        final parts = coordStr.split(',');
        lat = double.tryParse(parts[0].trim());
        lng = double.tryParse(parts[1].trim());
      } else {
        lat = double.tryParse((item['緯度'] ?? item['latitude'] ?? '0').toString());
        lng = double.tryParse((item['經度'] ?? item['longitude'] ?? '0').toString());
      }
      if (lat == null || lng == null || lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;

      final String lineId = (item['清運路線名稱'] ?? item['路線名稱'] ?? item['車次'] ?? item['lineid'] ?? '未知').toString();
      final String area = (item['行政區'] ?? item['town'] ?? '').toString();
      final String name = (item['停留地點'] ?? item['停留點'] ?? item['caption'] ?? '未知站點').toString();
      String timeRaw = (item['停留時間'] ?? item['停留時段'] ?? item['time'] ?? '').toString();

      points.add(GarbageRoutePoint(
        lineId: lineId, lineName: area.isNotEmpty ? '$area $lineId' : lineId, rank: i,
        name: name, position: LatLng(lat, lng), arrivalTime: TimeUtils.formatTo24Hour(timeRaw),
      ));
    }
    return points;
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
      final String content = await rootBundle.loadString('assets/kaohsiung_route.json');
      final List<GarbageRoutePoint> allPoints = _parseKaohsiungJson(content);
      if (allPoints.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'kaohsiung', (saved, total) => onProgress?.call('載入預設點位: $saved / $total 筆'));
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async => await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'kaohsiung');
    return points.map((p) => GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: p.name, position: p.position, updateTime: DateTime.now(), isRealTime: false)).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'kaohsiung');
}
