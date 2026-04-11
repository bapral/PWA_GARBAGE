/// [整體程式說明]
/// 本文件定義了 [DatabaseService] 類別，負責全系統的 SQLite 持久化儲存管理。
/// 採用單例模式（Singleton）以確保資料庫連線池的一致性。
/// 支援 Web (WASM/FFI) 與 Native (Mobile/Desktop) 雙平台架構。
///
/// [執行順序說明]
/// 1. `get db`：延遲初始化資料庫，首次呼叫時建立 Table 與 Index。
/// 2. `clearAndSaveRoutePointsWithProgress`：高效能大量寫入，支援 Transaction 與 Batch 處理。
/// 3. `findPointsByTime`：提供具備「城市感應」的時間窗口查詢，確保預測結果精準。

import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path/path.dart';
import '../models/garbage_route_point.dart';
import 'package:latlong2/latlong.dart';
import 'package:meta/meta.dart';
import 'package:flutter/foundation.dart';

/// 資料庫服務類別，封裝所有 SQLite 操作邏輯。
class DatabaseService {
  static DatabaseService _instance = DatabaseService._internal();
  
  /// 取得 [DatabaseService] 唯一的實例。
  factory DatabaseService() => _instance;
  
  DatabaseService._internal();

  /// 僅用於單元測試：重設單例狀態。
  @visibleForTesting
  static void resetInstance() {
    _db?.close();
    _db = null;
    _instance = DatabaseService._internal();
  }

  static Database? _db;
  static const String tableName = 'route_points';
  static const String metaTable = 'metadata';
  static String? _customPath;

  /// 全域日誌記錄功能。
  /// [message] 日誌文字。
  /// [error] 錯誤物件。
  /// [stackTrace] 堆疊追蹤。
  static Future<void> log(String message, {Object? error, StackTrace? stackTrace}) async {
    final now = DateTime.now();
    final logStr = '[$now] $message${error != null ? '\nError: $error' : ''}${stackTrace != null ? '\nStackTrace: $stackTrace' : ''}\n---\n';
    debugPrint(logStr);
  }

  /// 獲取開啟的資料庫實體。
  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  /// 執行資料庫初始化與遷移。
  Future<Database> _initDb() async {
    try {
      await log('正在初始化資料庫實體...');
      if (kIsWeb) {
        try {
          // 預設嘗試使用 Web 模式 (持久化)
          databaseFactory = databaseFactoryFfiWeb;
          await log('sqflite web 啟動中...');
        } catch (e) {
          await log('sqflite web 失敗，降級為記憶體模式', error: e);
          databaseFactory = databaseFactoryFfi;
        }
      } else {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      
      String path = _customPath ?? (kIsWeb ? 'garbage_map_v5.db' : join(await getDatabasesPath(), 'garbage_map_v3.db'));
      
      return await openDatabase(
        path,
        version: 2,
        onCreate: (db, version) async {
          // 建立主資料表與元數據表
          await db.execute('CREATE TABLE $tableName (lineId TEXT, lineName TEXT, rank INTEGER, name TEXT, latitude REAL, longitude REAL, arrivalTime TEXT, city TEXT)');
          await db.execute('CREATE TABLE $metaTable (key TEXT PRIMARY KEY, value TEXT)');
          // 建立索引以加速查詢
          await db.execute('CREATE INDEX idx_lineId ON $tableName (lineId)');
          await db.execute('CREATE INDEX idx_time ON $tableName (arrivalTime)');
          await db.execute('CREATE INDEX idx_city ON $tableName (city)');
        },
      );
    } catch (e) {
      await log('資料庫初始化崩潰，改用記憶體資料庫', error: e);
      databaseFactory = databaseFactoryFfi;
      return await openDatabase(inMemoryDatabasePath, version: 1);
    }
  }

  /// 獲取特定城市的資料版本號。
  Future<String?> getStoredVersion(String city) async {
    final database = await db;
    final List<Map<String, dynamic>> maps = await database.query(metaTable, where: 'key = ?', whereArgs: ['app_version_$city']);
    return maps.isNotEmpty ? maps.first['value'] : null;
  }

  /// 更新特定城市的資料版本號。
  Future<void> updateVersion(String version, String city) async {
    final database = await db;
    await database.insert(metaTable, {'key': 'app_version_$city', 'value': version}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 清除指定城市的點位資料。
  Future<void> clearAllRoutePoints(String city) async {
    final database = await db;
    await database.delete(tableName, where: 'city = ?', whereArgs: [city]);
  }

  /// 儲存點位資料（含交易處理）。
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

  /// 高效能批次寫入：清除並重新儲存，具備進度回調。
  Future<void> clearAndSaveRoutePointsWithProgress(
    List<GarbageRoutePoint> points, 
    String city, 
    void Function(int saved, int total)? onProgress
  ) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete(tableName, where: 'city = ?', whereArgs: [city]);
      
      const int batchSize = 1000;
      for (int i = 0; i < points.length; i += batchSize) {
        final batch = txn.batch();
        int end = (i + batchSize < points.length) ? i + batchSize : points.length;
        
        for (var j = i; j < end; j++) {
          final p = points[j];
          batch.insert(tableName, {
            'lineId': p.lineId, 'lineName': p.lineName, 'rank': p.rank, 'name': p.name,
            'latitude': p.position.latitude, 'longitude': p.position.longitude, 'arrivalTime': p.arrivalTime,
            'city': city,
          });
        }
        await batch.commit(noResult: true);
        onProgress?.call(end, points.length);
      }
    });
  }

  /// 獲取點位總數。
  Future<int> getTotalCount([String? city]) async {
    final database = await db;
    if (city != null) {
      return Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM $tableName WHERE city = ?', [city])) ?? 0;
    }
    return Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM $tableName')) ?? 0;
  }

  /// 檢查某城市是否已有資料。
  Future<bool> hasData(String city) async => (await getTotalCount(city)) > 0;

  /// 根據時間查詢符合時段的班表點位。
  /// [hour] 小時。
  /// [minute] 分鐘。
  /// [city] 城市識別。
  Future<List<GarbageRoutePoint>> findPointsByTime(int hour, int minute, String city) async {
    final database = await db;
    
    // 根據城市特性設定不同的查詢時間窗口
    int beforeOffset;
    int afterOffset;
    
    if (city == 'taipei' || city == 'ntpc') {
      beforeOffset = -5;
      afterOffset = 10;
    } else if (city == 'taichung') {
      beforeOffset = -15;
      afterOffset = 15;
    } else {
      beforeOffset = -10;
      afterOffset = 15;
    }

    final String start = _offsetTime(hour, minute, beforeOffset);
    final String end = _offsetTime(hour, minute, afterOffset);
    
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

  /// 輔助函式：計算時間位移。
  String _offsetTime(int h, int m, int offset) {
    int total = h * 60 + m + offset;
    if (total < 0) total = 0; if (total > 1439) total = 1439;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }

  /// 獲取單一路線的所有順序點位。
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
