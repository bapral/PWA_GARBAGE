/// [整體程式說明]
/// 本文件定義了新北市（NTPC）的垃圾清運服務實作。
/// 支援手動強制更新（API）與啟動自動載入（Assets）。

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
  final List<List<dynamic>> fields = const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(input.csvBody);
  if (fields.length <= 1) return [];
  final header = fields[0].map((e) => e.toString().toLowerCase().trim()).toList();
  int idxLineId = header.indexOf('lineid'); int idxLat = header.indexOf('latitude');
  int idxLng = header.indexOf('longitude'); int idxTime = header.indexOf('time');
  int idxLineName = header.indexOf('linename'); int idxName = header.indexOf('name');
  int idxRank = header.indexOf('rank');

  List<GarbageRoutePoint> result = [];
  for (int i = 1; i < fields.length; i++) {
    final row = fields[i]; if (row.length < 4) continue;
    final double lat = double.tryParse(row[idxLat].toString()) ?? 0;
    final double lng = double.tryParse(row[idxLng].toString()) ?? 0;
    if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;
    result.add(GarbageRoutePoint(
      lineId: row[idxLineId].toString(), lineName: idxLineName != -1 ? row[idxLineName].toString() : '',
      rank: idxRank != -1 ? (int.tryParse(row[idxRank].toString()) ?? 0) : i,
      name: idxName != -1 ? row[idxName].toString() : '', position: LatLng(lat, lng),
      arrivalTime: TimeUtils.formatTo24Hour(row[idxTime].toString()),
    ));
  }
  return result;
}

class _CsvParseInput { final String csvBody; const _CsvParseInput(this.csvBody); }

class NtpcGarbageService extends BaseGarbageService {
  static const String apiUrl = 'https://data.ntpc.gov.tw/api/datasets/28ab4122-60e1-4065-98e5-abccb69aaca6/csv';
  static const String routeUrl = 'https://data.ntpc.gov.tw/api/datasets/edc3ad26-8ae7-4916-a00b-bc6048d19bf8/csv';
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0', 'Accept': 'text/csv, application/json', 'Referer': 'https://data.ntpc.gov.tw/',
  };

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  NtpcGarbageService({required super.localSourceDir, http.Client? client}) : _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress}) async {
    final bool hasData = await _dbService.hasData('ntpc');

    if (!force) {
      // [模式 1: 自動載入] 僅在沒資料時從內建 Assets 載入，不碰網路
      if (!hasData) {
        onProgress?.call('初次啟動，正在快速載入內建班表...');
        await _importFromLocalCSV(onProgress);
      }
      return;
    }

    // [模式 2: 強制更新] 僅在按下按鈕時觸發，連線政府 API
    onProgress?.call('正在連線新北市政府 API 獲取最新班表...');
    bool apiSuccess = false;
    try {
      String targetUrl = routeUrl + '?size=100000';
      if (kIsWeb) targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      apiSuccess = await _syncFromApiWithProgress(onProgress, customUrl: targetUrl, timeout: 15);
    } catch (_) {}

    if (!apiSuccess) {
      onProgress?.call('雲端同步失敗，改從內建資料恢復...');
      await _importFromLocalCSV(onProgress);
    }
  }

  Future<bool> _syncFromApiWithProgress(void Function(String)? onProgress, {required String customUrl, required int timeout}) async {
    final request = http.Request('GET', Uri.parse(customUrl));
    _headers.forEach((k, v) => request.headers[k] = v);
    final streamedResponse = await _client.send(request).timeout(Duration(seconds: timeout));
    if (streamedResponse.statusCode != 200) return false;
    final int totalBytes = streamedResponse.contentLength ?? 0;
    int receivedBytes = 0; final List<int> bytes = [];
    await for (var chunk in streamedResponse.stream.timeout(Duration(seconds: timeout))) {
      bytes.addAll(chunk); receivedBytes += chunk.length;
      onProgress?.call('下載中: ${(receivedBytes / 1024).toStringAsFixed(1)} KB${totalBytes > 0 ? " / ${(totalBytes / 1024).toStringAsFixed(1)} KB" : ""}');
    }
    final List<GarbageRoutePoint> allPoints = await compute(_parseCsvIsolate, _CsvParseInput(utf8.decode(bytes).trim()));
    if (allPoints.isNotEmpty) {
      await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'ntpc', (saved, total) => onProgress?.call('資料庫更新中: $saved / $total 筆'));
      return true;
    }
    return false;
  }

  Future<bool> _importFromLocalCSV(void Function(String)? onProgress) async {
    try {
      final String csvContent = await rootBundle.loadString('assets/ntpc_route.csv');
      final List<GarbageRoutePoint> allPoints = _parseCsvIsolate(_CsvParseInput(csvContent));
      if (allPoints.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(allPoints, 'ntpc', (saved, total) => onProgress?.call('正在載入預設點位: $saved / $total 筆'));
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      String req = '$apiUrl?size=20000&_t=${DateTime.now().millisecondsSinceEpoch}';
      if (kIsWeb) req = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(req);
      final res = await _client.get(Uri.parse(req), headers: _headers).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final List<List<dynamic>> rows = const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(res.body.trim());
        if (rows.length > 1) {
          final h = rows[0].map((e) => e.toString().toLowerCase().trim()).toList();
          List<GarbageTruck> trucks = [];
          for (int i = 1; i < rows.length; i++) {
            final r = rows[i]; if (row.length < 5) continue;
            final double lat = double.tryParse(r[h.indexOf('latitude')].toString()) ?? 0;
            final double lng = double.tryParse(r[h.indexOf('longitude')].toString()) ?? 0;
            if (lat < 22 || lat > 26 || lng < 120 || lng > 122) continue;
            trucks.add(GarbageTruck(
              carNumber: r[h.indexOf('car')].toString(), lineId: r[h.indexOf('lineid')].toString(), location: r[h.indexOf('location')].toString(),
              position: LatLng(lat, lng), updateTime: DateTime.tryParse(r[h.indexOf('time')].toString()) ?? DateTime.now(), isRealTime: true,
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
    return points.map((p) => GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: p.name, position: p.position, updateTime: DateTime.now(), isRealTime: false)).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async => await _dbService.getRoutePoints(lineId, 'ntpc');
}
