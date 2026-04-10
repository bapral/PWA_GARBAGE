/// [整體程式說明]
/// 本文件定義了 [TaichungGarbageService] 類別，專門處理台中市的垃圾清運資料。
/// 台中市的實作特色在於「班表資料」儲存在本地資源目錄的 JSON 檔案中。
/// 服務會讀取本地 JSON 班表，並結合即時 GPS API 的座標資訊，動態生成清運路線圖。
///
/// [執行順序說明]
/// 1. 呼叫 `syncDataIfNeeded`：首先從雲端 API 下載最新的車輛 GPS 快照。
/// 2. 讀取本地 `0_臺中市定時定點垃圾收運地點.JSON` 檔案。
/// 3. 根據當前的「星期幾」過濾班表中的有效時段。
/// 4. 將班表中的車號與即時 GPS 座標進行關聯（Mapping）。
/// 5. 將整合後的 `GarbageRoutePoint` 存入資料庫以供後續查詢。
/// 6. 呼叫 `fetchTrucks` 時，直接從台中市 API 獲取最新的動態資料。

import 'dart:io';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'ntpc_garbage_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';

/// [TaichungGarbageService] 負責台中市清運路線與即時車輛位置。
/// 
/// 特色在於：台中市的路線點位主要透過讀取本地預載的 JSON 班表檔案，並動態比對 API 位置。
class TaichungGarbageService extends BaseGarbageService {
  /// 台中市定時定點收運路線 API (JSON)
  static const String routeApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=68d1a87f-7baa-4b50-8408-c36a3a7eda68';
  /// 台中市垃圾車即時動態 API (JSON)
  static const String dynamicApiUrl = 'https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=c923ad20-2ec6-43b9-b3ab-54527e99f7bc';

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  /// 建構子：初始化台中市服務。
  /// [localSourceDir] 資源目錄，[client] 可選 http 客戶端。
  TaichungGarbageService({required super.localSourceDir, http.Client? client}) 
      : _client = client ?? http.Client() {
    DatabaseService.log('TaichungGarbageService 已建立');
  }

  @override
  void dispose() {
    _client.close();
    DatabaseService.log('TaichungGarbageService 已釋放資源 (Client closed)');
  }

  /// 同步台中市路線點位。
  /// 
  /// 實作邏輯：
  /// 1. 抓取動態 API 以獲取當前所有車輛的「車牌 -> 最新座標」映射表。
  /// 2. 載入本地資源目錄下的 `0_臺中市定時定點垃圾收運地點.JSON`。
  /// 3. 解析 JSON，根據當前的「星期幾」決定顯示哪一個收運時段。
  /// 4. 將班表與即時座標關聯，生成點位資料存入資料庫。
  /// 
  /// [onProgress] 同步進度回調。
  @override
  Future<void> syncDataIfNeeded({void Function(String)? onProgress}) async {
    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    final String currentAppVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    final String? storedVersion = await _dbService.getStoredVersion('taichung');

    bool needsUpdate = storedVersion != currentAppVersion || !(await _dbService.hasData('taichung'));

    if (!needsUpdate) {
      onProgress?.call('台中市班表資料已為最新...');
      return;
    }

    onProgress?.call('正在同步台中市資料 (正在解析本地班表並比對實時位置)...');
    
    try {
      // 步驟一：建立即時位置映射，確保點位顯示時能附帶車輛位置
      onProgress?.call('步驟 1/3: 下載即時位置快照...');
      final dynamicResponse = await _client.get(Uri.parse('$dynamicApiUrl&limit=20000')).timeout(const Duration(seconds: 15));
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

      // 步驟二：讀取本地 JSON 檔案
      onProgress?.call('步驟 2/3: 讀取本地 JSON 資源檔...');
      final String jsonPath = join(localSourceDir, '0_臺中市定時定點垃圾收運地點.JSON');
      final File jsonFile = File(jsonPath);
      if (!await jsonFile.exists()) {
        throw Exception('資源目錄中缺少關鍵班表檔案: $jsonPath');
      }

      final String content = await jsonFile.readAsString();
      final List<dynamic> scheduleData = json.decode(content);
      
      onProgress?.call('步驟 3/3: 解析班表並過濾站點 (共 ${scheduleData.length} 筆)...');
      
      List<GarbageRoutePoint> allPoints = [];
      int dayOfWeek = DateTime.now().weekday; // 1 (Mon) - 7 (Sun)
      
      for (int i = 0; i < scheduleData.length; i++) {
        final item = scheduleData[i];
        final String carNo = item['car_licence']?.toString() ?? '';
        final String locationName = item['caption']?.toString() ?? '未知清運點';
        
        // 取得本日收運時間 (欄位格式為 g_d{n}_time_s)
        String arrivalTime = item['g_d${dayOfWeek}_time_s']?.toString() ?? '';
        
        // 如果今天剛好沒收運，則找尋該站在一週內有收運的第一個時段作為展示用參考
        if (arrivalTime.isEmpty) {
          for (int d = 1; d <= 7; d++) {
            arrivalTime = item['g_d${d}_time_s']?.toString() ?? '';
            if (arrivalTime.isNotEmpty) break;
          }
        }

        if (arrivalTime.isEmpty) continue;

        // 若即時 API 沒資料，預設使用台中市中心位置
        LatLng pos = carPositions[carNo] ?? const LatLng(24.147, 120.673);

        allPoints.add(GarbageRoutePoint(
          lineId: carNo,
          lineName: '${item['area'] ?? ''}${item['village'] ?? ''} ($carNo)',
          rank: i,
          name: locationName,
          position: pos,
          arrivalTime: arrivalTime,
        ));
      }
      
      onProgress?.call('正在批次寫入資料庫 (${allPoints.length} 筆)...');
      await _dbService.clearAndSaveRoutePoints(allPoints, 'taichung');
      
      await _dbService.updateVersion(currentAppVersion, 'taichung');
      onProgress?.call('台中市同步完成！');
      
    } catch (e, stack) {
      DatabaseService.log('台中市同步作業中斷', error: e, stackTrace: stack);
      onProgress?.call('同步失敗: $e');
    }
  }

  /// 從 API 下載台中市即時位置資料。
  /// 
  /// 解析台中 API 特有的 T 格式時間，並回傳 [GarbageTruck] 清單。
  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    try {
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await _client.get(Uri.parse('$dynamicApiUrl&limit=20000&_t=$timestamp'));
      
      if (response.statusCode == 200) {
        final List<dynamic> results = json.decode(response.body);
        final now = DateTime.now();
        
        return results.map((item) {
          final String carNo = item['car']?.toString() ?? '未知車號';
          final String location = item['location']?.toString() ?? '移動中';
          final String latStr = item['Y']?.toString() ?? '0';
          final String lonStr = item['X']?.toString() ?? '0';
          
          DateTime updateTime = now;
          final String? timeStr = item['time']?.toString();
          if (timeStr != null && timeStr.contains('T')) {
            // 解析台中 API 特有的 T 格式時間
            try {
              final String formatted = '${timeStr.substring(0, 4)}-${timeStr.substring(4, 6)}-${timeStr.substring(6, 8)} ${timeStr.substring(9, 11)}:${timeStr.substring(11, 13)}:${timeStr.substring(13, 15)}';
              updateTime = DateTime.tryParse(formatted) ?? now;
            } catch (_) {}
          }

          return GarbageTruck(
            carNumber: carNo,
            lineId: item['lineid']?.toString() ?? '',
            location: location,
            position: LatLng(double.tryParse(latStr) ?? 0, double.tryParse(lonStr) ?? 0),
            updateTime: updateTime,
          );
        }).toList();
      }
    } catch (e) {
      DatabaseService.log('台中市即時 API 連接失敗，回退至班表模式', error: e);
    }
    
    // 退回班表
    final now = DateTime.now();
    return await findTrucksByTime(now.hour, now.minute);
  }

  /// 班表查詢功能。
  /// [hour] 小時，[minute] 分鐘。
  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'taichung');
    final now = DateTime.now();
    return points.map((p) {
      DateTime scheduledTime = now;
      try {
        final parts = p.arrivalTime.split(':');
        if (parts.length == 2) scheduledTime = DateTime(now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]));
      } catch (_) {}
      return GarbageTruck(carNumber: '預定車', lineId: p.lineId, location: '${p.lineName} - ${p.name}', position: p.position, updateTime: scheduledTime);
    }).toList();
  }

  /// 獲取台中市特定車次的所有清運點。
  /// [lineId] 路線編號（即車號）。
  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async {
    return await _dbService.getRoutePoints(lineId, 'taichung');
  }
}
