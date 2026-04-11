/// [整體程式說明]
/// 本文件定義了 [GarbageTruck] 模型，代表垃圾車的即時動態狀態。
/// 除了封裝基本的車號、即時座標、位置描述與更新時間外，
/// 本模型還內建了「位置預測邏輯」，用於在 API 更新間隔期間提供流暢的車輛移動動畫。

import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'garbage_route_point.dart';

/// [GarbageTruck] 類別代表垃圾車的動態狀態資訊。
class GarbageTruck {
  /// 車牌號碼，作為車輛的唯一識別碼。
  final String carNumber;
  
  /// 目前車輛正在行駛的路線 ID。
  final String lineId;
  
  /// 根據 GPS 或班表回傳的位置描述。
  final String location;
  
  /// 垃圾車目前的地理經緯度座標。
  final LatLng position;
  
  /// 最後更新時間或預計抵達時間。
  final DateTime updateTime;

  /// 標記此資料是否來自「真實 GPS API」 (true) 還是「資料庫班表推估」 (false)。
  final bool isRealTime;

  /// 建構子：初始化垃圾車動態物件。
  GarbageTruck({
    required this.carNumber,
    required this.lineId,
    required this.location,
    required this.position,
    required this.updateTime,
    this.isRealTime = true, // 預設為 true 以相容舊程式碼
  });

  /// 從 JSON 格式解析為 [GarbageTruck] 物件。
  factory GarbageTruck.fromJson(Map<String, dynamic> json) {
    String car = (json['car'] ?? json['PlateNumb'] ?? json['car_number'] ?? json['PlateNumber'] ?? '未知').toString();
    String line = (json['lineid'] ?? json['RouteID'] ?? json['route_id'] ?? '無').toString();
    double lat = double.tryParse((json['latitude'] ?? json['Latitude'] ?? json['lat'] ?? '0').toString()) ?? 0;
    double lng = double.tryParse((json['longitude'] ?? json['Longitude'] ?? json['lng'] ?? '0').toString()) ?? 0;
    String loc = (json['location'] ?? json['address'] ?? json['Address'] ?? '').toString();
    DateTime time = DateTime.tryParse((json['time'] ?? json['GPSTime'] ?? json['update_time'] ?? '').toString()) ?? DateTime.now();

    return GarbageTruck(
      carNumber: car,
      lineId: line,
      location: loc,
      position: LatLng(lat, lng),
      updateTime: time,
      isRealTime: true, // 從 API JSON 來的一定是即時
    );
  }

  LatLng predictPosition(Duration duration) {
    if (duration == Duration.zero) return position;
    final double minutes = duration.inMinutes.toDouble();
    final Random random = Random(carNumber.hashCode);
    final double angle = random.nextDouble() * 2 * pi;
    final double speed = (0.0002 + random.nextDouble() * 0.0003);
    return LatLng(
      position.latitude + sin(angle) * speed * minutes,
      position.longitude + cos(angle) * speed * minutes
    );
  }

  LatLng predictOnRoute(Duration duration, List<GarbageRoutePoint> allRoutePoints) {
    if (duration == Duration.zero) return position;
    final routePoints = allRoutePoints.where((p) => p.lineId == lineId).toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));
    if (routePoints.isEmpty) return predictPosition(duration);
    final distanceCalc = const Distance();
    int currentIdx = 0;
    double minD = double.infinity;
    for (int i = 0; i < routePoints.length; i++) {
      final d = distanceCalc.as(LengthUnit.Meter, position, routePoints[i].position);
      if (d < minD) {
        minD = d;
        currentIdx = i;
      }
    }
    final int move = (duration.inMinutes / 3).floor();
    int targetIdx = currentIdx + move;
    if (targetIdx >= routePoints.length) targetIdx = routePoints.length - 1;
    return routePoints[targetIdx].position;
  }
}
