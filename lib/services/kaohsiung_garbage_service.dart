/// [整體程式說明]
/// 本文件定義了 [KaohsiungGarbageService] 類別，專門處理高雄市的垃圾清運資料。
/// 由於高雄市政府開放資料格式多變，本服務實作了強大的備援機制與彈性的 JSON 解析邏輯。
/// 支援從多個 API 端點獲取班表資料，並將其標準化後存入本地資料庫，供應用程式進行位置預測。
///
/// [執行順序說明]
/// 1. 呼叫 `syncDataIfNeeded` 檢查版本。
/// 2. 若需更新，依序嘗試 `routeApiUrls` 中的連結。
/// 3. 解析 API 回傳的 JSON，特別處理高雄特有的「合併經緯度字串」格式。
/// 4. 將標準化後的 `GarbageRoutePoint` 批量存入資料庫。
/// 5. 當呼叫 `fetchTrucks` 時，目前高雄市採「班表推估」模式，透過 `findTrucksByTime` 回傳結果。

import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';
import 'ntpc_garbage_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 高雄市垃圾清運服務類別，負責處理高雄市開放資料的同步與查詢。
class KaohsiungGarbageService extends BaseGarbageService {
  /// 高雄市政府開放資料 - 垃圾清運路線及時間 API 連結清單。
  /// 
  /// 提供多個備援連結，防止政府 API 介面變更造成斷訊。
  static const List<String> routeApiUrls = [
    // 主要 API (高雄市政府 API 平台 - 最新)
    'https://api.kcg.gov.tw/api/service/get/7c80a17b-ba6c-4a07-811e-feae30ff9210',
    // 備援 API 1
    'https://api.kcg.gov.tw/ServiceList/GetFullList/074c805a-00e1-4fc5-b5f8-b2f4d6b64aa4',
    // 備援 API 2 (政府資料開放平臺導向)
    'https://data.gov.tw/api/v2/GP_P_01?format=json&filters=county,EQ,高雄市&offset=0&limit=1000'
  ];

  final DatabaseService _dbService = DatabaseService();
  final http.Client _client;

  /// 建構子：初始化高雄市服務。
  /// 
  /// [localSourceDir] 本地資源目錄。
  /// [client] 可選傳入 http.Client 以利測試。
  KaohsiungGarbageService({required super.localSourceDir, http.Client? client}) 
      : _client = client ?? http.Client() {
    DatabaseService.log('KaohsiungGarbageService 已建立');
  }

  @override
  void dispose() {
    _client.close();
    DatabaseService.log('KaohsiungGarbageService 已釋放資源 (Client closed)');
  }

  /// 檢查高雄市資料版本並執行同步。
  /// 
  /// 邏輯流：
  /// 1. 取得目前 App 的版號。
  /// 2. 比對資料庫中已存的版本標籤。
  /// 3. 若版本不符或無點位資料，則逐一嘗試 API URLs。
  /// 4. 解析 API JSON 回傳，處理多種可能的欄位格式（如經緯度合併或分開）。
  /// 5. 將解析完成的點位大量寫入資料庫，並更新版本標記。
  /// 
  /// [onProgress] 同步進度回調函式。
  /// [debugVersion] 供測試使用的模擬版本號。
  @override
  Future<void> syncDataIfNeeded({void Function(String)? onProgress, String? debugVersion}) async {
    String currentAppVersion;
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      currentAppVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (e) {
      // 測試環境下的防錯處理
      currentAppVersion = debugVersion ?? 'test_version';
    }
    
    final String? storedVersion = await _dbService.getStoredVersion('kaohsiung');

    // 檢查是否需要執行耗時的網路同步
    bool needsUpdate = storedVersion != currentAppVersion || !(await _dbService.hasData('kaohsiung'));

    if (!needsUpdate) {
      onProgress?.call('高雄市快取資料已為最新...');
      return;
    }

    onProgress?.call('正在執行高雄市路線資料同步程序...');
    
    // 迭代嘗試備援連結
    for (String url in routeApiUrls) {
      try {
        onProgress?.call('連線至 API: $url');
        final response = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
        
        if (response.statusCode == 200) {
          final dynamic decoded = json.decode(utf8.decode(response.bodyBytes));
          List<dynamic> records = [];
          
          // 解析彈性的 JSON 結構 (高雄 API 常更動外層包裝)
          if (decoded is List) {
            records = decoded;
          } else if (decoded is Map) {
            if (decoded.containsKey('data')) {
              records = decoded['data'];
            } else if (decoded.containsKey('records')) {
              records = decoded['records'];
            }
          }
          
          if (records.isEmpty) continue;

          onProgress?.call('成功獲取 ${records.length} 筆原始資料，開始解析格式...');
          
          List<GarbageRoutePoint> allPoints = [];
          for (int i = 0; i < records.length; i++) {
            final item = records[i];
            
            double? lat;
            double? lng;

            // 處理高雄特有的合併經緯度字串 (例如 "22.6,120.3")
            final String coordStr = item['經緯度']?.toString() ?? '';
            if (coordStr.contains(',')) {
              final parts = coordStr.split(',');
              if (parts.length >= 2) {
                lat = double.tryParse(parts[0].trim());
                lng = double.tryParse(parts[1].trim());
              }
            } else {
              // 退回處理傳統的獨立經緯度欄位
              lat = double.tryParse(item['緯度']?.toString() ?? item['latitude']?.toString() ?? '');
              lng = double.tryParse(item['經度']?.toString() ?? item['longitude']?.toString() ?? '');
            }

            final String area = item['行政區']?.toString() ?? item['town']?.toString() ?? '';
            final String village = item['村里']?.toString() ?? item['village']?.toString() ?? '';
            final String location = item['停留地點']?.toString() ?? item['停留點']?.toString() ?? item['caption']?.toString() ?? '未知站點';
            
            // 時間格式標準化 (將 "0830" 或 "16:00-16:10" 轉換為 "HH:mm")
            String timeRaw = item['停留時間']?.toString() ?? item['停留時段']?.toString() ?? item['time']?.toString() ?? '';
            String timeStr = '';
            if (timeRaw.isNotEmpty) {
              if (timeRaw.contains('-')) {
                timeStr = timeRaw.split('-')[0].trim(); // 取開始時間
              } else {
                timeStr = timeRaw;
              }

              // 補齊冒號
              if (timeStr.length == 4 && !timeStr.contains(':')) {
                timeStr = '${timeStr.substring(0, 2)}:${timeStr.substring(2, 4)}';
              }
            }

            final String routeName = item['清運路線名稱']?.toString() ?? item['車次']?.toString() ?? item['linid']?.toString() ?? '未知路線';

            if (lat != null && lng != null && timeStr.isNotEmpty) {
              allPoints.add(GarbageRoutePoint(
                lineId: routeName,
                lineName: '$area $routeName',
                rank: i,
                name: '${village.isNotEmpty ? "$village " : ""}$location',
                position: LatLng(lat, lng),
                arrivalTime: timeStr,
              ));
            }
          }
          
          if (allPoints.isNotEmpty) {
            onProgress?.call('寫入資料庫 ${allPoints.length} 筆...');
            await _dbService.clearAndSaveRoutePoints(allPoints, 'kaohsiung');
            await _dbService.updateVersion(currentAppVersion, 'kaohsiung');
            onProgress?.call('高雄市同步完成！');
            return; // 只要有一個連結成功就終止循環
          }
        }
      } catch (e) {
        DatabaseService.log('連線嘗試失敗: $url', error: e);
      }
    }
    
    onProgress?.call('同步失敗：所有 API 備援連結皆無法正常運作。');
  }

  /// 即時抓取高雄市車輛。
  /// 
  /// 高雄市目前僅開放班表型 API，因此即時動態亦透過班表推估。
  /// 回傳當前時段的 [GarbageTruck] 清單。
  @override
  Future<List<GarbageTruck>> fetchTrucks() async {
    final now = DateTime.now();
    return await findTrucksByTime(now.hour, now.minute);
  }

  /// 從資料庫班表查詢指定時間點的預估車輛位置。
  /// 
  /// [hour] 目標小時。
  /// [minute] 目標分鐘。
  /// 回傳符合該時段的預估 [GarbageTruck] 清單。
  @override
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute) async {
    final points = await _dbService.findPointsByTime(hour, minute, 'kaohsiung');
    final now = DateTime.now();
    
    return points.map((p) {
      DateTime scheduledTime = now;
      try {
        final parts = p.arrivalTime.split(':');
        if (parts.length >= 2) {
          scheduledTime = DateTime(now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]));
        }
      } catch (_) {}

      return GarbageTruck(
        carNumber: '預定車', // 班表查詢結果統一標示為預定車
        lineId: p.lineId,
        location: p.name,
        position: p.position,
        updateTime: scheduledTime,
      );
    }).toList();
  }

  /// 獲取高雄市特定路線的所有站點。
  /// 
  /// [lineId] 路線編號。
  /// 回傳完整的 [GarbageRoutePoint] 序列。
  @override
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId) async {
    return await _dbService.getRoutePoints(lineId, 'kaohsiung');
  }
}
