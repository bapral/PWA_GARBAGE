import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';

/// [BaseGarbageService] 是所有城市垃圾清運服務的基底抽象類別。
/// 
/// 定義了統一的介面，確保各城市的實作皆包含資料同步、車輛抓取、時間查詢等功能。
abstract class BaseGarbageService {
  /// 存放該城市本地資源檔案（如預載 CSV/JSON）的目錄路徑。
  final String localSourceDir; 
  
  /// 建構子：初始化服務基類。
  BaseGarbageService({required this.localSourceDir});

  /// 抽象方法：檢查版本並同步清運點位資料至資料庫。
  /// [onProgress] 同步進度回調函式。
  Future<void> syncDataIfNeeded({void Function(String)? onProgress});

  /// 抽象方法：獲取該城市目前的垃圾車動態（API 或 班表）。
  /// 回傳即時 [GarbageTruck] 清單。
  Future<List<GarbageTruck>> fetchTrucks();

  /// 根據指定的時間點，從資料庫中檢索預計出現的垃圾車。
  /// [hour] 小時，[minute] 分鐘。
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute);

  /// 獲取特定路線編號的完整點位序列。
  /// [lineId] 路線編號。
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId);

  /// 釋放資源（如關閉 HTTP 用戶端）。
  void dispose();
}
