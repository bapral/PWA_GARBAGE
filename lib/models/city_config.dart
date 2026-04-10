/// [整體程式說明]
/// 本文件定義了 [CityConfig] 資料模型，用於封裝與特定縣市相關的配置參數。
/// 這套模型是應用程式「多城市支援」架構的核心，透過抽離城市特有的屬性（如中心點、顏色、資源路徑），
/// 使得增加新城市支援時不需修改核心邏輯，僅需新增對應的配置實例。
///
/// [執行順序說明]
/// 1. 應用程式啟動或使用者切換城市時，建構 [CityConfig] 物件。
/// 2. 各項服務（如 [GarbageProvider]）讀取此配置以決定 API 請求對象或本地檔案路徑。
/// 3. UI 層級（如 [MapScreen]）讀取配置中的 `themeColor` 與 `initialCenter` 來呈現對應的介面色彩與地圖視野。

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// [CityConfig] 類別用於定義特定城市的配置資訊與環境設定。
/// 
/// 這使得應用程式可以輕鬆擴充支援不同的縣市，只需提供對應的配置物件。
class CityConfig {
  /// 城市唯一識別名稱 (例如: "taipei", "ntpc")。
  final String cityName;
  
  /// 應用程式標題列顯示的名稱 (例如: "台北市垃圾車即時地圖")。
  final String appTitle;
  
  /// 地圖啟動時預設顯示的中心點座標 (經緯度)。
  final LatLng initialCenter;
  
  /// 該城市對應的主題顏色，影響 AppBar、按鈕與標記顏色。
  final MaterialColor themeColor;
  
  /// 存放該城市相關本地資源檔案（如預載的 CSV 或 JSON 班表）的目錄路徑。
  final String localSourceDir;

  /// 建構子：初始化城市配置。
  /// 
  /// [cityName] 城市識別碼。
  /// [appTitle] UI 顯示標題。
  /// [initialCenter] 地圖預設中心。
  /// [themeColor] 主題配色。
  /// [localSourceDir] 資源路徑。
  CityConfig({
    required this.cityName,
    required this.appTitle,
    required this.initialCenter,
    required this.themeColor,
    required this.localSourceDir,
  });
}
