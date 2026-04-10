import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path/path.dart';
import '../models/garbage_route_point.dart';
import 'package:latlong2/latlong.dart';
import 'package:meta/meta.dart';
import 'package:flutter/foundation.dart';

class DatabaseService {
  static DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

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
  static Future<void> _logQueue = Future.value();

  static Future<void> log(String message, {Object? error, StackTrace? stackTrace}) async {
    final now = DateTime.now();
    final logStr = '[$now] $message${error != null ? '\nError: $error' : ''}${stackTrace != null ? '\nStackTrace: $stackTrace' : ''}\n---\n';
    debugPrint(logStr);
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
      
      String path = _customPath ?? (kIsWeb ? 'garbage_map_v4.db' : join(await getDatabasesPath(), 'garbage_map_v3.db'));
      
      return await openDatabase(
        path,
        version: 2,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE $tableName (lineId TEXT, lineName TEXT, rank INTEGER, name TEXT, latitude REAL, longitude REAL, arrivalTime TEXT, city TEXT)');
          await db.execute('CREATE TABLE $metaTable (key TEXT PRIMARY KEY, value TEXT)');
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
    // 擴大查詢範圍：前後 30 分鐘，增加預測模式的命中率
    final String start = _offsetTime(hour, minute, -30);
    final String end = _offsetTime(hour, minute, 30);
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
