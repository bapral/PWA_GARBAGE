/// [整體程式說明]
/// 本文件定義了 [BaseGarbageService] 抽象基底類別。
/// 它為各縣市的垃圾清運服務提供了一套標準介面（Interface），包括資料同步、即時抓取與班表檢索。
/// 透過此架構，Provider 可以動態切換不同的縣市服務而不影響 UI 邏輯。
/// 
/// [執行順序說明]
/// 1. `syncDataIfNeeded`：啟動時檢查本地 SQLite 是否已有資料或版本是否過舊。
/// 2. `fetchTrucks`：定期觸發以獲取雲端 API 的最新車輛座標。
/// 3. `findTrucksByTime`：當處於預測模式時，向本地資料庫查詢特定時段的班表。

import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';

/// 垃圾清運服務的抽象基底類別。
abstract class BaseGarbageService {
  /// 本地資源檔案路徑。
  final String localSourceDir;
  
  /// 初始化服務。
  BaseGarbageService({required this.localSourceDir});

  /// 釋放服務佔用的資源（如 [http.Client]）。
  void dispose();
  
  /// 檢查並同步資料庫資料。
  /// [force] 是否強制連線網路 API 更新。
  /// [onProgress] 回調函式，用於通知 UI 當前同步進度描述。
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress});
  
  /// 獲取即時車輛位置。
  /// 回傳當前線上的 [GarbageTruck] 清單。
  Future<List<GarbageTruck>> fetchTrucks();
  
  /// 根據特定時間點查詢班表推估車輛。
  /// [hour] 小時 (0-23)。
  /// [minute] 分鐘 (0-59)。
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute);
  
  /// 獲取特定路線的所有站點路徑。
  /// [lineId] 路線唯一代碼。
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId);

  /// [Web 專用] 高可用性抓取工具：具備自動 JSON 拆包功能的代理輪詢。
  /// 
  /// 針對 Web 平台跨網域 (CORS) 限制設計，若直接連線失敗，將依序嘗試多個代理伺服器。
  Future<String?> webFetch(http.Client client, String url, {int timeout = 15}) async {
    if (!kIsWeb) return null;

    // 1. 嘗試直接連線 (預防某些 API 已開啟 CORS)
    try {
      final res = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) return res.body;
    } catch (_) {}

    // 2. 代理伺服器輪詢清單
    final proxyConfigs = [
      {'name': 'CorsProxy.io', 'url': 'https://corsproxy.io/?${Uri.encodeComponent(url)}', 'isJson': false},
      {'name': 'AllOrigins', 'url': 'https://api.allorigins.win/get?url=${Uri.encodeComponent(url)}', 'isJson': true},
      {'name': 'CodeTabs', 'url': 'https://api.codetabs.com/v1/proxy?url=${Uri.encodeComponent(url)}', 'isJson': false},
    ];

    for (var config in proxyConfigs) {
      try {
        final String proxyUrl = config['url'] as String;
        final bool isJsonWrap = config['isJson'] as bool;
        
        DatabaseService.log('PWA 連線嘗試: ${config['name']}');
        
        final res = await client.get(Uri.parse(proxyUrl)).timeout(Duration(seconds: timeout));
        
        if (res.statusCode == 200 && res.body.isNotEmpty) {
          if (isJsonWrap) {
            final Map<String, dynamic> data = json.decode(res.body);
            final String? content = data['contents'];
            if (content != null && content.isNotEmpty) return content;
          } else {
            return res.body;
          }
        }
      } catch (e) {
        DatabaseService.log('${config['name']} 代理請求失敗: $e');
      }
    }
    return null;
  }
}
