/// [整體程式說明]
/// 本文件定義了 [GarbageRoutePoint] 模型，代表靜態的垃圾清運站點資訊。
/// 該模型用於存儲來自政府開放資料（通常是 CSV 或 JSON 格式）的清運班表資訊，
/// 包含路線 ID、站點名稱、順序排名、座標以及預計抵達時間。
///
/// [執行順序說明]
/// 1. 各縣市清運服務類別（如 [TaipeiGarbageService]）讀取原始資料。
/// 2. 透過 `GarbageRoutePoint.fromJson` 靜態方法將每一筆原始資料轉換為結構化物件。
/// 3. 資料存放於 [GarbageProvider] 的靜態資料庫中。
/// 4. 當地圖需要顯示特定路線或進行位置預測時，從緩存中檢索這些點位。

import 'package:latlong2/latlong.dart';

/// [GarbageRoutePoint] 類別代表垃圾車清運路徑上的單一清運站點資訊。
/// 
/// 封裝了站點的位置、名稱、所屬路線以及預計抵達時間。
class GarbageRoutePoint {
  /// 路線唯一代碼，用於將點位關聯至特定行駛路線。
  final String lineId;
  
  /// 路線顯示名稱 (例如: "板橋區 A 路線")。
  final String lineName;
  
  /// 該點位在整條清運路線中的執行順序 (通常為 1, 2, 3...)。
  final int rank;
  
  /// 清運點的具體名稱或地址描述 (例如: "中正路 100 號前")。
  final String name;
  
  /// 該清運站點的地理經緯度座標。
  final LatLng position;
  
  /// 預計抵達站點的時間。
  /// 格式通常為 24 小時制的字串 "HH:mm" (例如 "17:30")。
  final String arrivalTime;

  /// 建構子：初始化清運站點物件。
  /// 
  /// [lineId] 路線代碼。
  /// [lineName] 路線名稱。
  /// [rank] 站點順序。
  /// [name] 站點名稱。
  /// [position] 座標。
  /// [arrivalTime] 預計抵達時間。
  GarbageRoutePoint({
    required this.lineId,
    required this.lineName,
    required this.rank,
    required this.name,
    required this.position,
    required this.arrivalTime,
  });

  /// 從 Map (通常來自 API 的 JSON 回傳) 轉換為 [GarbageRoutePoint] 物件的工廠方法。
  /// 
  /// 此方法具備容錯能力，會嘗試解析不同 API 可能使用的欄位 Key 名稱。
  /// [json] 為原始資料 Map。
  /// 回傳建構完成的 [GarbageRoutePoint] 實例。
  factory GarbageRoutePoint.fromJson(Map<String, dynamic> json) {
    return GarbageRoutePoint(
      // 解析路線 ID，若無則預設為空字串
      lineId: json['lineid'] ?? '',
      // 解析路線名稱
      lineName: json['linename'] ?? '',
      // 解析順序，並確保轉換為整數
      rank: int.tryParse(json['rank']?.toString() ?? '0') ?? 0,
      // 解析站點名稱
      name: json['name'] ?? '',
      // 解析座標，支援小寫 latitude/longitude
      position: LatLng(
        double.tryParse(json['latitude']?.toString() ?? '0') ?? 0,
        double.tryParse(json['longitude']?.toString() ?? '0') ?? 0,
      ),
      // 解析抵達時間字串
      arrivalTime: json['time'] ?? '',
    );
  }
}
