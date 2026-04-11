/// [整體程式說明]
/// 本文件定義了台南市（Tainan）的垃圾清運服務實作。
/// 支援串流下載以即時顯示下載進度與筆數回報。

import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'base_garbage_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

class TainanGarbageService extends BaseGarbageService {
  static const String dynamicApiUrl = 'https://soa.tainan.gov.tw/Api/Service/Get/2c8a70d5-06f2-4353-9e92-c40d33bcd969';
  static const String routeApiUrl = 'https://soa.tainan.gov.tw/Api/Service/Get/84df8cd6-8741-41ed-919c-5105a28ecd6d';

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  TainanGarbageService({required super.localSourceDir, http.Client? client}) 
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
    
    final String? storedVersion = await _dbService.getStoredVersion('tainan');
    if (storedVersion == currentAppVersion && (await _dbService.hasData('tainan'))) {
      onProgress?.call('台南市資料已就緒...');
      return;
    }

    onProgress?.call('正在初始化台南市資料更新...');
    
    bool apiSuccess = false;
    const int timeoutSeconds = 20;
    try {
      String targetUrl = routeApiUrl;
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      
      onProgress?.call('正在從雲端獲取班表...');
      final String content = await _downloadWithProgress(onProgress, targetUrl, timeoutSeconds);
      
      onProgress?.call('解析數據結構中...');
      final Map<String, dynamic> data = json.decode(content);
      final List<dynamic> records = data['data'] ?? [];
      
      if (records.isNotEmpty) {
        List<GarbageRoutePoint> allPoints = [];
        for (int i = 0; i < records.length; i++) {
          final item = records[i];
          final double? lat = double.tryParse(item['LATITUDE']?.toString() ?? '');
          final double? lng = double.tryParse(item['LONGITUDE']?.toString() ?? '');
          if (lat != null && lng != null) {
            allPoints.add(GarbageRoutePoint(
              lineId: item['ROUTEID']?.toString() ?? '',
              lineName: '${item['AREA'] ?? ''} ${item['ROUTEID'] ?? ''}',
              rank: int.tryParse(item['ROUTEORDER']?.toString() ?? '') ?? i,
              name: item['POINTNAME']?.toString() ?? '未知站點',
              position: LatLng(lat, lng),
              arrivalTime: item['TIME']?.toString() ?? '',
            ));
          }
        }
        
        if (allPoints.isNotEmpty) {
          onProgress?.call('正在存入資料庫...');
          await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'tainan', (saved, total) {
            onProgress?.call('資料庫寫入中: $saved / $total 筆');
          });
          apiSuccess = true; // 標記成功，避免進入備援邏輯
        }
      }
    } catch (e) {
      if (e is TimeoutException) {
        onProgress?.call('下載超過 $timeoutSeconds 秒已 Timeout，改用原內建資料...');
      } else {
        onProgress?.call('雲端連線失敗，正在載入內建資產...');
      }
      DatabaseService.log('Tainan Sync Error', error: e);
    }

    if (apiSuccess) {
      await _dbService.updateVersion(currentAppVersion, 'tainan');
      onProgress?.call('台南市同步完成！');
    } else {
      onProgress?.call('嘗試從內建資產載入...');
      if (await _importFromLocalJson(onProgress)) {
        await _dbService.updateVersion(currentAppVersion, 'tainan');
        onProgress?.call('台南市內建資料載入成功。');
      } else {
        onProgress?.call('台南市資料載入失敗。');
      }
    }
  }

  Future<String> _downloadWithProgress(void Function(String)? onProgress, String url, int timeout) async {
    final request = http.Request('GET', Uri.parse(url));
    final streamedResponse = await _client.send(request).timeout(Duration(seconds: timeout));
    if (streamedResponse.statusCode != 200) throw Exception('HTTP Error: ${streamedResponse.statusCode}');

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
      final String content = await rootBundle.loadString('assets/tainan_route.json');
      final Map<String, dynamic> data = json.decode(content);
      final List<dynamic> records = data['data'] ?? [];
      
      List<GarbageRoutePoint> allPoints = [];
      for (int i = 0; i < records.length; i++) {
        final item = records[i];
        final double? lat = double.tryParse(item['LATITUDE']?.toString() ?? '');
        final double? lng = double.tryParse(item['LONGITUDE']?.toString() ?? '');
        if (lat != null && lng != null) {
          allPoints.add(GarbageRoutePoint(
            lineId: item['ROUTEID']?.toString() ?? '',
            lineName: '${item['AREA'] ?? ''} ${item['ROUTEID'] ?? ''}',
            rank: int.tryParse(item['ROUTEORDER']?.toString() ?? '') ?? i,
            name: item['POINTNAME']?.toString() ?? '未知站點',
            position: LatLng(lat, lng),
            arrivalTime: item['TIME']?.toString() ?? '',
          ));
        }
      }
      
      if (allPoints.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'tainan', (saved, total) {
          onProgress?.call('載入內建資料: $saved / $total 筆');
        });
        return true;
      }
    } catch (e) {
      DatabaseService.log('Tainan Asset Import Error', error: e);
    }
    return false;
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      String targetUrl = dynamicApiUrl;
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        final List<dynamic> records = data['data'] ?? [];
        return records.map((item) => GarbageTruck(
          carNumber: item['car']?.toString() ?? '未知',
          lineId: item['linid']?.toString() ?? '',
          location: item['location']?.toString() ?? '行駛中',
          position: LatLng(double.tryParse(item['y']?.toString() ?? '0') ?? 0, double.tryParse(item['x']?.toString() ?? '0') ?? 0),
          updateTime: DateTime.now(),
          isRealTime: true,
        )).toList();
      }
    } catch (_) {}
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'tainan');
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
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'tainan');
}
