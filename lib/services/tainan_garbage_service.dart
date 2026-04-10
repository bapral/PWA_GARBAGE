/// [整體程式說明]
/// 本文件定義了 [TainanGarbageService] 類別，專門處理台南市的垃圾清運資料。
/// 支援從台南市政府開放資料平台介接 JSON 格式的 API。
/// 包含即時動態位置以及詳細的清運站點班表資料。
///
/// [執行順序說明]
/// 1. 呼叫 `syncDataIfNeeded`：連線至台南市班表 API 下載所有清運點資料。
/// 2. 解析 JSON 內容，將點位座標（LATITUDE/LONGITUDE）與路線資訊轉換為物件。
/// 3. 使用事務模式批量寫入 SQLite 資料庫。
/// 4. 呼叫 `fetchTrucks`：定期從 API 獲取最新的垃圾車即時座標。
/// 5. 提供 `findTrucksByTime` 功能，於網路斷線或預測模式下從資料庫檢索班表。

import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'ntpc_garbage_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// [TainanGarbageService] 實作台南市的垃圾車服務邏輯。
/// 
/// 支援從台南市政府 Open Data 取得 JSON 格式的即時動態與靜態清運點資料。
class TainanGarbageService extends BaseGarbageService {
  /// 即時動態 API
  static const String dynamicApiUrl = 'https://soa.tainan.gov.tw/Api/Service/Get/2c8a70d5-06f2-4353-9e92-c40d33bcd969';
  /// 班表清運點 API
  static const String routeApiUrl = 'https://soa.tainan.gov.tw/Api/Service/Get/84df8cd6-8741-41ed-919c-5105a28ecd6d';

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  /// 建構子：初始化台南市服務。
  /// [localSourceDir] 資源目錄，[client] 可選傳入 http 客戶端。
  TainanGarbageService({required super.localSourceDir, http.Client? client}) 
      : _client = client ?? http.Client() {
    DatabaseService.log('TainanGarbageService 已建立');
  }

  @override
  void dispose() {
    _client.close();
    DatabaseService.log('TainanGarbageService 已釋放資源 (Client closed)');
  }

  /// 台南市路線點位同步程序。
  /// 
  /// 解析 JSON 中的座標、清運站點名稱與表定時間。
  /// [onProgress] 同步進度回調。
  @override
  Future<void> syncDataIfNeeded({void Function(String)? onProgress}) async {
    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    final String currentAppVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    final String? storedVersion = await _dbService.getStoredVersion('tainan');

    bool needsUpdate = storedVersion != currentAppVersion || !(await _dbService.hasData('tainan'));

    if (!needsUpdate) {
      onProgress?.call('台南市資料庫已是最新版...');
      return;
    }

    onProgress?.call('正在啟動台南市 API 同步...');
    
    try {
      final response = await _client.get(Uri.parse(routeApiUrl)).timeout(const Duration(seconds: 30));
      
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        final List<dynamic> records = data['data'] ?? [];
        
        onProgress?.call('成功獲取 ${records.length} 筆清運點，正在解析格式...');
        
        List<GarbageRoutePoint> allPoints = [];
        for (int i = 0; i < records.length; i++) {
          final item = records[i];
          
          final double? lat = double.tryParse(item['LATITUDE']?.toString() ?? '');
          final double? lng = double.tryParse(item['LONGITUDE']?.toString() ?? '');
          final String routeId = item['ROUTEID']?.toString() ?? '未知路線';
          final String area = item['AREA']?.toString() ?? '';
          String arrivalTime = item['TIME']?.toString() ?? '';

          if (lat != null && lng != null && arrivalTime.isNotEmpty) {
            allPoints.add(GarbageRoutePoint(
              lineId: routeId,
              lineName: '$area $routeId 路線',
              rank: int.tryParse(item['ROUTEORDER']?.toString() ?? '') ?? i,
              name: item['POINTNAME']?.toString() ?? '未知站點',
              position: LatLng(lat, lng),
              arrivalTime: arrivalTime,
            ));
          }
        }
        
        onProgress?.call('正在批次存入本地 SQLite 資料庫...');
        await _dbService.clearAndSaveRoutePoints(allPoints, 'tainan');
        await _dbService.updateVersion(currentAppVersion, 'tainan');
        onProgress?.call('台南市同步作業順利完成。');
      }
    } catch (e) {
      DatabaseService.log('台南市 API 同步時發生錯誤', error: e);
      onProgress?.call('同步失敗: $e');
    }
  }

  /// 獲取台南市車輛即時動態。
  /// 
  /// 透過 API 獲取車牌、路線與即時座標，並回傳 [GarbageTruck] 清單。
  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      final response = await _client.get(Uri.parse(dynamicApiUrl));
      
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        final List<dynamic> records = data['data'] ?? [];
        final now = DateTime.now();
        
        return records.map((item) {
          final String carNo = item['car']?.toString() ?? '未知車號';
          final String linid = item['linid']?.toString() ?? carNo;
          final double lat = double.tryParse(item['y']?.toString() ?? '0') ?? 0;
          final double lng = double.tryParse(item['x']?.toString() ?? '0') ?? 0;
          
          return GarbageTruck(
            carNumber: carNo,
            lineId: linid,
            location: item['location']?.toString() ?? '行駛中',
            position: LatLng(lat, lng),
            updateTime: now,
          );
        }).toList();
      }
    } catch (e) {
      DatabaseService.log('台南市即時 API 連線異常，改採班表查詢模式', error: e);
    }
    
    // 若即時 API 失敗，退回班表預測
    final now = DateTime.now();
    return await findTrucksByTime(now.hour, now.minute);
  }

  /// 班表查詢。
  /// [hour] 小時，[minute] 分鐘。
  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'tainan');
    final now = DateTime.now();
    
    return points.map((p) {
      DateTime scheduledTime = now;
      try {
        final parts = p.arrivalTime.split(':');
        if (parts.length >= 2) {
          scheduledTime = DateTime(now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]));
        }
      } catch (_) {}

      return GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: p.name, position: p.position, updateTime: scheduledTime);
    }).toList();
  }

  /// 獲取指定路線的所有站點序列。
  /// [lineId] 路線 ID。
  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async {
    return await _dbService.getRoutePoints(lineId, 'tainan');
  }
}
