/// [整體程式說明]
/// 本文件定義了 [GarbageTruck] 模型，代表垃圾車的即時動態狀態。
/// 除了封裝基本的車號、即時座標、位置描述與更新時間外，
/// 本模型還內建了「位置預測邏輯」，用於在 API 更新間隔期間提供流暢的車輛移動動畫。
///
/// [執行順序說明]
/// 1. 透過各城市的 [GarbageService] 從網路獲取即時 GPS 資料。
/// 2. 使用 `GarbageTruck.fromJson` 將原始 JSON 資料解析為結構化模型。
/// 3. 在 [MapScreen] 地圖渲染時，若需要平滑移動，會呼叫 `predictPosition` 或 `predictOnRoute`。
/// 4. 預測邏輯會根據傳入的 `duration`（與最後更新時間的時間差）推算當前可能的經緯度。

import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'garbage_route_point.dart';

/// [GarbageTruck] 類別代表垃圾車的動態狀態資訊。
/// 
/// 記錄了車輛即時位置、隸屬路線以及 GPS 更新的時間點，並提供位置預測邏輯。
class GarbageTruck {
  /// 車牌號碼，作為車輛的唯一識別碼。
  final String carNumber;
  
  /// 目前車輛正在行駛的路線 ID。
  final String lineId;
  
  /// 根據 GPS 回傳的最近位置地址描述。
  final String location;
  
  /// 垃圾車目前的地理經緯度座標。
  final LatLng position;
  
  /// 該筆位置資訊最後更新的時間 (來自 GPS 伺服器)。
  final DateTime updateTime;

  /// 建構子：初始化垃圾車動態物件。
  /// 
  /// [carNumber] 車牌號碼。
  /// [lineId] 路線 ID。
  /// [location] 位置描述。
  /// [position] 目前座標。
  /// [updateTime] 更新時間。
  GarbageTruck({
    required this.carNumber,
    required this.lineId,
    required this.location,
    required this.position,
    required this.updateTime,
  });

  /// 從 JSON 格式解析為 [GarbageTruck] 物件。
  /// 
  /// 針對各縣市政府 API 欄位命名不統一的情況，採用多種可能的 Key 進行探索解析。
  /// [json] 原始資料。
  /// 回傳建構完成的 [GarbageTruck] 實例。
  factory GarbageTruck.fromJson(Map<String, dynamic> json) {
    // 優先解析車牌號碼相關 Key
    String car = (json['car'] ?? json['PlateNumb'] ?? json['car_number'] ?? json['PlateNumber'] ?? '未知').toString();
    
    // 解析路線 ID
    String line = (json['lineid'] ?? json['RouteID'] ?? json['route_id'] ?? '無').toString();
    
    // 解析經緯度，支援多種大小寫組合
    double lat = double.tryParse((json['latitude'] ?? json['Latitude'] ?? json['lat'] ?? '0').toString()) ?? 0;
    double lng = double.tryParse((json['longitude'] ?? json['Longitude'] ?? json['lng'] ?? '0').toString()) ?? 0;
    
    // 解析位置描述
    String loc = (json['location'] ?? json['address'] ?? json['Address'] ?? '').toString();
    
    // 解析更新時間，若解析失敗則回退至系統當前時間
    DateTime time = DateTime.tryParse((json['time'] ?? json['GPSTime'] ?? json['update_time'] ?? '').toString()) ?? DateTime.now();

    return GarbageTruck(
      carNumber: car,
      lineId: line,
      location: loc,
      position: LatLng(lat, lng),
      updateTime: time,
    );
  }

  /// 模式一：簡易隨機位置預測。
  /// 
  /// 基於當前位置，給予隨機的角度與速度，估算 [duration] 時間後的可能位置。
  /// 主要用於無路線資訊參考時的移動動畫模擬。
  /// [duration] 自最後一次更新以來經過的時間。
  /// 回傳預測的 [LatLng] 座標。
  LatLng predictPosition(Duration duration) {
    if (duration == Duration.zero) return position;
    final double minutes = duration.inMinutes.toDouble();
    
    // 使用車牌號碼作為隨機數種子，確保同一台車的預測方向一致。
    final Random random = Random(carNumber.hashCode);
    final double angle = random.nextDouble() * 2 * pi;
    
    // 定義模擬速度 (經緯度小量變化值)
    final double speed = (0.0002 + random.nextDouble() * 0.0003);
    return LatLng(
      position.latitude + sin(angle) * speed * minutes,
      position.longitude + cos(angle) * speed * minutes
    );
  }

  /// 模式二：循跡路線位置預測。
  /// 
  /// 根據預先儲存的路線清單 [allRoutePoints]，推算車輛在 [duration] 分鐘後的預期位置。
  /// 
  /// 運作原理：
  /// 1. 找出與此車輛 [lineId] 匹配的所有路線站點。
  /// 2. 比對當前座標，找到最接近的路線索引。
  /// 3. 根據時間進度（假設每 3 分鐘移動一站），推算出目標站點索引。
  /// 
  /// [duration] 自最後一次更新以來經過的時間。
  /// [allRoutePoints] 全部的路線站點緩存資料。
  /// 回傳預測的 [LatLng] 座標。
  LatLng predictOnRoute(Duration duration, List<GarbageRoutePoint> allRoutePoints) {
    if (duration == Duration.zero) return position;
    
    // 篩選出該路線的點位並按順序排列
    final routePoints = allRoutePoints.where((p) => p.lineId == lineId).toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));
    
    // 若找不到對應路線點，則退回隨機預測模式
    if (routePoints.isEmpty) return predictPosition(duration);
    
    final distanceCalc = const Distance();
    int currentIdx = 0;
    double minD = double.infinity;
    
    // 找出目前即時座標最接近哪一個清運點 (定位當前進度)
    for (int i = 0; i < routePoints.length; i++) {
      final d = distanceCalc.as(LengthUnit.Meter, position, routePoints[i].position);
      if (d < minD) {
        minD = d;
        currentIdx = i;
      }
    }
    
    // 計算預期移動的站數 (預估 3 分鐘一站)
    final int move = (duration.inMinutes / 3).floor();
    int targetIdx = currentIdx + move;
    
    // 確保索引不超出該路線總站數
    if (targetIdx >= routePoints.length) targetIdx = routePoints.length - 1;
    
    // 回傳預測點的座標
    return routePoints[targetIdx].position;
  }
}
