/// [整體程式說明]
/// 本文件定義了垃圾清運服務的基底架構以及新北市（NTPC）的具體實作。
/// [BaseGarbageService] 確立了城市服務的統一介面，支援多城市擴充。
/// [NtpcGarbageService] 則實作了新北市開放資料的 CSV 解析邏輯，
/// 包含即時動態 API、路線班表 API 以及本地 CSV 備援方案。
///
/// [執行順序說明]
/// 1. 呼叫 `syncDataIfNeeded`：比對版本後，優先從雲端 API 下載 CSV 路線資料。
/// 2. 若 API 逾時或失敗，則嘗試讀取本地 Assets 中的 CSV 檔案進行匯入。
/// 3. 解析過程中使用 `CsvToListConverter` 將字串轉換為 `GarbageRoutePoint` 並批次存入資料庫。

import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

/// [BaseGarbageService] 是所有城市垃圾清運服務的基底抽象類別。
abstract class BaseGarbageService {
  final String localSourceDir; 
  BaseGarbageService({required this.localSourceDir});
  Future<void> syncDataIfNeeded({void Function(String)? onProgress});
  Future<List<GarbageTruck>> fetchTrucks();
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute);
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId);
  void dispose();
}

/// 內部使用的解析封裝物件，用於 Isolate 溝通。
class _CsvParseInput {
  final String csvBody;
  const _CsvParseInput(this.csvBody);
}

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

    result.add(GarbageRoutePoint(
      lineId: row[idxLineId].toString(),
      lineName: idxLineName != -1 ? row[idxLineName].toString() : '',
      rank: idxRank != -1 ? (int.tryParse(row[idxRank].toString()) ?? 0) : i,
      name: idxName != -1 ? row[idxName].toString() : '',
      position: LatLng(
        double.tryParse(row[idxLat].toString()) ?? 0, 
        double.tryParse(row[idxLng].toString()) ?? 0
      ),
      arrivalTime: row[idxTime].toString(),
    ));
  }
  return result;
}

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

    onProgress?.call('正在更新新北市路線資料...');
    
    // 優先嘗試 API，但加入嚴格的逾時保護 (10秒)
    bool apiSuccess = false;
    try {
      String targetUrl = routeUrl + '?size=100000';
      if (kIsWeb) {
        targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      }
      apiSuccess = await _syncFromApi(onProgress, customUrl: targetUrl);
    } catch (e) {
      DatabaseService.log('新北市 API 連線失敗或逾時，轉向本地資產: $e');
    }

    if (apiSuccess) {
      await _dbService.updateVersion(currentAppVersion, 'ntpc');
      onProgress?.call('新北市路線同步完成 (雲端)。');
    } else {
      onProgress?.call('正在載入內建清運班表資料 (Assets)...');
      if (await _importFromLocalCSV(onProgress)) {
        await _dbService.updateVersion(currentAppVersion, 'ntpc');
        onProgress?.call('新北市路線載入完成。');
      } else {
        onProgress?.call('載入失敗，地圖可能不顯示完整路線。');
      }
    }
  }

  Future<bool> _syncFromApi(void Function(String)? onProgress, {required String customUrl}) async {
    try {
      onProgress?.call('連線至政府 API...');
      final response = await _client.get(Uri.parse(customUrl), headers: _headers)
          .timeout(const Duration(seconds: 12)); // 設定 12 秒逾時
      
      if (response.statusCode == 200) {
        onProgress?.call('獲取成功，解析中...');
        final List<GarbageRoutePoint> allPoints = await compute(_parseCsvIsolate, _CsvParseInput(response.body.trim()));

        if (allPoints.isNotEmpty) {
          await _dbService.clearAllRoutePoints('ntpc');
          const int batchSize = 1000; // 降低批次大小以利 Web 穩定性
          for (int i = 0; i < allPoints.length; i += batchSize) {
            int end = (i + batchSize < allPoints.length) ? i + batchSize : allPoints.length;
            await _dbService.saveRoutePoints(allPoints.sublist(i, end), 'ntpc');
            onProgress?.call('資料儲存中: ${((end/allPoints.length)*100).toInt()}%');
          }
          return true;
        }
      }
    } catch (e) {
      DatabaseService.log('新北市 API 同步異常', error: e);
    }
    return false;
  }

  Future<bool> _importFromLocalCSV(void Function(String)? onProgress) async {
    try {
      String csvContent;
      try {
        csvContent = await rootBundle.loadString('assets/ntpc_route.csv');
      } catch (e) {
        return false;
      }

      final List<GarbageRoutePoint> allPoints = _parseCsvIsolate(_CsvParseInput(csvContent));
      if (allPoints.isEmpty) return false;

      await _dbService.clearAllRoutePoints('ntpc');
      const int batchSize = 1000;
      for (int i = 0; i < allPoints.length; i += batchSize) {
        int end = (i + batchSize < allPoints.length) ? i + batchSize : allPoints.length;
        await _dbService.saveRoutePoints(allPoints.sublist(i, end), 'ntpc');
        onProgress?.call('正在載入本地資料: ${((end/allPoints.length)*100).toInt()}%');
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      String requestUrl = '$apiUrl?size=20000&_t=$timestamp';
      if (kIsWeb) {
        requestUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(requestUrl);
      }
      final response = await _client.get(Uri.parse(requestUrl), headers: _headers).timeout(const Duration(seconds: 8));
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
