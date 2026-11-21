import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingliu/data/database.dart';
import 'package:qingliu/data/repositories.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('备份导出/导入全量往返（v2：含临时任务/独立闹钟/isToday/title）', () async {
    final project = await ProjectRepo(db).create('写作计划', 0xFF5B8DD9, '今年写完初稿');
    final task = await TaskRepo(db).create(TasksCompanion.insert(
      projectId: Value(project.id),
      title: '完成第三章',
      note: Value('关键场景对话'),
      dueDate: Value(DateTime(2026, 1, 15, 9, 30)),
      priority: const Value(1),
      isToday: const Value(true),
    ));
    // 临时任务（无项目）+ 今日
    await TaskRepo(db).create(TasksCompanion.insert(
      title: '买咖啡豆',
      isToday: const Value(true),
    ));
    // 任务提醒 + 独立闹钟
    await ReminderRepo(db).create(RemindersCompanion.insert(
      taskId: Value(task.id),
      type: 'daily',
      fireAt: DateTime(2026, 1, 10, 9, 0),
    ));
    await ReminderRepo(db).create(RemindersCompanion.insert(
      title: const Value('视频会议，讨论ai应用'),
      type: 'once',
      fireAt: DateTime(2026, 1, 11, 15, 0),
    ));
    await FocusRepo(db).insert(FocusSessionsCompanion.insert(
      startedAt: DateTime(2026, 1, 9, 14, 0),
      plannedMinutes: 25,
      endedAt: Value(DateTime(2026, 1, 9, 14, 25)),
    ));

    final backup = BackupService(db);
    final json = await backup.exportJson();

    // 导入到新库
    final db2 = AppDatabase(NativeDatabase.memory());
    addTearDown(db2.close);
    final restored = await BackupService(db2).importAll(await backup.exportAll());

    expect(restored.projects, 1);
    expect(restored.tasks, 2);
    expect(restored.reminders, 2);
    expect(restored.sessions, 1);

    final projects2 = await ProjectRepo(db2).getAll(includeArchived: true);
    expect(projects2.single.name, '写作计划');
    final tasks2 = await TaskRepo(db2).getAll();
    final withProject = tasks2.firstWhere((t) => t.title == '完成第三章');
    expect(withProject.projectId, project.id);
    expect(withProject.priority, 1);
    expect(withProject.isToday, true);
    final temp = tasks2.firstWhere((t) => t.title == '买咖啡豆');
    expect(temp.projectId, isNull);
    expect(temp.isToday, true);

    // 独立闹钟恢复
    final alarms = await db2.select(db2.reminders).get();
    final independent = alarms.where((r) => r.taskId == null).single;
    expect(independent.title, '视频会议，讨论ai应用');
    expect(independent.type, 'once');

    // 导出字符串是合法 JSON
    expect(json, contains('写作计划'));
  });

  test('v1 旧备份（无 isToday/title 字段）可导入', () async {
    final legacy = {
      'version': 1,
      'exportedAt': DateTime(2026, 1, 1).toIso8601String(),
      'projects': [
        {'id': 1, 'name': '旧项目', 'color': 4289379478, 'note': '', 'archived': false, 'sortOrder': 0}
      ],
      'tasks': [
        {'id': 1, 'projectId': 1, 'title': '旧任务', 'status': 'todo', 'priority': 0, 'sortOrder': 0}
      ],
      'reminders': [
        {'id': 1, 'taskId': 1, 'type': 'once', 'fireAt': '2026-01-02T09:00:00.000', 'enabled': true}
      ],
      'focusSessions': [],
    };
    final db2 = AppDatabase(NativeDatabase.memory());
    addTearDown(db2.close);
    final restored = await BackupService(db2).importAll(legacy);
    expect(restored.tasks, 1);
    final tasks2 = await TaskRepo(db2).getAll();
    expect(tasks2.single.isToday, false); // 缺省 false
    final reminders2 = await db2.select(db2.reminders).get();
    expect(reminders2.single.title, isNull); // 缺省 null
  });

  test('任务完成状态流转', () async {
    final project = await ProjectRepo(db).create('测试项目', 0xFF4A9B8E, '');
    final task = await TaskRepo(db).create(
        TasksCompanion.insert(projectId: Value(project.id), title: '任务A'));

    await TaskRepo(db).setDone(task.id, done: true);
    var reloaded = await TaskRepo(db).getById(task.id);
    expect(reloaded!.status, 'done');
    expect(reloaded.doneAt, isNotNull);

    await TaskRepo(db).setDone(task.id, done: false);
    reloaded = await TaskRepo(db).getById(task.id);
    expect(reloaded!.status, 'todo');
    expect(reloaded.doneAt, isNull);
  });

  test('看板移动：状态 + 完成时间', () async {
    final project = await ProjectRepo(db).create('测试项目', 0xFF4A9B8E, '');
    final task = await TaskRepo(db).create(
        TasksCompanion.insert(projectId: Value(project.id), title: '任务B'));

    await TaskRepo(db).moveTask(task.id, status: 'doing', sortOrder: 500);
    var reloaded = await TaskRepo(db).getById(task.id);
    expect(reloaded!.status, 'doing');
    expect(reloaded.sortOrder, 500);

    await TaskRepo(db).moveTask(task.id, status: 'done');
    reloaded = await TaskRepo(db).getById(task.id);
    expect(reloaded!.status, 'done');
    expect(reloaded.doneAt, isNotNull);
  });

  test('项目删除级联清理任务/提醒/专注记录；独立闹钟不受影响', () async {
    final project = await ProjectRepo(db).create('待删项目', 0xFF4A9B8E, '');
    final task = await TaskRepo(db).create(
        TasksCompanion.insert(projectId: Value(project.id), title: '任务C'));
    await ReminderRepo(db).create(RemindersCompanion.insert(
        taskId: Value(task.id), type: 'once', fireAt: DateTime(2026, 2, 1, 9)));
    final alarm = await ReminderRepo(db).create(RemindersCompanion.insert(
        title: const Value('独立闹钟'), type: 'once', fireAt: DateTime(2026, 2, 2, 10)));
    await FocusRepo(db).insert(FocusSessionsCompanion.insert(
        startedAt: DateTime.now(), plannedMinutes: 25));

    await ProjectRepo(db).delete(project.id);

    expect(await TaskRepo(db).getAll(), isEmpty);
    final remindersLeft = await db.select(db.reminders).get();
    expect(remindersLeft.single.id, alarm.id); // 只剩独立闹钟
    expect(await db.select(db.focusSessions).get(), isNotEmpty); // sessionId 无任务关联，保留
    expect(await ProjectRepo(db).getAll(includeArchived: true), isEmpty);
  });

  test('今日任务：勾选加入/移出 + watchToday 排序', () async {
    final p1 = await ProjectRepo(db).create('项目一', 0xFF4A9B8E, '');
    final t1 = await TaskRepo(db)
        .create(TasksCompanion.insert(projectId: Value(p1.id), title: '项目任务'));
    final t2 =
        await TaskRepo(db).create(TasksCompanion.insert(title: '临时任务', isToday: const Value(true)));

    expect((await TaskRepo(db).watchToday().first).length, 1); // 仅临时任务

    await TaskRepo(db).setToday(t1.id, value: true);
    var today = await TaskRepo(db).watchToday().first;
    expect(today.length, 2);
    // 项目信息 join 正确
    final t1Row = today.firstWhere((r) => r.$1.id == t1.id);
    expect(t1Row.$2?.name, '项目一');
    final t2Row = today.firstWhere((r) => r.$1.id == t2.id);
    expect(t2Row.$2, isNull); // 临时任务无项目

    // 完成的排后面
    await TaskRepo(db).setDone(t1.id, done: true);
    today = await TaskRepo(db).watchToday().first;
    expect(today.last.$1.id, t1.id);

    // 移出今日
    await TaskRepo(db).setToday(t1.id, value: false);
    await TaskRepo(db).setToday(t2.id, value: false);
    expect((await TaskRepo(db).watchToday().first), isEmpty);
  });

  test('独立闹钟列表与开关', () async {
    final repo = ReminderRepo(db);
    await repo.create(RemindersCompanion.insert(
        title: const Value('闹钟A'), type: 'once', fireAt: DateTime(2026, 3, 1, 8)));
    await repo.create(RemindersCompanion.insert(
        title: const Value('闹钟B'), type: 'once', fireAt: DateTime(2026, 3, 2, 9)));
    final project = await ProjectRepo(db).create('项目', 0xFF4A9B8E, '');
    final task = await TaskRepo(db)
        .create(TasksCompanion.insert(projectId: Value(project.id), title: '任务'));
    await repo.create(RemindersCompanion.insert(
        taskId: Value(task.id), type: 'once', fireAt: DateTime(2026, 3, 3, 10)));

    final alarms = await repo.watchAlarms().first;
    expect(alarms.length, 2); // 任务提醒不计入
    expect(alarms.map((a) => a.title).toList(), ['闹钟A', '闹钟B']); // 时间正序

    await repo.setEnabled(alarms.first.id, enabled: false);
    expect((await repo.watchAlarms().first).length, 1);
  });
}
