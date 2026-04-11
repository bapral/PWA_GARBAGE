/// [整體程式說明]
/// 本文件定義了台中市（Taichung）的垃圾清運服務實作。
/// 核心邏輯：
/// 1. 唯一識別碼：以「車牌號碼 (car_licence)」作為動態與靜態資料的映射紐帶。
/// 2. ISO T 解析：支援 "20240411T093000" 這種包含日期與 T 字元的時間格式。
/// 3. 週循環排程：自動判定當前星期幾，若該點位當天不收運，則找出一週內最近一次收運的時間。
/// 4. 混合資料源：靜態班表 (rid=68d1a87f...) + 動態 API (rid=c923ad20...)。

import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'base_garbage_service.dart';
import '../utils/time_utils.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

class TaichungGarbageService extends BaseGarbageService {
  // 台中市定時定點收運地點 API
  static const String routeApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=68d1a87f-7baa-4b50-8408-c36a3a7eda68';
  // 台中市垃圾車即時動態 API
  static const String dynamicApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc';

  // [重要] 資產版本號，用於強制更新本地 SQLite 資料庫
  static const String requiredAssetVersion = '20260411_v3'; 

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  TaichungGarbageService({required super.localSourceDir, http.Client? client}) : _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress}) async {
    final String? storedVersion = await _dbService.getStoredVersion('taichung');
    final int currentCount = await _dbService.getTotalCount('taichung');

    if (!force && storedVersion == requiredAssetVersion && currentCount > 10000) {
      return;
    }

    onProgress?.call('正在同步台中市最新班表資料...');
    bool apiSuccess = false;
    try {
      // 1. 下載班表 JSON ( rid=68d1... )
      String targetUrl = routeApiUrl;
      if (kIsWeb) targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final String body = utf8.decode(response.bodyBytes);
        final List<GarbageRoutePoint> allPoints = await compute(_parseTaichungScheduleIsolate, body);
        
        if (allPoints.isNotEmpty) {
          onProgress?.call('正在更新資料庫 (${allPoints.length} 筆)...');
          await _dbService.clearAndSaveRoutePointsWithProgress(
            allPoints, 
            'taichung', 
            (saved, total) => onProgress?.call('資料寫入中: $saved / $total 筆')
          );
          apiSuccess = true;
        }
      }
    } catch (e) {
      DatabaseService.log('Taichung API Sync Failed', error: e);
    }

    if (apiSuccess) {
      await _dbService.updateVersion(requiredAssetVersion, 'taichung');
      onProgress?.call('台中市班表更新成功！');
    } else {
      // 若 API 失敗，嘗試從本地 Assets 載入
      if (currentCount < 100) {
        onProgress?.call('雲端同步失敗，改從備援資料恢復...');
        await _importFromLocalAssets(onProgress);
      } else {
        onProgress?.call('連線失敗，保留現有本地資料。');
      }
    }
  }

  /// 在背景 Isolate 解析台中班表 JSON。
  static List<GarbageRoutePoint> _parseTaichungScheduleIsolate(String body) {
    final List<dynamic> data = json.decode(body);
    List<GarbageRoutePoint> points = [];
    final int weekday = DateTime.now().weekday; // 1-7 (週一到週日)

    for (int i = 0; i < data.length; i++) {
      final item = data[i];
      final String carNo = (item['car_licence'] ?? '').toString();
      if (carNo.isEmpty) continue;

      // [智慧選時邏輯]：先找當天，若沒收則找這週最早有收的時間
      String rawTime = (item['g_d${weekday}_time_s'] ?? '').toString();
      if (rawTime.isEmpty || rawTime == 'null') {
        for (int d = 1; d <= 7; d++) {
          final String altTime = (item['g_d${d}_time_s'] ?? '').toString();
          if (altTime.isNotEmpty && altTime != 'null') {
            rawTime = altTime;
            break;
          }
        }
      }

      if (rawTime.isEmpty || rawTime == 'null') continue;

      // 座標處理：X 為經度，Y 為緯度
      final double? lat = double.tryParse(item['Y']?.toString() ?? '');
      final double? lng = double.tryParse(item['X']?.toString() ?? '');

      if (lat != null && lng != null) {
        final String area = item['area']?.toString() ?? '';
        final String village = item['village']?.toString() ?? '';
        final String siteName = item['caption']?.toString() ?? '定時收運點';

        points.add(GarbageRoutePoint(
          lineId: carNo, // 以車牌為識別 Key
          lineName: '$area$village',
          rank: i,
          name: siteName,
          position: LatLng(lat, lng),
          arrivalTime: TimeUtils.formatTo24Hour(rawTime),
        ));
      }
    }
    return points;
  }

  Future<void> _importFromLocalAssets(void Function(String)? onProgress) async {
    try {
      final String content = await rootBundle.loadString('assets/taichung_route.json');
      final List<GarbageRoutePoint> allPoints = await compute(_parseTaichungScheduleIsolate, content);
      if (allPoints.isNotEmpty) {
        await _dbService.clearAndSaveRoutePointsWithProgress(
          allPoints, 
          'taichung', 
          (saved, total) => onProgress?.call('載入內建資料: $total 筆')
        );
      }
    } catch (_) {}
  }

  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      // 抓取即時座標 API (rid=c923...)
      String targetUrl = '$dynamicApiUrl&limit=20000&_t=${DateTime.now().millisecondsSinceEpoch}';
      if (kIsWeb) targetUrl = 'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(targetUrl);
      
      final response = await _client.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        List<GarbageTruck> trucks = [];

        for (var item in data) {
          final String carNo = (item['car'] ?? '').toString();
          final double? lat = double.tryParse(item['Y']?.toString() ?? '');
          final double? lng = double.tryParse(item['X']?.toString() ?? '');

          if (carNo.isNotEmpty && lat != null && lng != null && lat > 22 && lat < 26) {
            // 台中 ISO T 格式解析
            DateTime updateTime = DateTime.now();
            final String timeStr = (item['time'] ?? '').toString();
            if (timeStr.contains('T')) {
              try {
                // 格式: 20240411T093000
                final String f = '${timeStr.substring(0, 4)}-${timeStr.substring(4, 6)}-${timeStr.substring(6, 8)} '
                                 '${timeStr.substring(9, 11)}:${timeStr.substring(11, 13)}:${timeStr.substring(13, 15)}';
                updateTime = DateTime.tryParse(f) ?? DateTime.now();
              } catch (_) {}
            }

            trucks.add(GarbageTruck(
              carNumber: carNo,
              lineId: carNo, // 車牌映射
              location: (item['location'] ?? '清運中').toString(),
              position: LatLng(lat, lng),
              updateTime: updateTime,
              isRealTime: true,
            ));
          }
        }
        if (trucks.isNotEmpty) return trucks;
      }
    } catch (e) {
      DatabaseService.log('Taichung Dynamic API Error', error: e);
    }
    
    // 如果 API 失敗，回退到班表推估模式
    return await findTrucksByTime(DateTime.now().hour, DateTime.now().minute);
  }

  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    // 1. 從資料庫獲取此時段的預定班表
    final points = await _dbService.findPointsByTime(hour, minute, 'taichung');
    if (points.isEmpty) return [];

    // 2. 為了實現「混合模式」，嘗試獲取一次即時座標進行映射 (如果可能的話)
    // 注意：這裡為了效能，通常直接顯示資料庫座標，但在 TaichungGarbageService 中，
    // 我們已經在 fetchTrucks() 實作了即時映射。findTrucksByTime 主要是給預測模式使用的。
    return points.map((p) => GarbageTruck(
      carNumber: '預定車',
      lineId: p.lineId,
      location: '${p.lineName} - ${p.name}',
      position: p.position,
      updateTime: DateTime.now(),
      isRealTime: false,
    )).toList();
  }

  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async {
    // lineId 就是 car_licence
    return await _dbService.getRoutePoints(lineId, 'taichung');
  }
}
