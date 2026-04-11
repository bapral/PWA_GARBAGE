/// [整體程式說明]
/// 本文件定義了新北市（NTPC）的垃圾清運服務實作。
/// 遵循 GARBAGE_DATA_GUIDE.md 實作安全性驗證、效能解析與髒資料過濾。

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

import 'base_garbage_service.dart';
import '../utils/time_utils.dart';

/// 在獨立 Isolate 中執行的 CSV 解析函式。
List<GarbageRoutePoint> _parseCsvIsolate(_CsvParseInput input) {
  final List<List<dynamic>> fields = const CsvToListConverter(
    shouldParseNumbers: false, 
    eol: '\n'
  ).convert(input.csvBody);

  if (fields.length <= 1) return [];

  final header = fields[0].map((e) => e.toString().toLowerCase().trim()).toList();
  int idxLineId = header.indexOf('lineid');
  int idxLat = header.indexOf('latitude');
  int idxLng = header.indexOf('longitude');
  int idxTime = header.indexOf('time');
  int idxLineName = header.indexOf('linename');
  int idxName = header.indexOf('name');
  int idxRank = header.indexOf('rank');

  List<GarbageRoutePoint> result = [];
  for (int i = 1; i < fields.length; i++) {
    final row = fields[i];
    if (row.length < 4) continue;

    final double lat = double.tryParse(row[idxLat].toString()) ?? 0;
    final double lng = double.tryParse(row[idxLng].toString()) ?? 0;

    // [指南要求]：過濾座標異常的髒資料 (範圍: 緯度 22-26, 經度 120-122)
    if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;

    result.add(GarbageRoutePoint(
      lineId: row[idxLineId].toString(),
      lineName: idxLineName != -1 ? row[idxLineName].toString() : '',
      rank: idxRank != -1 ? (int.tryParse(row[idxRank].toString()) ?? 0) : i,
      name: idxName != -1 ? row[idxName].toString() : '',
      position: LatLng(lat, lng),
      arrivalTime: TimeUtils.formatTo24Hour(row[idxTime].toString()),
    ));
  }
  return result;
}

class _CsvParseInput {
  final String csvBody;
  const _CsvParseInput(this.csvBody);
}

class NtpcGarbageService extends BaseGarbageService {
  static const String apiUrl = 'https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/csv';
  static const String routeUrl = 'https://data.ntpc.gov.tw/api/datasets/edc3ad26-8ae7-4916-a00b-bc6048d19bf8/csv';

  // [指南要求]：必須包含特定 User-Agent 與 Referer 繞過 403 限制
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
    }

    if (apiSuccess) {
      await _dbService.updateVersion(currentAppVersion, 'ntpc');
      onProgress?.call('新北市雲端同步成功！');
    } else {
      if (await _importFromLocalCSV(onProgress)) {
        await _dbService.updateVersion(currentAppVersion, 'ntpc');
        onProgress?.call('新北市內建資料載入成功。');
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
      onProgress?.call('下載中: ${(receivedBytes / 1024).toStringAsFixed(1)} KB${totalBytes > 0 ? " / ${(totalBytes / 1024).toStringAsFixed(1)} KB" : ""}');
    }

    onProgress?.call('下載完成，正在背景解析 CSV...');
    final String body = utf8.decode(bytes);
    // [指南要求]：使用背景執行緒解析大筆 CSV 資料
    final List<GarbageRoutePoint> allPoints = await compute(_parseCsvIsolate, _CsvParseInput(body.trim()));

    if (allPoints.isNotEmpty) {
      await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'ntpc', (saved, total) {
        onProgress?.call('資料庫寫入中: $saved / $total 筆');
      });
      return true;
    }
    return false;
  }

  Future<bool> _importFromLocalCSV(void Function(String)? onProgress) async {
    try {
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
            final double lat = double.tryParse(row[idxLat].toString()) ?? 0;
            final double lng = double.tryParse(row[idxLng].toString()) ?? 0;
            // 座標合法性檢查
            if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;

            trucks.add(GarbageTruck(
              carNumber: row[idxCar].toString(), lineId: row[idxLineId].toString(), location: row[idxLoc].toString(),
              position: LatLng(lat, lng),
              updateTime: DateTime.tryParse(row[idxTime].toString()) ?? DateTime.now(),
              isRealTime: true,
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
      isRealTime: false,
    )).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'ntpc');
}
