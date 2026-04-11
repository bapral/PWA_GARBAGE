import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';

/// 垃圾清運服務基底類別。
abstract class BaseGarbageService {
  final String localSourceDir;
  BaseGarbageService({required this.localSourceDir});

  /// 釋放資源 (如 http.Client)。
  void dispose();

  /// 同步班表資料至資料庫。
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress});

  /// 獲取即時垃圾車動態。
  Future<List<GarbageTruck>> fetchTrucks();

  /// 根據時間查找班表點位。
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute);

  /// 獲取特定路線的所有點位。
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId);

  /// [Web 專用] 具備備援機制的 Web 抓取工具。
  Future<String?> webFetch(http.Client client, String url, {int timeout = 15}) async {
    if (!kIsWeb) return null;

    // 代理伺服器清單 (由穩定到備援)
    final proxies = [
      (String u) => 'https://corsproxy.io/?' + Uri.encodeComponent(u),
      (String u) => 'https://api.allorigins.win/get?url=' + Uri.encodeComponent(u),
      (String u) => 'https://api.codetabs.com/v1/proxy?url=' + Uri.encodeComponent(u),
    ];

    for (var proxyFunc in proxies) {
      try {
        final target = proxyFunc(url);
        final res = await client.get(Uri.parse(target)).timeout(Duration(seconds: timeout));
        
        if (res.statusCode == 200) {
          if (target.contains('allorigins.win')) {
            final Map<String, dynamic> data = json.decode(res.body);
            return data['contents'];
          }
          return res.body;
        }
      } catch (e) {
        debugPrint('Proxy Attempt Failed: $e');
      }
    }
    return null;
  }
}
