/// [整體程式說明]
/// 本文件定義了應用程式的所有狀態管理提供者（Providers），採用 Riverpod 框架。
/// 職責包括管理城市選擇、定位模式、同步狀態、以及核心的垃圾車資料流（包含即時與預測）。
/// 本文件充當了 UI（MapScreen）與 Service 層（GarbageService, DatabaseService）之間的協調器。
///
/// [執行順序說明]
/// 1. 監聽 `citySelectionProvider`，當城市變更時觸發 `GarbageTrucksNotifier` 的重新建構。
/// 2. `GarbageTrucksNotifier` 初始化時呼叫對應 Service 的 `syncDataIfNeeded` 進行資料庫同步。
/// 3. 啟動 `Timer.periodic` 每 30 秒呼叫一次 `refresh()` 獲取 API 最新動態。
/// 4. `predictedTrucksProvider` 根據目前是否處於「預測模式」決定要回傳 API 即時資料還是資料庫班表資料。
/// 5. UI 層訂閱上述 Provider 並隨之自動重繪。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../models/garbage_truck.dart';
import '../models/garbage_route_point.dart';
import '../models/city_config.dart';
import '../services/ntpc_garbage_service.dart';
import '../services/taipei_garbage_service.dart';
import '../services/taichung_garbage_service.dart';
import '../services/tainan_garbage_service.dart';
import '../services/kaohsiung_garbage_service.dart';
import '../services/database_service.dart';

/// 城市選擇狀態管理。
/// 
/// 記錄使用者目前選擇查詢的城市，預設為 'ntpc' (新北市)。
final citySelectionProvider = NotifierProvider<CitySelectionNotifier, String>(CitySelectionNotifier.new);

/// [CitySelectionNotifier] 負責管理城市切換邏輯。
class CitySelectionNotifier extends Notifier<String> {
  @override
  String build() => 'ntpc';
  
  /// 設定當前選擇的城市。
  /// [city] 城市代碼。
  void setCity(String city) => state = city;
}

/// 垃圾清運服務實體 Provider。
/// 
/// 負責根據當前城市配置，動態實例化對應的 Service 類別。
final garbageServiceProvider = Provider<BaseGarbageService>((ref) {
  final config = ref.watch(currentCityConfigProvider);
  BaseGarbageService service;
  
  if (config.cityName == 'taipei') {
    service = TaipeiGarbageService(localSourceDir: config.localSourceDir);
  } else if (config.cityName == 'taichung') {
    service = TaichungGarbageService(localSourceDir: config.localSourceDir);
  } else if (config.cityName == 'tainan') {
    service = TainanGarbageService(localSourceDir: config.localSourceDir);
  } else if (config.cityName == 'kaohsiung') {
    service = KaohsiungGarbageService(localSourceDir: config.localSourceDir);
  } else {
    service = NtpcGarbageService(localSourceDir: config.localSourceDir);
  }

  // 確保在 Provider 銷毀時釋放 Service 資源 (如 http.Client)
  ref.onDispose(() {
    DatabaseService.log('garbageServiceProvider (${config.cityName}) 正在銷毀，執行 dispose...');
    service.dispose();
  });

  return service;
});

/// 顯示來源狀態資訊，用於在 AppBar 顯示資料抓取來源（如：雲端 API 或 資料庫預測）。
final sourceInfoProvider = NotifierProvider<SourceInfoNotifier, String>(SourceInfoNotifier.new);

/// [SourceInfoNotifier] 管理 AppBar 下方的狀態文字。
class SourceInfoNotifier extends Notifier<String> {
  @override
  String build() => '正在初始化...';
  
  /// 更新狀態文字內容。
  /// [msg] 要顯示的訊息。
  void setInfo(String msg) => state = msg;
}

/// 當前城市詳細配置資訊（地圖中心、顏色、路徑）。
final currentCityConfigProvider = Provider<CityConfig>((ref) {
  final city = ref.watch(citySelectionProvider);
  if (city == 'taipei') {
    return CityConfig(
      cityName: 'taipei',
      appTitle: '台北市垃圾車即時地圖',
      initialCenter: const LatLng(25.0330, 121.5654),
      themeColor: Colors.blue,
      localSourceDir: r'D:\CLI\garbage\台北市垃圾車路線',
    );
  } else if (city == 'taichung') {
    return CityConfig(
      cityName: 'taichung',
      appTitle: '台中市垃圾車即時地圖',
      initialCenter: const LatLng(24.1477, 120.6736),
      themeColor: Colors.green,
      localSourceDir: r'D:\CLI\garbage\臺中市定時定點垃圾收運地點',
    );
  } else if (city == 'tainan') {
    return CityConfig(
      cityName: 'tainan',
      appTitle: '台南市垃圾車即時地圖',
      initialCenter: const LatLng(22.9975, 120.2025),
      themeColor: Colors.orange,
      localSourceDir: r'D:\CLI\garbage\台南市垃圾車路線',
    );
  } else if (city == 'kaohsiung') {
    return CityConfig(
      cityName: 'kaohsiung',
      appTitle: '高雄市垃圾車即時地圖',
      initialCenter: const LatLng(22.6273, 120.3014),
      themeColor: Colors.purple,
      localSourceDir: r'D:\CLI\garbage\高雄市垃圾車路線',
    );
  }
  return CityConfig(
    cityName: 'ntpc',
    appTitle: '新北市垃圾車即時地圖',
    initialCenter: const LatLng(25.0125, 121.4650),
    themeColor: Colors.yellow,
    localSourceDir: r'D:\CLI\garbage\新北市垃圾車路線',
  );
});

/// 定位模式：自動 (GPS 定位本人) 或 手動 (在地圖上點擊位置)。
enum LocationMode { auto, manual }

/// [locationModeProvider] 管理當前系統的定位行為。
final locationModeProvider = NotifierProvider<LocationModeNotifier, LocationMode>(LocationModeNotifier.new);

/// [LocationModeNotifier] 負責自動與手動模式的切換。
class LocationModeNotifier extends Notifier<LocationMode> {
  @override
  LocationMode build() => LocationMode.auto;
  
  /// 切換目前的定位模式。
  void toggle() => state = (state == LocationMode.auto ? LocationMode.manual : LocationMode.auto);
}

/// 手動點擊設定的位置座標。
final manualPositionProvider = NotifierProvider<ManualPositionNotifier, LatLng?>(ManualPositionNotifier.new);

/// [ManualPositionNotifier] 記錄手動模式下的選取點位。
class ManualPositionNotifier extends Notifier<LatLng?> {
  @override
  LatLng? build() => null;
  
  /// 設定手動點擊的位置。
  /// [pos] 經緯度座標。
  void setPosition(LatLng? pos) => state = pos;
}

/// 資料庫中當前城市的快取點位數量。
final routeDataCountProvider = NotifierProvider<RouteDataCountNotifier, int>(RouteDataCountNotifier.new);

/// [RouteDataCountNotifier] 管理 UI 顯示的資料筆數。
class RouteDataCountNotifier extends Notifier<int> {
  @override
  int build() => 0;
  
  /// 更新點位總數。
  /// [value] 數量。
  void setCount(int value) => state = value;
}

/// 是否正在執行資料同步作業。
final isSyncingProvider = NotifierProvider<SyncStatusNotifier, bool>(SyncStatusNotifier.new);

/// [SyncStatusNotifier] 告知 UI 是否應顯示載入遮罩。
class SyncStatusNotifier extends Notifier<bool> {
  @override
  bool build() => true;
  
  /// 設定同步狀態。
  /// [value] 是否正在同步。
  void setSyncing(bool value) => state = value;
}

/// 同步過程的具體進度文字。
final syncProgressProvider = NotifierProvider<SyncProgressNotifier, String>(SyncProgressNotifier.new);

/// [SyncProgressNotifier] 提供詳細的同步步驟文字描述。
class SyncProgressNotifier extends Notifier<String> {
  @override
  String build() => '正在檢查快取版本...';
  
  /// 設定進度訊息。
  /// [msg] 文字內容。
  void setProgress(String msg) => state = msg;
}

/// 絕對時間預測模式的目標時間。
final targetTimeProvider = NotifierProvider<TargetTimeNotifier, DateTime?>(TargetTimeNotifier.new);

/// [TargetTimeNotifier] 管理「指定時間查詢」功能的目標點。
class TargetTimeNotifier extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;
  
  /// 設定目標查詢時間。
  /// [time] 完整時間日期物件。
  void setTime(DateTime time) => state = time;
  
  /// 重置時間為 null。
  void reset() => state = null;
}

/// 相對時間預測模式的時間偏移量。
final predictionDurationProvider = NotifierProvider<PredictionDurationNotifier, Duration>(PredictionDurationNotifier.new);

/// [PredictionDurationNotifier] 管理「預測多久後」功能的時間偏移。
class PredictionDurationNotifier extends Notifier<Duration> {
  @override
  Duration build() => Duration.zero;
  
  /// 設定時間偏移量。
  /// [duration] 時長。
  void setDuration(Duration duration) => state = duration;
  
  /// 重置偏移量為零。
  void reset() => state = Duration.zero;
}

/// 最終地圖顯示清單邏輯 Provider。
/// 
/// 這是地圖畫面最重要的資料來源，它整合了即時動態與預測邏輯。
final predictedTrucksProvider = FutureProvider<List<GarbageTruck>>((ref) async {
  final realTimeTrucks = ref.watch(garbageTrucksProvider);
  final duration = ref.watch(predictionDurationProvider);
  final targetTime = ref.watch(targetTimeProvider);
  final service = ref.read(garbageServiceProvider);
  
  List<GarbageTruck> result;
  String sourceLabel = '';

  if (targetTime != null) {
    // 若設定了目標時間，從資料庫查找班表
    result = await service.findTrucksByTime(targetTime.hour, targetTime.minute);
    sourceLabel = '模式: 指定時間查詢 (班表)';
  } else if (duration != Duration.zero) {
    // 若設定了預測時數，計算未來時間並查找班表
    final target = DateTime.now().add(duration);
    result = await service.findTrucksByTime(target.hour, target.minute);
    sourceLabel = '模式: 時間預測 (班表)';
  } else {
    // 預設顯示即時抓取的車輛動態
    result = realTimeTrucks;
    bool isApiData = realTimeTrucks.isNotEmpty && realTimeTrucks.any((t) => t.carNumber != '已過站' && t.carNumber != '預定車');
    sourceLabel = isApiData ? '模式: API 即時位置' : '模式: 資料庫預估 (API暫無回應)';
  }

  // 非同步更新標籤文字
  final finalLabel = '$sourceLabel | 目前顯示: ${result.length} 輛';
  Future.microtask(() {
    ref.read(sourceInfoProvider.notifier).setInfo(finalLabel);
  });

  return result;
});

/// 定期輪詢獲取即時垃圾車動態的狀態管理。
final garbageTrucksProvider = NotifierProvider<GarbageTrucksNotifier, List<GarbageTruck>>(GarbageTrucksNotifier.new);

/// [GarbageTrucksNotifier] 是資料獲取的核心，負責定時向 Service 要求最新位置。
class GarbageTrucksNotifier extends Notifier<List<GarbageTruck>> {
  Timer? _timer;

  /// 初始化建構邏輯。
  @override
  List<GarbageTruck> build() {
    // 監聽城市變更，一旦變更就執行初始化同步與資料更新
    final city = ref.watch(citySelectionProvider);
    state = []; // 切換城市時先清空列表
    
    Future.microtask(() async {
      final service = ref.read(garbageServiceProvider);
      ref.read(isSyncingProvider.notifier).setSyncing(true);
      try {
        // 必要時執行路線資料同步 (如初次啟動或版號更新)
        await service.syncDataIfNeeded(onProgress: (msg) {
          ref.read(syncProgressProvider.notifier).setProgress(msg);
        });
        await _updateCount(city);
        await refresh(); // 初次載入
      } catch (e) {
        DatabaseService.log('背景同步失敗', error: e);
      } finally {
        ref.read(isSyncingProvider.notifier).setSyncing(false);
      }
    });
    
    // 啟動定時輪詢 (每 30 秒)
    _startTimer();
    ref.onDispose(() => _timer?.cancel());
    return [];
  }

  /// 更新當前城市的本地快取資料筆數統計。
  /// [city] 城市代碼。
  Future<void> _updateCount(String city) async {
    final count = await DatabaseService().getTotalCount(city);
    ref.read(routeDataCountProvider.notifier).setCount(count);
  }

  /// 執行資料刷新：從伺服器抓取最新車輛位置。
  Future<void> refresh() async {
    final city = ref.read(citySelectionProvider);
    final service = ref.read(garbageServiceProvider);
    try {
      final trucks = await service.fetchTrucks();
      state = trucks;
      await _updateCount(city);
    } catch (e) {
      DatabaseService.log('即時重新整理失敗', error: e);
    }
  }

  /// 強制重置資料庫版本並重新執行同步程序。
  /// 
  /// 用於使用者手動觸發資料更新，或偵測到本地資料損毀時。
  Future<void> forceUpdateRouteData() async {
    final city = ref.read(citySelectionProvider);
    final service = ref.read(garbageServiceProvider);
    
    final targetTime = ref.read(targetTimeProvider);
    final duration = ref.read(predictionDurationProvider);
    final isPrediction = targetTime != null || duration != Duration.zero;

    if (isPrediction) {
      ref.read(isSyncingProvider.notifier).setSyncing(true);
      try {
        // 設定一個無效的版本號以觸發強制同步
        await DatabaseService().updateVersion('force_refresh_$city', city);
        await service.syncDataIfNeeded(onProgress: (msg) {
          ref.read(syncProgressProvider.notifier).setProgress(msg);
        });
        await _updateCount(city);
        ref.invalidate(predictedTrucksProvider); // 讓 UI 重算
      } finally {
        ref.read(isSyncingProvider.notifier).setSyncing(false);
      }
    } else {
      // 即時模式下，僅需刷新 API 位置
      await refresh();
    }
  }

  /// 定時計時器實作。
  /// 
  /// 負責每 30 秒定期觸發 [refresh]。
  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) => refresh());
  }
}
