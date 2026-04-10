/// [整體程式說明]
/// 本文件定義了 [MapScreen] 元件，是應用程式的核心使用者介面。
/// 負責整合 Flutter Map 插件進行地圖渲染，顯示垃圾車的即時位置與預測點位，
/// 並提供多樣化的互動功能，如：切換縣市、搜尋最近車輛、設定預測時間、以及切換定位模式。
///
/// [執行順序說明]
/// 1. `initState` 時執行 `_determinePosition` 獲取使用者初始 GPS 位置。
/// 2. 監聽 `predictedTrucksProvider` 以獲取當前地圖應顯示的車輛清單（包含即時或預測）。
/// 3. 若 `isSyncing` 為真，顯示同步進度畫面。
/// 4. 建立 `FlutterMap` 元件，包含 `TileLayer`（底圖）、`PolylineLayer`（輔助線）與 `MarkerLayer`（車輛標記）。
/// 5. 使用者點擊標記或按鈕時，觸發 `_showTruckInfo` 或 `_findNearestTruck` 等邏輯方法。
/// 6. 透過 `MapController` 進行視角的平滑移動與縮放。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../providers/garbage_provider.dart';
import '../models/garbage_truck.dart';
import '../services/database_service.dart';

/// 地圖主畫面類別，負責地圖渲染、圖層顯示與使用者互動。
/// 
/// 繼承自 [ConsumerStatefulWidget] 以便使用 Riverpod 的 [ref] 來存取狀態。
class MapScreen extends ConsumerStatefulWidget {
  /// 建立 [MapScreen] 實例。
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

/// [MapScreen] 的狀態管理類別。
/// 
/// 處理地圖控制器、GPS 定位、UI 互動邏輯以及狀態監聽。
class _MapScreenState extends ConsumerState<MapScreen> {
  // 地圖控制器，用於控制地圖縮放、移動等
  final MapController _mapController = MapController();
  
  // 目前使用者的 GPS 位置（自動定位模式下使用）
  Position? _userPosition; 
  
  // 地圖上的連線路徑：
  // 1. _nearestPolyline: 指向距離最近目標的連線
  // 2. _selectedPolyline: 點擊特定車輛後顯示的連線
  Polyline? _nearestPolyline; 
  Polyline? _selectedPolyline; 
  
  // 底部資訊卡片顯示的文字資訊
  String? _routeInfo; 

  @override
  void initState() {
    super.initState();
    DatabaseService.log('MapScreen 進入 initState');
    // 初始化時嘗試獲取 GPS 權限與當前位置
    _determinePosition(); 
  }

  /// 獲取使用者當前的 GPS 位置，並處理權限要求。
  /// 
  /// 此方法會依序檢查定位服務是否啟用、權限是否獲得，最後更新 [_userPosition] 並移動地圖。
  Future<void> _determinePosition() async {
    DatabaseService.log('正在獲取 GPS 定位...');
    // 檢查定位服務是否開啟
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      DatabaseService.log('GPS 定位服務未啟用');
      return;
    }

    // 檢查並要求定位權限
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        DatabaseService.log('GPS 定位權限被拒絕');
        return;
      }
    }

    // 獲取當前經緯度
    final pos = await Geolocator.getCurrentPosition();
    DatabaseService.log('GPS 定位獲取成功: ${pos.latitude}, ${pos.longitude}');
    if (mounted) {
      setState(() {
        _userPosition = pos;
      });
      // 若目前的定位模式為「自動」，地圖視野將自動移動至使用者所在位置
      if (ref.read(locationModeProvider) == LocationMode.auto) {
        try {
          _mapController.move(LatLng(pos.latitude, pos.longitude), 15);
        } catch (e) {
          debugPrint('MapController 尚未就緒: $e');
        }
      }
    }
  }

  /// 根據目前的模式 (自動/手動)，回傳有效的參考座標。
  /// 
  /// 自動模式回傳 GPS 位置，手動模式回傳地圖點擊位置。
  /// 回傳 [LatLng] 座標，若無位置資訊則回傳 null。
  LatLng? _getEffectiveUserLatLng() {
    final mode = ref.read(locationModeProvider);
    if (mode == LocationMode.manual) {
      return ref.read(manualPositionProvider);
    }
    return _userPosition != null ? LatLng(_userPosition!.latitude, _userPosition!.longitude) : null;
  }

  /// 清除地圖上的所有輔助連線與資訊框。
  /// 
  /// 重置 [_nearestPolyline]、[_selectedPolyline] 與 [_routeInfo] 為 null。
  void _clearAllPolylines() {
    setState(() {
      _nearestPolyline = null;
      _selectedPolyline = null;
      _routeInfo = null;
    });
  }

  /// 核心功能：搜尋距離參考座標最近的一台垃圾車。
  /// 
  /// 並在地圖上劃出一條輔助線，同時自動縮放視野以顯示兩端。
  /// [trucks] 為目前地圖上所有可見的垃圾車清單。
  void _findNearestTruck(List<GarbageTruck> trucks) {
    DatabaseService.log('執行「搜尋最近垃圾車」功能，候選車輛筆數: ${trucks.length}');
    final userLatLng = _getEffectiveUserLatLng();
    if (userLatLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請先獲取位置或在地圖上手動指定地點')));
      return;
    }

    if (trucks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('此時段下沒有可用的垃圾車資訊')));
      return;
    }

    final distanceCalc = const Distance();
    GarbageTruck? nearestTruck;
    double minDistance = double.infinity;

    // 遍歷所有車輛找出距離最短者
    for (var truck in trucks) {
      final d = distanceCalc.as(LengthUnit.Meter, userLatLng, truck.position);
      if (d < minDistance) {
        minDistance = d;
        nearestTruck = truck;
      }
    }

    if (nearestTruck != null) {
      DatabaseService.log('找到最近車輛: ${nearestTruck.carNumber}, 距離: ${minDistance.toInt()} 公尺');
      setState(() {
        _selectedPolyline = null; // 清除點選線條
        _nearestPolyline = Polyline(
          points: [userLatLng, nearestTruck!.position],
          color: Colors.green.withValues(alpha: 0.8),
          strokeWidth: 2.0,
        );
        // 粗估步行時間 (設定每分鐘步行約 83 公尺)
        final minutes = (minDistance / 83).ceil();
        _routeInfo = '最近目標: ${nearestTruck!.carNumber}\n距離: ${minDistance.toInt()} 公尺 (步行約 $minutes 分鐘)';
      });

      // 自動調整視野（Bounds Fit）
      final bounds = LatLngBounds.fromPoints([userLatLng, nearestTruck.position]);
      _mapController.fitCamera(CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(100)));
      
      // 顯示該車輛的詳細資訊底板
      _showTruckInfo(nearestTruck);
    }
  }

  /// 構建畫面的 UI 結構。
  /// 
  /// [context] 建構上下文。
  /// 回傳 [Scaffold] 元件，包含 AppBar、Body（Map）與 FloatingActionButton。
  @override
  Widget build(BuildContext context) {
    // 透過 Riverpod 監聽各項狀態
    final config = ref.watch(currentCityConfigProvider);
    final isSyncing = ref.watch(isSyncingProvider);
    final trucksAsync = ref.watch(predictedTrucksProvider);
    final duration = ref.watch(predictionDurationProvider);
    final targetTime = ref.watch(targetTimeProvider);
    final locationMode = ref.watch(locationModeProvider);
    final manualPos = ref.watch(manualPositionProvider);
    
    // 判斷目前的顯示狀態 (即時、相對預測、絕對時間)
    bool isAbsolute = targetTime != null;
    bool isRelative = duration != Duration.zero;
    bool isNow = !isAbsolute && !isRelative;

    // UI 色彩計算 (確保文字在主題色上清晰)
    final isDarkColor = config.themeColor.computeLuminance() < 0.5;
    final appBarTitleColor = isDarkColor ? Colors.white : Colors.black87;
    final appBarSubtitleColor = isDarkColor ? Colors.white70 : Colors.black54;

    // 當系統正在同步或初始化大筆路線資料時的顯示畫面
    if (isSyncing) {
      final progressMsg = ref.watch(syncProgressProvider);
      return Scaffold(
        appBar: AppBar(
          title: Text('系統初始化...', style: TextStyle(fontWeight: FontWeight.bold, color: appBarTitleColor)),
          backgroundColor: config.themeColor[800],
          elevation: 2,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(strokeWidth: 6, color: config.themeColor[800]),
              const SizedBox(height: 30),
              Text(progressMsg, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 15),
              const Text('若遇到卡住，可檢查日誌檔案：', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SelectionArea(child: Text('C:\\Users\\bapral\\AppData\\Local\\garbage_map_debug.log', style: TextStyle(color: Colors.blueGrey, fontSize: 10))),
            ],
          ),
        ),
      );
    }

    // 狀態列文字顯示
    String predictionText = '';
    if (isNow) {
      predictionText = '目前即時線上車輛';
    } else if (isAbsolute) {
      predictionText = '檢索目標時間: ${targetTime!.hour}:${targetTime.minute.toString().padLeft(2, '0')}';
    } else if (isRelative) {
      predictionText = '預測位置: ${duration.inHours > 0 ? '${duration.inHours}小時' : ''}${duration.inMinutes % 60}分鐘後';
    }

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () {
            // 點擊 AppBar 標題可快速切換定位模式
            ref.read(locationModeProvider.notifier).toggle();
            final newMode = ref.read(locationModeProvider);
            DatabaseService.log('切換定位模式: $newMode');
            _clearAllPolylines();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(newMode == LocationMode.auto ? '已切換為：自動 GPS 定位' : '已切換為：手動指定地點 (請點擊地圖)'),
              duration: const Duration(seconds: 2),
            ));
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(config.appTitle, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: appBarTitleColor)),
                  const SizedBox(width: 5),
                  Icon(locationMode == LocationMode.auto ? Icons.gps_fixed : Icons.edit_location_alt, size: 16, color: appBarSubtitleColor),
                ],
              ),
              Consumer(
                builder: (context, ref, child) {
                  final count = ref.watch(routeDataCountProvider);
                  final sourceInfo = ref.watch(sourceInfoProvider);
                  return SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('快取資料: $count 筆 | 模式: ${locationMode == LocationMode.auto ? "自動 GPS" : "手動指定"}', 
                          style: TextStyle(fontSize: 11, color: appBarSubtitleColor)),
                        Text(sourceInfo, style: TextStyle(fontSize: 10, color: appBarSubtitleColor, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        backgroundColor: config.themeColor[800],
        iconTheme: IconThemeData(color: appBarTitleColor),
        elevation: 4,
        actions: [
          IconButton(
            icon: const Icon(Icons.location_city),
            onPressed: () => _showCitySelectionDialog(),
            tooltip: '切換縣市',
            color: appBarTitleColor,
          ),
          IconButton(
            icon: Icon(isNow ? Icons.refresh : Icons.auto_graph),
            onPressed: isNow 
              ? () {
                  DatabaseService.log('手動點擊「重新整理」即時車輛');
                  _clearAllPolylines();
                  ref.read(garbageTrucksProvider.notifier).refresh();
                }
              : () {
                  DatabaseService.log('手動點擊「重置回即時」模式');
                  ref.read(predictionDurationProvider.notifier).reset();
                  ref.read(targetTimeProvider.notifier).reset();
                  _clearAllPolylines();
                },
            tooltip: isNow ? '重新整理' : '重置回即時',
            color: appBarTitleColor,
          ),
          IconButton(
            icon: const Icon(Icons.timer),
            onPressed: () => _showPredictionDialog(),
            tooltip: '開啟預測模式',
            color: appBarTitleColor,
          ),
          PopupMenuButton<String>(
            iconColor: appBarTitleColor,
            onSelected: (value) {
              if (value == 'update') {
                DatabaseService.log('觸發「強制清除並更新資料庫」');
                ref.read(garbageTrucksProvider.notifier).forceUpdateRouteData();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'update', child: Text('強制清除並更新資料庫')),
            ],
          ),
        ],
      ),
      body: trucksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(
          child: SelectionArea(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  const Text('資料載入發生錯誤', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SelectableText(
                    err.toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => ref.read(garbageTrucksProvider.notifier).refresh(),
                    child: const Text('嘗試重新整理'),
                  ),
                ],
              ),
            ),
          ),
        ),
        data: (trucks) => Stack(
          children: [
            // 地圖元件
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: config.initialCenter,
                initialZoom: 14.0,
                onTap: (_, point) {
                  if (ref.read(locationModeProvider) == LocationMode.manual) {
                    DatabaseService.log('手動指定位置: ${point.latitude}, ${point.longitude}');
                    ref.read(manualPositionProvider.notifier).setPosition(point);
                    _clearAllPolylines();
                  } else {
                    _clearAllPolylines();
                  }
                },
              ),
              children: [
                // 開放地圖圖層
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.ntpc_garbage_map',
                ),
                // 連線路徑圖層
                PolylineLayer(
                  polylines: [
                    if (_nearestPolyline != null) _nearestPolyline!,
                    if (_selectedPolyline != null) _selectedPolyline!,
                  ],
                ),
                // 垃圾車標記圖層
                MarkerLayer(
                  markers: trucks.asMap().entries.map((entry) {
                    final index = entry.key;
                    final truck = entry.value;
                    // 使用 索引 + 車號 + 座標 的組合鍵，確保全域唯一性，避免 Duplicate Key 錯誤
                    final key = ValueKey('truck_${truck.carNumber}_${truck.position.latitude}_${truck.position.longitude}_$index');
                    
                    Color cityColor;
                    String cityShort;
                    
                    if (truck.lineId.contains('台北') || config.cityName == 'taipei') {
                      cityColor = Colors.blue[700]!;
                      cityShort = '北';
                    } else if (truck.lineId.contains('台中') || config.cityName == 'taichung') {
                      cityColor = Colors.green[700]!;
                      cityShort = '中';
                    } else if (truck.lineId.contains('新北') || config.cityName == 'ntpc') {
                      cityColor = Colors.orange[800]!;
                      cityShort = '新';
                    } else if (truck.lineId.contains('台南') || config.cityName == 'tainan') {
                      cityColor = Colors.deepOrange[700]!;
                      cityShort = '南';
                    } else if (truck.lineId.contains('高雄') || config.cityName == 'kaohsiung') {
                      cityColor = Colors.purple[700]!;
                      cityShort = '高';
                    } else {
                      cityColor = Colors.grey[700]!;
                      cityShort = '?';
                    }
                    
                    return Marker(
                      key: key,
                      point: truck.position,
                      width: 50,
                      height: 50,
                      child: GestureDetector(
                        onTap: () {
                          DatabaseService.log('選取車輛標記: ${truck.carNumber}');
                          _showTruckInfo(truck);
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // 簡化後的標記背景，減少陰影計算以提升 FPS
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(color: cityColor, width: 2),
                              ),
                            ),
                            Icon(Icons.local_shipping_rounded, color: cityColor, size: 22),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: cityColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 1),
                                ),
                                child: Text(cityShort, style: const TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                // 使用者所在位置標記
                if (locationMode == LocationMode.manual && manualPos != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: manualPos,
                        width: 45,
                        height: 45,
                        child: const Icon(Icons.person_pin_circle, color: Colors.blueAccent, size: 45),
                      ),
                    ],
                  )
                else if (locationMode == LocationMode.auto && _userPosition != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(_userPosition!.latitude, _userPosition!.longitude),
                        width: 40,
                        height: 40,
                        child: const Icon(Icons.person_pin_circle, color: Colors.redAccent, size: 40),
                      ),
                    ],
                  ),
              ],
            ),
            // 頂部當前模式卡片
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Card(
                color: isNow ? Colors.orange[50]?.withValues(alpha: 0.9) : Colors.blue[50]?.withValues(alpha: 0.9),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                  child: Row(
                    children: [
                      Icon(isNow ? Icons.sensors : Icons.event_note, color: isNow ? Colors.orange : Colors.blue),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SelectionArea(
                          child: Text(predictionText, style: TextStyle(fontWeight: FontWeight.bold, color: isNow ? Colors.orange[900] : Colors.blue[900])),
                        ),
                      ),
                      if (!isNow)
                        TextButton(
                          onPressed: () {
                            DatabaseService.log('卡片內點選「回到現在」');
                            ref.read(predictionDurationProvider.notifier).reset();
                            ref.read(targetTimeProvider.notifier).reset();
                            _clearAllPolylines();
                          },
                          child: const Text('回到現在'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // 底部導航/距離卡片
            if (_routeInfo != null)
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Card(
                  color: Colors.yellow[50],
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  child: Padding(
                    padding: const EdgeInsets.all(15),
                    child: Row(
                      children: [
                        const Icon(Icons.directions_walk, color: Colors.orange),
                        const SizedBox(width: 15),
                        Expanded(
                          child: SelectionArea(
                            child: Text(_routeInfo!, style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _nearestPolyline = null;
                            _routeInfo = null;
                          }),
                        )
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // 懸浮按鈕：找最近的垃圾車
          FloatingActionButton(
            heroTag: 'nearest',
            onPressed: () => trucksAsync.whenData((trucks) => _findNearestTruck(trucks)),
            backgroundColor: Colors.green,
            child: const Icon(Icons.near_me, color: Colors.white),
          ),
          const SizedBox(height: 15),
          // 懸浮按鈕：地圖中心點移動到我的位置
          FloatingActionButton(
            heroTag: 'location',
            onPressed: () {
              if (ref.read(locationModeProvider) == LocationMode.auto) {
                DatabaseService.log('FAB: 移動地圖至當前 GPS 位置');
                _determinePosition();
              } else {
                final mPos = ref.read(manualPositionProvider);
                if (mPos != null) {
                  DatabaseService.log('FAB: 移動地圖至手動指定位置');
                  _mapController.move(mPos, 15);
                }
              }
            },
            backgroundColor: config.themeColor[700],
            child: Icon(locationMode == LocationMode.auto ? Icons.my_location : Icons.location_searching, color: Colors.black),
          ),
        ],
      ),
    );
  }

  /// 顯示縣市切換對話框。
  /// 
  /// 使用者點擊切換縣市按鈕後彈出，列出所有支援的城市選項。
  void _showCitySelectionDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('選擇查詢區域'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildCityTile('台北市', 'taipei', Colors.blue),
              const Divider(),
              _buildCityTile('新北市', 'ntpc', Colors.yellow),
              const Divider(),
              _buildCityTile('台中市', 'taichung', Colors.green),
              const Divider(),
              _buildCityTile('台南市', 'tainan', Colors.orange),
              const Divider(),
              _buildCityTile('高雄市', 'kaohsiung', Colors.purple),
            ],
          ),
        );
      },
    );
  }

  /// 建立縣市選擇清單項目。
  /// 
  /// [label] 顯示文字。
  /// [cityKey] 城市 ID。
  /// [color] 代表色。
  /// 回傳 [ListTile] 元件。
  Widget _buildCityTile(String label, String cityKey, Color color) {
    return ListTile(
      leading: Icon(Icons.map, color: color),
      title: Text(label),
      onTap: () {
        DatabaseService.log('選取縣市: $cityKey ($label)');
        ref.read(citySelectionProvider.notifier).setCity(cityKey);
        Navigator.pop(context);
        _onCityChanged();
      },
    );
  }

  /// 處理縣市變更後的 UI 回調。
  /// 
  /// 清除輔助線並將地圖中心點移動至新城市的預設中心。
  void _onCityChanged() {
    _clearAllPolylines();
    final config = ref.read(currentCityConfigProvider);
    DatabaseService.log('縣市已變更，移動地圖中心至: ${config.initialCenter}');
    _mapController.move(config.initialCenter, 14.0);
  }

  /// 顯示預測模式選擇選單。
  /// 
  /// 彈出對話框讓使用者選擇「相對時間預測」、「絕對時間查詢」或「重置回即時」。
  void _showPredictionDialog() {
    DatabaseService.log('顯示預測模式選擇對話框');
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('預測模式設定'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.history, color: Colors.orange),
                title: const Text('相對時間：預測 X 小時 Y 分後'),
                onTap: () {
                  Navigator.pop(context);
                  _showDurationPicker();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.schedule, color: Colors.blue),
                title: const Text('絕對時間：指定特定的時間點'),
                onTap: () async {
                  Navigator.pop(context);
                  final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                  if (time != null) {
                    final now = DateTime.now();
                    final selected = DateTime(now.year, now.month, now.day, time.hour, time.minute);
                    DatabaseService.log('設定絕對預測時間: ${selected.hour}:${selected.minute}');
                    ref.read(targetTimeProvider.notifier).setTime(selected);
                    ref.read(predictionDurationProvider.notifier).reset();
                    _clearAllPolylines();
                  }
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.sensors, color: Colors.green),
                title: const Text('重置模式：回到即時動態'),
                onTap: () {
                  DatabaseService.log('重置預測模式為「即時」');
                  Navigator.pop(context);
                  ref.read(predictionDurationProvider.notifier).reset();
                  ref.read(targetTimeProvider.notifier).reset();
                  _clearAllPolylines();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 顯示相對時間選取器。
  /// 
  /// 讓使用者選取小時與分鐘，設定預測的時間偏移量。
  void _showDurationPicker() {
    int hours = 0;
    int minutes = 30;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('預測多久之後？'),
              content: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  DropdownButton<int>(
                    value: hours,
                    items: List.generate(24, (i) => DropdownMenuItem(value: i, child: Text('$i 小時'))),
                    onChanged: (val) => setState(() => hours = val!),
                  ),
                  DropdownButton<int>(
                    value: minutes,
                    items: List.generate(60, (i) => DropdownMenuItem(value: i, child: Text('$i 分鐘'))),
                    onChanged: (val) => setState(() => minutes = val!),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                ElevatedButton(
                  onPressed: () {
                    DatabaseService.log('設定相對預測時長: $hours 小時 $minutes 分鐘');
                    ref.read(predictionDurationProvider.notifier).setDuration(Duration(hours: hours, minutes: minutes));
                    ref.read(targetTimeProvider.notifier).reset();
                    _clearAllPolylines();
                    Navigator.pop(context);
                  },
                  child: const Text('執行預測'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 顯示單一車輛的詳細資訊面板（BottomSheet）。
  /// 
  /// [truck] 被點擊的垃圾車實例。
  /// 此方法會計算距離、估算步行時間，並顯示車輛的路線與最後更新時間。
  void _showTruckInfo(GarbageTruck truck) {
    String distanceStr = '正在獲取位置...';
    String walkTimeStr = '';

    final userLatLng = _getEffectiveUserLatLng();
    if (userLatLng != null) {
      final distance = const Distance().as(LengthUnit.Meter, userLatLng, truck.position);
      final minutes = (distance / 83).ceil();
      distanceStr = '${distance.toInt()} 公尺';
      walkTimeStr = ' (步行約 $minutes 分鐘)';

      // 點擊車輛時也建立連線輔助顯示
      setState(() {
        _selectedPolyline = Polyline(
          points: [userLatLng, truck.position],
          color: Colors.orange.withValues(alpha: 0.8),
          strokeWidth: 2.0,
        );
      });
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.local_shipping, color: Colors.orange, size: 40),
                  const SizedBox(width: 15),
                  Expanded(child: SelectableText(truck.carNumber, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
                ],
              ),
              const Divider(),
              const SizedBox(height: 10),
              SelectableText('清運路線: ${truck.lineId}', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 5),
              SelectableText('距離估計: $distanceStr$walkTimeStr', style: const TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.bold)),
              const SizedBox(height: 5),
              SelectableText('目前位置描述: ${truck.location}', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 5),
              SelectableText('GPS 更新時間: ${truck.updateTime.hour}:${truck.updateTime.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}
