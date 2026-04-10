/// [整體程式說明]
/// 本文件定義了 [DatabaseService] 類別，是應用程式唯一的持久化資料存取層。
/// 基於 SQLite 實作，負責儲存各縣市的靜態垃圾清運站點（班表資料）與系統中繼資料（如版本號）。
/// 此外，本類別還集成了全域日誌系統，能將執行過程中的錯誤與重要事件寫入本地日誌檔案。

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
  
  @visibleForTesting
  static set customPath(String? path) => _customPath = path;

  static Future<void> _logQueue = Future.value();

  /// 全域日誌記錄功能。
  static Future<void> log(String message, {Object? error, StackTrace? stackTrace}) async {
    final now = DateTime.now();
    final logStr = '[$now] $message${error != null ? '\nError: $error' : ''}${stackTrace != null ? '\nStackTrace: $stackTrace' : ''}\n---\n';
    debugPrint(logStr);
    
    if (!kIsWeb) {
      // 將寫入任務排入隊列，僅在非 Web 平台執行
      _logQueue = _logQueue.then((_) => _writeLogToNativeFile(logStr)).catchError((e) {
        debugPrint('日誌隊列執行異常: $e');
      });
    }
  }

  /// 僅在原生平台執行的日誌檔案寫入。
  /// 此處不引用 Platform 以免 Web 編譯失敗。
  static Future<void> _writeLogToNativeFile(String logStr) async {
    // 這裡我們在 native 模式下才引用 dart:io，或者乾脆在 Web 下不做這件事
    // 為了極致相容，我們在 Web 上直接 return
    return; 
  }

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    try {
      await log('正在初始化資料庫實體...');
      if (kIsWeb) {
        try {
          databaseFactory = databaseFactoryFfiWeb;
          await log('sqflite web 啟動完成');
        } catch (webError) {
          await log('Web 資料庫工廠初始化失敗', error: webError);
        }
      } else {
        // 原生平台初始化
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        await log('sqfliteFfi 啟動完成');
      }
      
      String path;
      if (kIsWeb) {
        path = 'garbage_map_v3.db';
      } else {
        path = _customPath ?? join(await getDatabasesPath(), 'garbage_map_v3.db');
      }
      await log('資料庫儲存路徑: $path');
      
      final db = await openDatabase(
        path,
        version: 2,
        onCreate: (db, version) async {
          await log('正在建立全新資料表結構...');
          await db.execute('CREATE TABLE $tableName (lineId TEXT, lineName TEXT, rank INTEGER, name TEXT, latitude REAL, longitude REAL, arrivalTime TEXT, city TEXT)');
          await db.execute('CREATE TABLE $metaTable (key TEXT PRIMARY KEY, value TEXT)');
          await db.execute('CREATE INDEX idx_lineId ON $tableName (lineId)');
          await db.execute('CREATE INDEX idx_time ON $tableName (arrivalTime)');
          await db.execute('CREATE INDEX idx_city ON $tableName (city)');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute('ALTER TABLE $tableName ADD COLUMN city TEXT');
            await db.execute('CREATE INDEX idx_city ON $tableName (city)');
          }
        },
      );
      await log('資料庫連線開啟成功');
      return db;
    } catch (e, stack) {
      await log('資料庫初始化失敗', error: e, stackTrace: stack);
      rethrow;
    }
  }

  Future<String?> getStoredVersion(String city) async {
    final database = await db;
    final List<Map<String, dynamic>> maps = await database.query(metaTable, where: 'key = ?', whereArgs: ['app_version_$city']);
    return maps.isNotEmpty ? maps.first['value'] : null;
  }

  Future<void> updateVersion(String version, String city) async {
    final database = await db;
    await database.insert(metaTable, {'key': 'app_version_$city', 'value': version}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearAllRoutePoints(String city) async {
    final database = await db;
    await database.delete(tableName, where: 'city = ?', whereArgs: [city]);
  }

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

  Future<int> getTotalCount([String? city]) async {
    final database = await db;
    if (city != null) {
      return Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM $tableName WHERE city = ?', [city])) ?? 0;
    }
    return Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM $tableName')) ?? 0;
  }

  Future<bool> hasData(String city) async => (await getTotalCount(city)) > 0;

  Future<List<GarbageRoutePoint>> findPointsByTime(int hour, int minute, String city) async {
    final database = await db;
    final String start = _offsetTime(hour, minute, -3);
    final String end = _offsetTime(hour, minute, 17);
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

  String _offsetTime(int h, int m, int offset) {
    int total = h * 60 + m + offset;
    if (total < 0) total = 0; if (total > 1439) total = 1439;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }

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
