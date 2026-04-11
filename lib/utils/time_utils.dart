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
    
    String time = raw.trim();

    // 處理台中 ISO T 格式: 20240411T093000
    if (time.contains('T')) {
      try {
        time = time.split('T')[1].substring(0, 4); // 取 0930
      } catch (_) {}
    }

    // 處理區間格式: 16:00-16:10
    if (time.contains('-')) {
      time = time.split('-')[0].trim();
    }

    // 移除現有的冒號以便統一處理
    time = time.replaceAll(':', '');

    // 處理只有 3 位數的情況 (例如 830 -> 0830)
    if (time.length == 3) {
      time = '0$time';
    }

    // 處理 4 位數的情況 (例如 0830 或 2030)
    if (time.length == 4) {
      return '${time.substring(0, 2)}:${time.substring(2, 4)}';
    }

    // 若都不符合，回傳原始並嘗試補冒號 (保險)
    if (raw.length == 5 && raw.contains(':')) return raw;
    
    return raw;
  }
}
