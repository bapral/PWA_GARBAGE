/// [整體程式說明]
/// 本文件為「台灣垃圾車即時地圖」應用程式的啟動核心。
/// 主要職責包括初始化 Flutter 引擎、配置全域錯誤捕捉機制、管理應用程式生命週期，
/// 以及建構應用的根層級 Widget 結構（MaterialApp 與 ProviderScope）。
///
/// [執行順序說明]
/// 1. 執行 main() 函式，進入 runZonedGuarded 隔離區以捕捉非同步例外。
/// 2. 呼叫 WidgetsFlutterBinding.ensureInitialized() 確保原生插件與 Flutter 通訊正常。
/// 3. 設定 FlutterError.onError 捕捉框架層級錯誤，並透過 DatabaseService 記錄。
/// 4. 設定 PlatformDispatcher.instance.onError 捕捉底層平台錯誤。
/// 5. 呼叫 runApp() 並包裹 ProviderScope，初始化 Riverpod 狀態管理。
/// 6. 建構 GarbageMapApp，註冊 WidgetsBindingObserver 以監聽系統生命週期事件。
/// 7. 根據不同平台屬性（如 Windows）設定特定的結束行為。
/// 8. 最終載入 MapScreen 作為應用程式的首頁。

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/map_screen.dart';
import 'services/database_service.dart';

/// 應用程式進入點。
/// 
/// 負責引導整個應用程式的啟動流程。
/// 使用 [runZonedGuarded] 捕捉全域未處理的異常，並將其記錄至本地日誌系統。
/// 這能確保應用程式在遇到非預期錯誤時不會無聲潰散。
void main() {
  runZonedGuarded(() async {
    // 確保 Flutter 引擎初始化完成，以便在 runApp 之前執行非同步操作。
    WidgetsFlutterBinding.ensureInitialized();
    
    // 記錄啟動日誌，方便追蹤應用程式生命週期。
    DatabaseService.log('=== Application Starting ===');
    DatabaseService.log('Operating System: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    DatabaseService.log('Dart VM version: ${Platform.version}');
    
    // 捕捉並處理來自 Flutter 框架層級的錯誤（例如 Widget 建構失敗）。
    FlutterError.onError = (FlutterErrorDetails details) {
      DatabaseService.log('Flutter Error', error: details.exception, stackTrace: details.stack);
      FlutterError.presentError(details);
    };

    // 捕捉並處理非同步任務中發出的錯誤（例如 Future 失敗但未被捕捉）。
    PlatformDispatcher.instance.onError = (error, stack) {
      DatabaseService.log('Platform Dispatcher Error', error: error, stackTrace: stack);
      return true;
    };

    // 啟動 Flutter 應用程式，並包裹在 ProviderScope 中以支援 Riverpod 狀態管理。
    runApp(
      const ProviderScope(
        child: GarbageMapApp(),
      ),
    );
  }, (error, stack) {
    // 捕捉任何溢出的全域例外狀況（RunZonedGuarded 的最終防線）。
    DatabaseService.log('Uncaught Global Error', error: error, stackTrace: stack);
  });
}

/// 應用程式的主要根 Widget。
/// 
/// 繼承自 [StatefulWidget] 以便監聽應用程式生命週期變化（例如視窗關閉或背景切換）。
class GarbageMapApp extends StatefulWidget {
  /// 建立 [GarbageMapApp] 實例。
  const GarbageMapApp({super.key});

  @override
  State<GarbageMapApp> createState() => _GarbageMapAppState();
}

/// [GarbageMapApp] 的狀態管理類別。
/// 
/// 混入 [WidgetsBindingObserver] 用於觀察應用程式生命週期。
class _GarbageMapAppState extends State<GarbageMapApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // 註冊觀察者以監聽應用程式生命週期變化。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    // 移除觀察者，防止記憶體洩漏。
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 當應用程式生命週期狀態改變時觸發。
  /// 
  /// [state] 為目前的生命週期狀態。
  /// 針對 Windows 平台進行特殊處理：當視窗被關閉時，主動結束進程。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // 針對 Windows 平台進行特殊處理：
    // 當視窗被使用者手動關閉時，Lifecycle 會進入 detached 狀態。
    // 在桌面端我們主動執行 exit(0) 以確保程式進程徹底結束，不會殘留在背景。
    if (state == AppLifecycleState.detached && !kIsWeb) {
      DatabaseService.log('Window closed, exiting application.');
      exit(0);
    }
  }

  /// 構建應用程式介面。
  /// 
  /// [context] 建構上下文。
  /// 回傳配置好的 [MaterialApp] 元件。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '台灣垃圾車即時地圖',
      debugShowCheckedModeBanner: false, // 隱藏偵錯模式的橫幅
      theme: ThemeData(
        // 定義應用程式主題色彩方案
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.yellow, // 以黃色為種子顏色（呼叫垃圾車經典印象）
          primary: Colors.yellow[800]!,
          secondary: Colors.orange,
        ),
        useMaterial3: true, // 啟用 Material 3 設計規範
      ),
      // 首頁顯示地圖螢幕元件
      home: const MapScreen(),
    );
  }
}
