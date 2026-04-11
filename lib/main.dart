/// [整體程式說明]
/// 本文件為「台灣垃圾車即時地圖」應用程式的啟動核心。
/// 負責 Flutter 引擎初始化、全域錯誤攔截、以及跨平台（Web/Native）的環境設定。
/// 採用 Riverpod 作為全域狀態管理的注入點。
/// 
/// [執行順序說明]
/// 1. `runZonedGuarded`：建立全域錯誤區域，捕捉非同步異常。
/// 2. `WidgetsFlutterBinding.ensureInitialized()`：確保原生通訊管道已就緒。
/// 3. `DatabaseService.log`：初始化日誌系統。
/// 4. `runApp`：啟動 MaterialApp 並注入 `ProviderScope`。

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/map_screen.dart';
import 'services/database_service.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    DatabaseService.log('=== Application Starting ===');
    
    if (kIsWeb) {
      DatabaseService.log('Running on Web platform');
    } else {
      DatabaseService.log('Running on Native platform');
    }
    
    FlutterError.onError = (FlutterErrorDetails details) {
      DatabaseService.log('Flutter Error', error: details.exception, stackTrace: details.stack);
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      DatabaseService.log('Platform Dispatcher Error', error: error, stackTrace: stack);
      return true;
    };

    runApp(
      const ProviderScope(
        child: GarbageMapApp(),
      ),
    );
  }, (error, stack) {
    DatabaseService.log('Uncaught Global Error', error: error, stackTrace: stack);
  });
}

class GarbageMapApp extends StatefulWidget {
  const GarbageMapApp({super.key});
  @override
  State<GarbageMapApp> createState() => _GarbageMapAppState();
}

class _GarbageMapAppState extends State<GarbageMapApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 移除 exit(0) 以避免在 Web 或非支援平台上崩潰
    if (state == AppLifecycleState.detached) {
      DatabaseService.log('App Detached');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '台灣垃圾車即時地圖',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.yellow,
          primary: Colors.yellow[800]!,
          secondary: Colors.orange,
        ),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}
