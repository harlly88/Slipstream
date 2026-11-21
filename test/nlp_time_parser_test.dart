import 'package:flutter_test/flutter_test.dart';
import 'package:qingliu/services/nlp_time_parser.dart';

void main() {
  // 基准时间：2026-11-15（周日）10:00
  final now = DateTime(2026, 11, 15, 10, 0);

  ParsedAlarm? parse(String s) => parseChineseTime(s, now: now);

  group('日期 + 时段 + 时刻', () {
    test('明天下午3点有一个视频会议，讨论ai应用', () {
      final r = parse('明天下午3点有一个视频会议，讨论ai应用')!;
      expect(r.fireAt, DateTime(2026, 11, 16, 15, 0));
      expect(r.title, '视频会议，讨论ai应用');
      expect(r.repeated, false);
    });

    test('后天早上8点半叫我起床', () {
      final r = parse('后天早上8点半叫我起床')!;
      expect(r.fireAt, DateTime(2026, 11, 17, 8, 30));
      expect(r.title, '叫我起床');
    });

    test('周五晚上9点团队周会（最近未来周五）', () {
      final r = parse('周五晚上9点团队周会')!;
      // 2026-11-15 是周日 → 最近未来周五 = 11-20
      expect(r.fireAt, DateTime(2026, 11, 20, 21, 0));
      expect(r.title, '团队周会');
    });

    test('12月25号晚上8点圣诞聚会', () {
      final r = parse('12月25号晚上8点圣诞聚会')!;
      expect(r.fireAt, DateTime(2026, 12, 25, 20, 0));
      expect(r.title, '圣诞聚会');
    });

    test('大后天凌晨5点赶飞机', () {
      final r = parse('大后天凌晨5点赶飞机')!;
      expect(r.fireAt, DateTime(2026, 11, 18, 5, 0));
      expect(r.title, '赶飞机');
    });

    test('中午12点吃午饭', () {
      final r = parse('今天中午12点吃午饭')!;
      expect(r.fireAt, DateTime(2026, 11, 15, 12, 0));
      expect(r.title, '吃午饭');
    });

    test('冒号格式 18:30', () {
      final r = parse('明天18:30健身')!;
      expect(r.fireAt, DateTime(2026, 11, 16, 18, 30));
      expect(r.title, '健身');
    });

    test('X点一刻 / X点三刻', () {
      expect(parse('明天上午9点一刻晨会')!.fireAt, DateTime(2026, 11, 16, 9, 15));
      expect(parse('明天上午9点三刻晨会')!.fireAt, DateTime(2026, 11, 16, 9, 45));
    });

    test('中文数字时刻', () {
      expect(parse('明天早上八点半晨跑')!.fireAt, DateTime(2026, 11, 16, 8, 30));
      expect(parse('明天下午两点开会')!.fireAt, DateTime(2026, 11, 16, 14, 0));
      expect(parse('明天上午十点站会')!.fireAt, DateTime(2026, 11, 16, 10, 0));
    });

    test('24 小时制 20 点原样', () {
      expect(parse('明天20点复盘')!.fireAt, DateTime(2026, 11, 16, 20, 0));
    });

    test('13-23 点无时段原样', () {
      expect(parse('明天15点30分评审')!.fireAt, DateTime(2026, 11, 16, 15, 30));
    });
  });

  group('缺省与顺延', () {
    test('无时刻 → 默认上午 9:00', () {
      expect(parse('明天有个面试')!.fireAt, DateTime(2026, 11, 16, 9, 0));
    });

    test('仅晚上 → 默认 20:00', () {
      expect(parse('明天晚上团建')!.fireAt, DateTime(2026, 11, 16, 20, 0));
    });

    test('无日期且时间已过 → 顺延明天', () {
      // now = 10:00，"下午3点" 今天 15:00 未过 → 今天
      expect(parse('下午3点取快递')!.fireAt, DateTime(2026, 11, 15, 15, 0));
      // "上午9点" 已过 → 明天 9:00
      expect(parse('上午9点取快递')!.fireAt, DateTime(2026, 11, 16, 9, 0));
    });

    test('今天时间已过 → 顺延明天', () {
      expect(parse('今天早上8点晨会')!.fireAt, DateTime(2026, 11, 16, 8, 0));
    });

    test('周X 已过今天对应时刻 → 顺延 7 天', () {
      // 2026-11-15 周日 10:00，"周日11点" → 今天 11:00 未过
      expect(parse('周日11点直播')!.fireAt, DateTime(2026, 11, 15, 11, 0));
      // "周日9点" 已过 → 下周日
      expect(parse('周日9点直播')!.fireAt, DateTime(2026, 11, 22, 9, 0));
    });

    test('下周X = 最近未来 + 7 天', () {
      // 周日说"下周五" → 11-27
      expect(parse('下周五晚上9点周会')!.fireAt, DateTime(2026, 11, 27, 21, 0));
    });

    test('月日已过 → 明年', () {
      // now = 2026-11-15，"1月1号" → 2027
      expect(parse('1月1号凌晨0点跨年')!.fireAt, DateTime(2027, 1, 1, 0, 0));
    });
  });

  group('相对时长（v0.3）', () {
    test('过1小时提醒我暂停喝水', () {
      final r = parse('过1小时提醒我暂停喝水')!;
      expect(r.fireAt, now.add(const Duration(hours: 1)));
      expect(r.title, '暂停喝水');
    });

    test('过多1小时提醒我暂停喝水（多余字）', () {
      final r = parse('过多1小时提醒我暂停喝水')!;
      expect(r.fireAt, now.add(const Duration(hours: 1)));
      expect(r.title, '暂停喝水');
    });

    test('半小时后提醒我喝水', () {
      final r = parse('半小时后提醒我喝水')!;
      expect(r.fireAt, now.add(const Duration(minutes: 30)));
      expect(r.title, '喝水');
    });

    test('再过10分钟叫我起来活动', () {
      final r = parse('再过10分钟叫我起来活动')!;
      expect(r.fireAt, now.add(const Duration(minutes: 10)));
      expect(r.title, '叫我起来活动');
    });

    test('一个半小时后开会', () {
      final r = parse('一个半小时后开会')!;
      expect(r.fireAt, now.add(const Duration(minutes: 90)));
      expect(r.title, '开会');
    });

    test('正文数字不被误吞', () {
      // "3小时" 无过前缀/后后缀 → 不构成相对时间
      final r = parse('明天下午3点复盘，预计3小时');
      expect(r!.fireAt, DateTime(2026, 11, 16, 15, 0));
      expect(r.title, '复盘，预计3小时');
    });
  });

  group('重复与失败', () {
    test('每天 → repeated 标记（按单次创建）', () {
      final r = parse('每天早上7点叫我起床')!;
      expect(r.repeated, true);
      // 今天 7 点已过（now 10:00）→ 明天 7:00
      expect(r.fireAt, DateTime(2026, 11, 16, 7, 0));
      expect(r.title, '叫我起床');
    });

    test('完全无时间信息 → null', () {
      expect(parse('视频会议'), isNull);
      expect(parse(''), isNull);
    });
  });
}
