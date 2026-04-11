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

  /// [Web 專用] 高可用性抓取工具：嘗試直接連線與多重代理
  Future<String?> webFetch(http.Client client, String url, {int timeout = 15}) async {
    if (!kIsWeb) return null;

    // 1. 嘗試直接連線 (預防某些 API 已開啟 CORS)
    try {
      final res = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) return res.body;
    } catch (_) {}

    // 2. 代理伺服器輪詢清單 (使用 raw 模式以簡化解析)
    final proxyUrls = [
      'https://corsproxy.io/?' + Uri.encodeComponent(url),
      'https://api.allorigins.win/raw?url=' + Uri.encodeComponent(url),
      'https://thingproxy.freeboard.io/fetch/' + url,
    ];

    for (var target in proxyUrls) {
      try {
        DatabaseService.log('嘗試代理連線: $target');
        final res = await client.get(Uri.parse(target)).timeout(Duration(seconds: timeout));
        if (res.statusCode == 200 && res.body.isNotEmpty) {
          DatabaseService.log('代理連線成功！');
          return res.body;
        }
      } catch (e) {
        DatabaseService.log('代理失敗 ($target): $e');
      }
    }
    return null;
  }
}
