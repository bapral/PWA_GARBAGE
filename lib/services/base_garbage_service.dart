import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import 'database_service.dart';

/// 垃圾清運服務基底類別。
abstract class BaseGarbageService {
  final String localSourceDir;
  BaseGarbageService({required this.localSourceDir});

  void dispose();
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress});
  Future<List<GarbageTruck>> fetchTrucks();
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute);
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId);

  /// [Web 專用] 高可用性抓取工具：具備自動 JSON 拆包功能的代理輪詢。
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
