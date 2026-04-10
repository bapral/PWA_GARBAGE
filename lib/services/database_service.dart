/// [整體程式說明]
/// 本文件定義了 [DatabaseService] 類別，是應用程式唯一的持久化資料存取層。
/// 基於 SQLite 實作，負責儲存各縣市的靜態垃圾清運站點（班表資料）與系統中繼資料（如版本號）。
/// 此外，本類別還集成了全域日誌系統，能將執行過程中的錯誤與重要事件寫入本地日誌檔案。
///
/// [執行順序說明]
/// 1. 透過單例模式 `DatabaseService()` 獲取實例。
/// 2. 首次存取 `db` 屬性時，觸發 `_initDb` 進行 SQLite 引擎初始化（包含 Windows FFI 設定）。
/// 3. 若資料庫不存在，則執行 `onCreate` 建立資料表與索引。
/// 4. 服務層透過 `getStoredVersion` 檢查是否需要同步資料。
/// 5. 執行 `saveRoutePoints` 或 `clearAndSaveRoutePoints` 進行批量資料寫入。
/// 6. `findPointsByTime` 根據時間演算法從資料庫檢索符合時段的清運點位。

import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path/path.dart';
import '../models/garbage_route_point.dart';
import 'package:latlong2/latlong.dart';
import 'package:meta/meta.dart';
import 'package:flutter/foundation.dart';

/// [DatabaseService] 類別負責本地 SQLite 資料庫的生命週期管理與資料存取。
/// 
/// 支援跨平台（Windows, Android, iOS, Linux），並整合了日誌寫入功能。
class DatabaseService {
  // 單例模式實作
  static DatabaseService _instance = DatabaseService._internal();
  
  /// 獲取 [DatabaseService] 的單例實例。
  factory DatabaseService() => _instance;
  
  /// 內部分建構子。
  DatabaseService._internal();

  /// 專供單元測試使用的重置方法。
  /// 
  /// 用於清除目前資料庫連線並重新初始化單例，確保測試環境的純淨。
  @visibleForTesting
  static void resetInstance() {
    _db?.close();
    _db = null;
    _instance = DatabaseService._internal();
  }

  static Database? _db;
  /// 儲存清運路線點位的資料表名稱。
  static const String tableName = 'route_points';
  /// 儲存系統中繼資料（如版本資訊）的資料表名稱。
  static const String metaTable = 'metadata';
  
  // 自定義路徑，便於測試時切換至記憶體資料庫
  static String? _customPath;
  
  /// 設定自定義資料庫儲存路徑（僅供測試使用）。
  @visibleForTesting
  static set customPath(String? path) => _customPath = path;

  // 用於確保日誌順序寫入的 Future 鏈接，避免 Windows 檔案鎖定衝突
  static Future<void> _logQueue = Future.value();

  /// 全域日誌記錄功能。
  /// 
  /// 會同步顯示在控制台，並非同步順序寫入本地檔案，方便離線偵錯。
  /// [message] 日誌文字內容。
  /// [error] 選擇性傳入的錯誤物件。
  /// [stackTrace] 選擇性傳入的堆疊資訊。
  static Future<void> log(String message, {Object? error, StackTrace? stackTrace}) async {
    final now = DateTime.now();
    final logStr = '[$now] $message${error != null ? '\nError: $error' : ''}${stackTrace != null ? '\nStackTrace: $stackTrace' : ''}\n---\n';
    debugPrint(logStr);
    
    // 將寫入任務排入隊列，確保順序執行
    _logQueue = _logQueue.then((_) => _writeLogToFile(logStr)).catchError((e) {
      debugPrint('日誌隊列執行異常: $e');
    });
  }

  /// 將日誌字串附加至本地日誌檔。
  /// 
  /// 根據作業系統環境變數決定儲存位置。
  /// [logStr] 已格式化的日誌字串。
  static Future<void> _writeLogToFile(String logStr) async {
    try {
      if (kIsWeb) return;
      String? logPath;
      if (Platform.isWindows) {
        final localAppData = Platform.environment['LOCALAPPDATA'];
        if (localAppData != null) {
          logPath = join(localAppData, 'garbage_map_debug.log');
        }
      } else if (Platform.isLinux || Platform.isMacOS) {
        logPath = join(Platform.environment['HOME'] ?? '.', 'garbage_map_debug.log');
      }
      
      if (logPath != null) {
        final file = File(logPath);
        // 使用 append 模式確保舊日誌不被覆蓋，flush 確保即時寫入磁碟
        await file.writeAsString(logStr, mode: FileMode.append, flush: true);
      }
    } catch (e) {
      // 這裡不使用 log() 以免造成無窮遞迴
      debugPrint('日誌檔案寫入失敗 (File: $logStr): $e');
    }
  }

  /// 獲取已初始化的資料庫實體。
  /// 
  /// 採延遲載入（Lazy loading）模式，若尚未初始化則呼叫 [_initDb]。
  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  /// 初始化 SQLite 資料庫。
  /// 
  /// 針對桌面端 (Windows) 啟動 FFI 支援，並建立資料表與索引。
  /// 回傳建構完成的 [Database] 實例。
  Future<Database> _initDb() async {
    try {
      await log('正在初始化資料庫實體...');
      if (kIsWeb) {
        try {
          databaseFactory = databaseFactoryFfiWeb;
          await log('sqflite web 啟動完成');
        } catch (webError) {
          await log('Web 資料庫工廠初始化失敗，嘗試降級', error: webError);
          // 這裡可以考慮不設定 factory，讓它拋出更明顯的錯誤或使用記憶體模擬
        }
      } else if (Platform.isWindows || Platform.isLinux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        await log('sqfliteFfi 啟動完成');
      }
      
      // 組合資料庫路徑
      String path;
      if (kIsWeb) {
        path = 'garbage_map_v3.db';
      } else {
        path = _customPath ?? join(await getDatabasesPath(), 'garbage_map_v3.db');
      }
      await log('資料庫儲存路徑: $path');
      
      final db = await openDatabase(
        path,
        version: 2, // 版本 2 引入了 'city' 欄位
        onCreate: (db, version) async {
          await log('正在建立全新資料表結構...');
          // 點位資料表
          await db.execute('CREATE TABLE $tableName (lineId TEXT, lineName TEXT, rank INTEGER, name TEXT, latitude REAL, longitude REAL, arrivalTime TEXT, city TEXT)');
          // 中繼資料表
          await db.execute('CREATE TABLE $metaTable (key TEXT PRIMARY KEY, value TEXT)');
          // 建立索引以提升大量資料查詢速度
          await db.execute('CREATE INDEX idx_lineId ON $tableName (lineId)');
          await db.execute('CREATE INDEX idx_time ON $tableName (arrivalTime)');
          await db.execute('CREATE INDEX idx_city ON $tableName (city)');
          await log('資料表建立完成');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await log('偵測到版本更新：從 $oldVersion 升級至 $newVersion');
          if (oldVersion < 2) {
            // 從版本 1 升級上來的處理邏輯
            await db.execute('ALTER TABLE $tableName ADD COLUMN city TEXT');
            await db.execute('CREATE INDEX idx_city ON $tableName (city)');
          }
          await log('資料庫升級完成');
        },
      );
      await log('資料庫連線開啟成功');
      return db;
    } catch (e, stack) {
      await log('資料庫初始化失敗，可能造成功能異常', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// 獲取特定城市當前快取的資料版本標籤。
  /// 
  /// [city] 城市代碼。
  /// 回傳版本字串，若無紀錄則為 null。
  Future<String?> getStoredVersion(String city) async {
    final database = await db;
    final List<Map<String, dynamic>> maps = await database.query(metaTable, where: 'key = ?', whereArgs: ['app_version_$city']);
    return maps.isNotEmpty ? maps.first['value'] : null;
  }

  /// 更新特定城市的資料版本紀錄。
  /// 
  /// [version] 新的版本標籤。
  /// [city] 城市代碼。
  Future<void> updateVersion(String version, String city) async {
    final database = await db;
    await database.insert(metaTable, {'key': 'app_version_$city', 'value': version}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 刪除特定城市在資料庫中的所有快取點位。
  /// 
  /// [city] 城市代碼。
  Future<void> clearAllRoutePoints(String city) async {
    final database = await db;
    await database.delete(tableName, where: 'city = ?', whereArgs: [city]);
  }

  /// 批量寫入路線點位（高效能）。
  /// 
  /// [points] 點位清單。
  /// [city] 城市代碼。
  Future<void> saveRoutePoints(List<GarbageRoutePoint> points, String city) async {
    final database = await db;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (var p in points) {
        batch.insert(tableName, {
          'lineId': p.lineId, 'lineName': p.lineName, 'rank': p.rank, 'name': p.name,
          'latitude': p.position.latitude, 'longitude': p.position.longitude, 'arrivalTime': p.arrivalTime,
          'city': city,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// 原子操作：同步資料時先刪除舊資料再插入新資料。
  /// 
  /// 使用事務（Transaction）確保資料的一致性與操作原子性。
  /// [points] 點位清單。
  /// [city] 城市代碼。
  Future<void> clearAndSaveRoutePoints(List<GarbageRoutePoint> points, String city) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete(tableName, where: 'city = ?', whereArgs: [city]);
      final batch = txn.batch();
      for (var p in points) {
        batch.insert(tableName, {
          'lineId': p.lineId, 'lineName': p.lineName, 'rank': p.rank, 'name': p.name,
          'latitude': p.position.latitude, 'longitude': p.position.longitude, 'arrivalTime': p.arrivalTime,
          'city': city,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// 查詢總點位數量。
  /// 
  /// [city] 選擇性傳入城市代碼，若無則查詢全體。
  /// 回傳整數總計筆數。
  Future<int> getTotalCount([String? city]) async {
    final database = await db;
    if (city != null) {
      return Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM $tableName WHERE city = ?', [city])) ?? 0;
    }
    return Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM $tableName')) ?? 0;
  }

  /// 判斷特定城市是否有快取資料。
  /// 
  /// [city] 城市代碼。
  /// 回傳布林值。
  Future<bool> hasData(String city) async => (await getTotalCount(city)) > 0;

  /// 核心查詢邏輯：找出指定時間區間內的清運點位。
  /// 
  /// [hour], [minute] 為使用者指定的基準點。
  /// [city] 城市代碼。
  /// 查詢邏輯：查詢基準點前 3 分鐘至後 17 分鐘內的所有站點。
  /// 回傳符合條件的 [GarbageRoutePoint] 清單。
  Future<List<GarbageRoutePoint>> findPointsByTime(int hour, int minute, String city) async {
    final database = await db;
    final String start = _offsetTime(hour, minute, -3);
    final String end = _offsetTime(hour, minute, 17);
    
    await log('執行班表查詢: city=$city, 時段範圍 $start ~ $end');
    
    final List<Map<String, dynamic>> maps = await database.query(
      tableName, 
      where: "arrivalTime >= ? AND arrivalTime <= ? AND city = ?", 
      whereArgs: [start, end, city]
    );
    return maps.map((m) => GarbageRoutePoint(
      lineId: m['lineId'] ?? '', lineName: m['lineName'] ?? '', rank: m['rank'] ?? 0, name: m['name'] ?? '',
      position: LatLng(m['latitude'] ?? 0, m['longitude'] ?? 0), arrivalTime: m['arrivalTime'] ?? '',
    )).toList();
  }

  /// 計算時間偏移量並標準化為 HH:mm 格式。
  /// 
  /// [h] 小時，[m] 分鐘，[offset] 偏移分鐘。
  /// 回傳格式化字串。
  String _offsetTime(int h, int m, int offset) {
    int total = h * 60 + m + offset;
    // 邊界檢查
    if (total < 0) total = 0; if (total > 1439) total = 1439;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }

  /// 根據路線編號 (lineId) 獲取完整行駛路徑站點。
  /// 
  /// [lineId] 路線 ID。
  /// [city] 城市代碼。
  /// 回傳依 [rank] 排序的 [GarbageRoutePoint] 清單。
  Future<List<GarbageRoutePoint>> getRoutePoints(String lineId, String city) async {
    final database = await db;
    final List<Map<String, dynamic>> maps = await database.query(
      tableName, 
      where: 'lineId = ? AND city = ?', 
      whereArgs: [lineId, city], 
      orderBy: 'rank ASC'
    );
    return maps.map((m) => GarbageRoutePoint(
      lineId: m['lineId'], lineName: m['lineName'], rank: m['rank'], name: m['name'],
      position: LatLng(m['latitude'], m['longitude']), arrivalTime: m['arrivalTime'],
    )).toList();
  }
}
