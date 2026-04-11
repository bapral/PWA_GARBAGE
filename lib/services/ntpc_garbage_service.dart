/// [整體程式說明]
/// 本文件定義了新北市（NTPC）的垃圾清運服務實作。
/// 支援串流下載（Streamed Download）以即時顯示下載進度與筆數。

import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

import 'ntpc_garbage_service.dart';

class NtpcGarbageService extends BaseGarbageService {
  static const String apiUrl = 'https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/csv';
  static const String routeUrl = 'https://data.ntpc.gov.tw/api/datasets/edc3ad26-8ae7-4916-a00b-bc6048d19bf8/csv';

  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/csv, application/json',
    'Referer': 'https://data.ntpc.gov.tw/',
  };

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  NtpcGarbageService({required super.localSourceDir, http.Client? client}) 
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
    
    final String? storedVersion = await _dbService.getStoredVersion('ntpc');
    if (storedVersion == currentAppVersion && (await _dbService.hasData('ntpc'))) {
      onProgress?.call('新北市資料已就緒...');
      return;
    }

    onProgress?.call('正在初始化新北市資料同步...');
    
    bool apiSuccess = false;
    const int timeoutSeconds = 15;
    try {
      String targetUrl = routeUrl + '?size=100000';
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      apiSuccess = await _syncFromApiWithProgress(onProgress, customUrl: targetUrl, timeout: timeoutSeconds);
    } catch (e) {
      if (e is TimeoutException) {
        onProgress?.call('連線超過 $timeoutSeconds 秒已 Timeout，改用原內建資料...');
      } else {
        onProgress?.call('連線異常，正在切換至備援資產...');
      }
      DatabaseService.log('新北市 API 失敗: $e');
    }

    if (apiSuccess) {
      await _dbService.updateVersion(currentAppVersion, 'ntpc');
      onProgress?.call('新北市雲端同步成功！');
    } else {
      if (!apiSuccess) {
        // 若 apiSuccess 為 false 但沒進入 catch (例如 statusCode 錯誤)
        onProgress?.call('雲端連線失敗，正在載入內建資產...');
      }
      if (await _importFromLocalCSV(onProgress)) {
        await _dbService.updateVersion(currentAppVersion, 'ntpc');
        onProgress?.call('新北市內建資料載入完成。');
      }
    }
  }

  Future<bool> _syncFromApiWithProgress(void Function(String)? onProgress, {required String customUrl, required int timeout}) async {
    onProgress?.call('正在建立雲端連線...');
    final request = http.Request('GET', Uri.parse(customUrl));
    _headers.forEach((k, v) => request.headers[k] = v);
    
    final streamedResponse = await _client.send(request).timeout(Duration(seconds: timeout));
    
    if (streamedResponse.statusCode != 200) return false;

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

    onProgress?.call('下載完成，正在解析數據...');
    final String body = utf8.decode(bytes);
    final List<GarbageRoutePoint> allPoints = await compute(_parseCsvIsolate, _CsvParseInput(body.trim()));

    if (allPoints.isNotEmpty) {
      await _dbService.clearAllRoutePoints('ntpc');
      await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'ntpc', (saved, total) {
        onProgress?.call('資料庫寫入中: $saved / $total 筆');
      });
      return true;
    }
    return false;
  }

  Future<bool> _importFromLocalCSV(void Function(String)? onProgress) async {
    try {
      onProgress?.call('讀取內部資源中...');
      final String csvContent = await rootBundle.loadString('assets/ntpc_route.csv');
      final List<GarbageRoutePoint> allPoints = _parseCsvIsolate(_CsvParseInput(csvContent));
      
      if (allPoints.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'ntpc', (saved, total) {
          onProgress?.call('載入內部資料: $saved / $total 筆');
        });
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      String requestUrl = '$apiUrl?size=20000&_t=$timestamp';
      if (kIsWeb) {
        requestUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(requestUrl);
      }
      final response = await _client.get(Uri.parse(requestUrl), headers: _headers).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final List<List<dynamic>> rows = const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(response.body.trim());
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
              carNumber: row[idxCar].toString(), lineId: row[idxLineId].toString(), location: row[idxLoc].toString(),
              position: LatLng(double.tryParse(row[idxLat].toString()) ?? 0, double.tryParse(row[idxLng].toString()) ?? 0),
              updateTime: DateTime.tryParse(row[idxTime].toString()) ?? DateTime.now(),
            ));
          }
          return trucks;
        }
      }
    } catch (_) {}
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'ntpc');
    return points.map((p) => GarbageTruck(
      carNumber: '預定車', lineId: p.lineId, location: p.name, position: p.position, updateTime: DateTime.now(),
    )).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'ntpc');
}
