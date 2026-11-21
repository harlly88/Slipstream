/// 本地中文自然语言时间解析器（零网络，纯规则）。
/// 示例："明天下午3点有一个视频会议，讨论ai应用" → 明天 15:00 + "视频会议，讨论ai应用"
/// v0.3：支持相对时长，"过1小时提醒我暂停喝水" → 1 小时后 + "暂停喝水"
class ParsedAlarm {
  final DateTime fireAt;
  final String title;

  /// 输入中出现了"每天/每周"等重复表达（本迭代仅按单次创建，UI 层提示）
  final bool repeated;

  const ParsedAlarm({required this.fireAt, required this.title, this.repeated = false});
}

/// 相对时长模式：要求「过/再过/过多」前缀或「后/之后」后缀，避免误吞正文数字。
/// 组：1=过前缀(可选) 2=数值 3=个半 4=单位 5=后缀(可选)
final RegExp _relDurationPattern = RegExp(
    r'(再?过多?)?\s*(\d+(?:\.\d+)?|[一两二三四五六七八九十]|半)?(个半)?\s*(小时|钟头|分钟|分)\s*(之?后)?');

/// 解析失败返回 null
ParsedAlarm? parseChineseTime(String input, {DateTime? now}) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final base = now ?? DateTime.now();
  final today = DateTime(base.year, base.month, base.day);

  var repeated = RegExp(r'(每天|每日|每周|每个|工作日|工作天)').hasMatch(text);

  // ---------- 0. 相对时长（最高优先级）："过1小时" / "半小时后" / "再过10分钟" ----------
  var relativeFound = false;
  Duration? relDur;
  final relMatch = _relDurationPattern.firstMatch(text);
  if (relMatch != null &&
      (relMatch.group(1) != null || relMatch.group(5) != null)) {
    final numStr = relMatch.group(2);
    final hasGeBan = relMatch.group(3) != null;
    final unit = relMatch.group(4)!;
    var value = 1.0;
    if (numStr == '半') {
      value = 0.5;
    } else if (numStr != null) {
      final d = double.tryParse(numStr) ?? _cnToInt(numStr).toDouble();
      value = d > 0 ? d : 1.0;
    }
    if (hasGeBan) value += 0.5; // "一个半小时"
    final isHours = unit == '小时' || unit == '钟头';
    final minutes = isHours ? value * 60 : value;
    relDur = Duration(milliseconds: (minutes * 60 * 1000).round());
    relativeFound = true;
  }

  // ---------- 1. 日期 ----------
  var dateFound = false;
  var date = today;
  var dateIsWeekday = false; // 顺延策略：星期用 +7 天，其余 +1 天

  final relDay = RegExp(r'(大后天|后天|明天|今天|今晚|明晚)').firstMatch(text);
  // 注意："下周X" 中 "下周" 已含 "周"，前缀与星期词必须一体匹配，否则会回退成 "周X"
  final weekdayMatch = RegExp(r'(下|这|本)?(?:周|星期|礼拜)([一二三四五六天日1-7])').firstMatch(text);
  final monthDay = RegExp(r'(\d{1,2})月(\d{1,2})[日号]').firstMatch(text);

  if (relDay != null) {
    dateFound = true;
    final word = relDay.group(1)!;
    date = switch (word) {
      '大后天' => today.add(const Duration(days: 3)),
      '后天' => today.add(const Duration(days: 2)),
      '明天' || '明晚' => today.add(const Duration(days: 1)),
      _ => today, // 今天 / 今晚
    };
  } else if (monthDay != null) {
    dateFound = true;
    final m = int.parse(monthDay.group(1)!);
    final d = int.parse(monthDay.group(2)!);
    var cand = DateTime(base.year, m, d);
    if (cand.isBefore(today)) cand = DateTime(base.year + 1, m, d);
    date = cand;
  } else if (weekdayMatch != null) {
    dateFound = true;
    dateIsWeekday = true;
    final target = _weekdayValue(weekdayMatch.group(2)!);
    var delta = (target - base.weekday + 7) % 7;
    if (weekdayMatch.group(1) == '下') {
      // 下周X = 最近未来周X + 7 天
      delta += 7;
    }
    date = today.add(Duration(days: delta));
  }

  // ---------- 2. 时段 ----------
  var periodFound = false;
  var period = ''; // morning / noon / afternoon / evening / night
  final periodMatch = RegExp(r'(凌晨|早上|上午|中午|下午|傍晚|晚上|夜里|夜间|深夜|今晚|明晚)').firstMatch(text);
  if (periodMatch != null) {
    periodFound = true;
    final w = periodMatch.group(1)!;
    period = switch (w) {
      '凌晨' => 'night',
      '中午' => 'noon',
      '下午' => 'afternoon',
      '傍晚' || '晚上' || '夜里' || '夜间' || '深夜' || '今晚' || '明晚' => 'evening',
      _ => 'morning', // 早上 / 上午
    };
  }

  // ---------- 3. 时刻 ----------
  var clockFound = false;
  var hour = 9;
  var minute = 0;

  final colonMatch = RegExp(r'(\d{1,2})[:：](\d{2})').firstMatch(text);
  final cnHourMatch =
      RegExp(r'([0-9零一二三四五六七八九十两]{1,3})\s*点\s*(半|一刻|三刻|(\d{1,2})\s*分?|整)?').firstMatch(text);

  if (colonMatch != null) {
    clockFound = true;
    hour = int.parse(colonMatch.group(1)!);
    minute = int.parse(colonMatch.group(2)!);
  } else if (cnHourMatch != null) {
    clockFound = true;
    hour = _cnToInt(cnHourMatch.group(1)!);
    final frac = cnHourMatch.group(2); // 完整分数短语（如 "30分"）
    final fracDigits = cnHourMatch.group(3); // 纯数字分钟
    if (frac == '半') {
      minute = 30;
    } else if (frac == '一刻') {
      minute = 15;
    } else if (frac == '三刻') {
      minute = 45;
    } else if (fracDigits != null) {
      final m = int.tryParse(fracDigits);
      minute = (m != null && m >= 0 && m <= 59) ? m : 0;
    }
  }

  if (clockFound && (hour < 0 || hour > 24 || minute < 0 || minute > 59)) return null;

  // ---------- 4. 12/24 小时折算 ----------
  if (clockFound) {
    if (hour >= 24) hour = hour % 24;
    if (hour <= 12) {
      switch (period) {
        case 'afternoon': // 13-17
          if (hour < 12) hour += 12;
          break;
        case 'evening': // 19-23
          if (hour < 12) hour += 12;
          break;
        case 'noon': // 11-13
          if (hour <= 2) hour += 12;
          break;
        case 'night': // 凌晨 0-5 原样
          break;
        default:
          break; // 早上/上午原样；无时段 12 点按中午 12
      }
    }
  } else {
    // 无时刻：默认上午 9:00；晚上类默认 20:00
    hour = period == 'evening' ? 20 : 9;
    minute = 0;
  }

  // ---------- 5. 组合 ----------
  DateTime fireAt;
  if (relativeFound && relDur != null) {
    // 相对时长：天然在未来，不做顺延
    fireAt = base.add(relDur);
  } else {
    fireAt = DateTime(date.year, date.month, date.day, hour, minute);

    // 必须在未来：星期顺延 7 天，其余顺延 1 天
    if (fireAt.isBefore(base)) {
      fireAt = fireAt.add(Duration(days: dateIsWeekday ? 7 : 1));
    }
  }

  // 完全无时间信息 → 解析失败
  if (!dateFound && !clockFound && !periodFound && !relativeFound) return null;

  // ---------- 6. 标题：删去时间短语与连接词 ----------
  var title = text;
  // 相对时长短语（含 过/再过 前缀 或 后/之后 后缀的完整短语）
  title = title.replaceAllMapped(_relDurationPattern, (m) {
    final hasAffix = m.group(1) != null || m.group(5) != null;
    return hasAffix ? ' ' : m.group(0)!; // 无前后缀的正文数字不动
  });
  // 先删星期短语（含 下/这/本 前缀，须先于 "下周" 词删除，避免残留 "五"）
  title = title.replaceAll(RegExp(r'(下|这|本)?(?:周|星期|礼拜)[一二三四五六天日1-7]'), ' ');
  // 删除匹配到的短语
  for (final w in [
    '大后天', '后天', '明天', '今天', '今晚', '明晚',
    '凌晨', '早上', '上午', '中午', '下午', '傍晚', '晚上', '夜里', '夜间', '深夜',
  ]) {
    title = title.replaceAll(w, ' ');
  }
  title = title.replaceAll(RegExp(r'\d{1,2}月\d{1,2}[日号]'), ' ');
  title = title.replaceAll(RegExp(r'\d{1,2}[:：]\d{2}'), ' ');
  title = title.replaceAll(
      RegExp(r'[0-9零一二三四五六七八九十两]{1,3}\s*点\s*(半|一刻|三刻|\d{1,2}\s*分?|整)?'), ' ');
  // 连接词与冗余表达
  title = title.replaceAll(
      RegExp(r'(有一个|有个|有场|要去|要去参加|要参加|要开|要去开|记得|提醒我|帮我|请|麻烦|设个|设一个|设置|定个|定一个|安排)'),
      ' ');
  // 每天每周等
  title = title.replaceAll(RegExp(r'(每天|每日|每周|每个|工作日|工作天)'), ' ');
  // 清理标点与空白
  title = title.replaceAll(RegExp(r'^[\s，,。.、！!？?的]+|[\s，,。.、！!？?]+$'), '');
  title = title.replaceAll(RegExp(r'\s{2,}'), ' ');
  if (title.isEmpty) title = '闹钟';

  return ParsedAlarm(fireAt: fireAt, title: title, repeated: repeated);
}

/// 星期文字 → 数字（周一=1 … 周日=7）
int _weekdayValue(String s) => switch (s) {
      '一' || '1' => 1,
      '二' || '2' => 2,
      '三' || '3' => 3,
      '四' || '4' => 4,
      '五' || '5' => 5,
      '六' || '6' => 6,
      _ => 7, // 天 / 日 / 7
    };

/// 中文/阿拉伯数字（0~99）→ int；解析失败返回 -1
int _cnToInt(String s) {
  if (int.tryParse(s) != null) return int.parse(s);
  const digits = {'零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
  if (s == '十') return 10;
  if (s.contains('十')) {
    final parts = s.split('十');
    final tens = parts[0].isEmpty ? 1 : (digits[parts[0]] ?? -1);
    final ones = parts[1].isEmpty ? 0 : (digits[parts[1]] ?? -1);
    if (tens < 0 || ones < 0) return -1;
    return tens * 10 + ones;
  }
  return digits[s] ?? -1;
}
