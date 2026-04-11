/// [整體程式說明]
/// 本文件提供 [TimeUtils] 工具類別，負責全系統的時間格式標準化處理。
/// 由於各縣市政府 API 回傳的時間格式極其混雜（如 12H/24H、帶日期、純數字等），
/// 本工具類別確保進入資料庫與 UI 顯示的時間均為統一的 24 小時制 "HH:mm"。

/// 時間處理工具類別，確保全系統一致使用 24 小時制 (HH:mm)。
class TimeUtils {
  /// 將各種可能的時間格式標準化為 "HH:mm" (24小時制)。
  /// 
  /// 支援格式：
  /// - "0830" -> "08:30"
  /// - "2030" -> "20:30"
  /// - "8:30"  -> "08:30"
  /// - "16:00-16:10" -> "16:00"
  /// - "20240411T093000" -> "09:30"
  static String formatTo24Hour(String raw) {
    if (raw.isEmpty) return "";

    String time = raw.trim().toUpperCase();

    // 處理 12 小時制標記 (AM/PM 或 上午/下午)
    bool isPM = time.contains('PM') || time.contains('下午') || time.contains('晚上');
    bool isAM = time.contains('AM') || time.contains('上午') || time.contains('早上');

    // 移除所有非數字字元，但保留冒號以便後續切割
    time = time.replaceAll(RegExp(r'[^0-9:]'), '');

    // 處理台中 ISO T 格式: 20240411T093000 -> 09:30
    if (raw.contains('T')) {
      try {
        final parts = raw.split('T');
        if (parts.length > 1) {
          String timePart = parts[1].replaceAll(RegExp(r'[^0-9]'), '');
          if (timePart.length >= 4) {
            time = timePart.substring(0, 4); // 取 0930
          }
        }
      } catch (_) {}
    }

    // 處理區間格式: 16:00-16:10 -> 16:00
    if (time.contains('-')) {
      time = time.split('-')[0].trim();
    }

    // 解析小時與分鐘
    int hour = 0;
    int minute = 0;

    if (time.contains(':')) {
      final parts = time.split(':');
      hour = int.tryParse(parts[0]) ?? 0;
      minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    } else {
      // 處理純數字 0830, 830, 2030
      if (time.length == 3) {
        hour = int.tryParse(time.substring(0, 1)) ?? 0;
        minute = int.tryParse(time.substring(1, 3)) ?? 0;
      } else if (time.length == 4) {
        hour = int.tryParse(time.substring(0, 2)) ?? 0;
        minute = int.tryParse(time.substring(2, 4)) ?? 0;
      }
    }

    // 根據 AM/PM 修正小時
    if (isPM && hour < 12) hour += 12;
    if (isAM && hour == 12) hour = 0;

    // 確保範圍合法
    if (hour < 0) hour = 0; if (hour > 23) hour = 23;
    if (minute < 0) minute = 0; if (minute > 59) minute = 59;

    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
}
