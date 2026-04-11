import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';

/// [BaseGarbageService] 是所有城市垃圾清運服務的基底抽象類別。
abstract class BaseGarbageService {
  /// 存放該城市本地資源檔案（如預載 CSV/JSON）的目錄路徑。
  final String localSourceDir; 
  
  /// 建構子：初始化服務基類。
  BaseGarbageService({required this.localSourceDir});

  /// 檢查版本並同步資料。
  /// [force] 若為 true，代表是由使用者點擊「強制更新」按鈕觸發，應連線 API。
  /// [onProgress] 同步進度回調。
  Future<void> syncDataIfNeeded({bool force = false, void Function(String)? onProgress});

  /// 獲取該城市目前的垃圾車即時動態。
  Future<List<GarbageTruck>> fetchTrucks();

  /// 根據指定的時間點，從資料庫中檢索預計出現的垃圾車。
  Future<List<GarbageTruck>> findTrucksByTime(int hour, int minute);

  /// 獲取特定路線編號的完整點位序列。
  Future<List<GarbageRoutePoint>> getRouteForLine(String lineId);

  /// 釋放資源。
  void dispose();
}
