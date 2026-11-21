import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

export 'database.dart';

/// 项目仓库
class ProjectRepo {
  final AppDatabase db;
  ProjectRepo(this.db);

  Stream<List<Project>> watchAll({bool includeArchived = false}) {
    final query = db.select(db.projects)
      ..orderBy([
        (t) => OrderingTerm(expression: t.sortOrder),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
    if (!includeArchived) {
      query.where((t) => t.archived.equals(false));
    }
    return query.watch();
  }

  Future<Project> create(String name, int color, String note) async {
    final id = await db.into(db.projects).insert(
        ProjectsCompanion.insert(name: name, color: Value(color), note: Value(note)));
    return (db.select(db.projects)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> update(ProjectsCompanion entry) =>
      (db.update(db.projects)..where((t) => t.id.equals(entry.id.value)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())));

  Future<void> archive(int id, {required bool archived}) =>
      (db.update(db.projects)..where((t) => t.id.equals(id))).write(
          ProjectsCompanion(archived: Value(archived), updatedAt: Value(DateTime.now())));

  /// 删除项目（手动级联：先删提醒 → 专注 → 任务 → 项目）
  Future<void> delete(int id) async {
    await db.transaction(() async {
      final taskIds =
          (await (db.select(db.tasks)..where((t) => t.projectId.equals(id))).get())
              .map((t) => t.id)
              .toList();
      if (taskIds.isNotEmpty) {
        await (db.delete(db.reminders)..where((r) => r.taskId.isIn(taskIds))).go();
        await (db.delete(db.focusSessions)..where((f) => f.taskId.isIn(taskIds))).go();
        await (db.delete(db.tasks)..where((t) => t.projectId.equals(id))).go();
      }
      await (db.delete(db.projects)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<List<Project>> getAll({bool includeArchived = false}) {
    final query = db.select(db.projects);
    if (!includeArchived) query.where((t) => t.archived.equals(false));
    return query.get();
  }

  Future<Project?> getById(int id) =>
      (db.select(db.projects)..where((t) => t.id.equals(id))).getSingleOrNull();
}

/// 任务仓库
class TaskRepo {
  final AppDatabase db;
  TaskRepo(this.db);

  /// 按项目查询任务（看板用，含全部状态）
  Stream<List<Task>> watchByProject(int projectId) {
    final query = db.select(db.tasks)
      ..where((t) => t.projectId.equals(projectId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.sortOrder),
        (t) => OrderingTerm(expression: t.id),
      ]);
    return query.watch();
  }

  /// 今日视图（v0.2）：显式勾选 isToday=true 的任务（含临时任务，leftJoin 项目）
  Stream<List<(Task, Project?)>> watchToday() {
    final query = db.select(db.tasks).join([
      leftOuterJoin(db.projects, db.projects.id.equalsExp(db.tasks.projectId)),
    ])
      ..where(db.tasks.isToday.equals(true))
      ..orderBy([
        OrderingTerm(expression: db.tasks.status.equals('done')), // 未完成在前
        OrderingTerm.desc(db.tasks.priority),
        OrderingTerm.asc(db.tasks.sortOrder),
        OrderingTerm.asc(db.tasks.id),
      ]);
    return query.watch().map((rows) =>
        rows.map((r) => (r.readTable(db.tasks), r.readTableOrNull(db.projects))).toList());
  }

  /// 全部项目的未完成任务（含项目信息，「从项目任务选择」用）
  Future<List<(Task, Project)>> getOpenTasksWithProject() async {
    final rows = await (db.select(db.tasks).join([
      innerJoin(db.projects, db.projects.id.equalsExp(db.tasks.projectId)),
    ])
          ..where(db.tasks.status.equals('done').not())
          ..orderBy([
            OrderingTerm.asc(db.projects.sortOrder),
            OrderingTerm.asc(db.tasks.sortOrder),
          ]))
        .get();
    return rows.map((r) => (r.readTable(db.tasks), r.readTable(db.projects))).toList();
  }

  /// 加入/移出今日
  Future<void> setToday(int taskId, {required bool value}) =>
      (db.update(db.tasks)..where((t) => t.id.equals(taskId))).write(TasksCompanion(
        isToday: Value(value),
        updatedAt: Value(DateTime.now()),
      ));

  Future<Task> create(TasksCompanion entry) async {
    final id = await db.into(db.tasks).insert(entry);
    return (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> update(TasksCompanion entry) =>
      (db.update(db.tasks)..where((t) => t.id.equals(entry.id.value)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())));

  /// 看板拖拽：改状态 + 排序位置
  Future<void> moveTask(int taskId, {required String status, double? sortOrder}) {
    return (db.update(db.tasks)..where((t) => t.id.equals(taskId))).write(TasksCompanion(
      status: Value(status),
      sortOrder: sortOrder != null ? Value(sortOrder.toInt()) : const Value.absent(),
      doneAt: Value(status == 'done' ? DateTime.now() : null),
      updatedAt: Value(DateTime.now()),
    ));
  }

  Future<void> setDone(int taskId, {required bool done}) {
    return (db.update(db.tasks)..where((t) => t.id.equals(taskId))).write(TasksCompanion(
      status: Value(done ? 'done' : 'todo'),
      doneAt: Value(done ? DateTime.now() : null),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// 删除任务（手动级联：提醒 / 专注记录）
  Future<void> delete(int id) async {
    await db.transaction(() async {
      await (db.delete(db.reminders)..where((r) => r.taskId.equals(id))).go();
      await (db.delete(db.focusSessions)..where((f) => f.taskId.equals(id))).go();
      await (db.delete(db.tasks)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<Task?> getById(int id) =>
      (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Task>> getAll() => db.select(db.tasks).get();
}

/// 提醒仓库
class ReminderRepo {
  final AppDatabase db;
  ReminderRepo(this.db);

  Stream<List<Reminder>> watchByTask(int taskId) {
    final query = db.select(db.reminders)
      ..where((r) => r.taskId.equals(taskId) & r.enabled.equals(true));
    return query.watch();
  }

  /// 全部已启用的独立闹钟（taskId=null，按触发时间正序）
  Stream<List<Reminder>> watchAlarms() {
    final query = db.select(db.reminders)
      ..where((r) => r.taskId.isNull() & r.enabled.equals(true))
      ..orderBy([(r) => OrderingTerm.asc(r.fireAt)]);
    return query.watch();
  }

  /// 今日触发的提醒（今日 00:00 ~ 24:00，含独立闹钟与任务提醒）
  Future<List<Reminder>> getTodayAlarms() async {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final rows = await getAllEnabled();
    return rows.where((r) {
      switch (r.type) {
        case 'daily':
          return true;
        case 'weekly':
          return (r.weekdays ?? '').contains('${now.weekday}');
        case 'monthly':
          return r.dayOfMonth == now.day;
        default: // once
          return !r.fireAt.isBefore(dayStart) && r.fireAt.isBefore(dayEnd);
      }
    }).where((r) {
      // 今天的触发时刻还没过（含已过 5 分钟内的）
      final todayAt = r.type == 'once'
          ? r.fireAt
          : DateTime(now.year, now.month, now.day, r.fireAt.hour, r.fireAt.minute);
      return todayAt.isAfter(now.subtract(const Duration(minutes: 5)));
    }).toList();
  }

  Future<List<Reminder>> getAllEnabled() {
    final query = db.select(db.reminders)..where((r) => r.enabled.equals(true));
    return query.get();
  }

  Future<Reminder> create(RemindersCompanion entry) async {
    final id = await db.into(db.reminders).insert(entry);
    return (db.select(db.reminders)..where((r) => r.id.equals(id))).getSingle();
  }

  Future<void> update(RemindersCompanion entry) =>
      (db.update(db.reminders)..where((r) => r.id.equals(entry.id.value)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())));

  Future<void> setEnabled(int id, {required bool enabled}) =>
      (db.update(db.reminders)..where((r) => r.id.equals(id))).write(
          RemindersCompanion(enabled: Value(enabled), updatedAt: Value(DateTime.now())));

  Future<void> markFired(int id) => (db.update(db.reminders)..where((r) => r.id.equals(id)))
      .write(RemindersCompanion(lastFiredAt: Value(DateTime.now())));

  Future<void> delete(int id) => (db.delete(db.reminders)..where((r) => r.id.equals(id))).go();
}

/// 专注记录仓库（v0.2：仅写入，统计已移除）
class FocusRepo {
  final AppDatabase db;
  FocusRepo(this.db);

  Future<void> insert(FocusSessionsCompanion entry) =>
      db.into(db.focusSessions).insert(entry);
}

/// 键值设置仓库
class SettingsRepo {
  final AppDatabase db;
  SettingsRepo(this.db);

  Future<String?> get(String key) async {
    final row =
        await (db.select(db.settingsKv)..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) => db.into(db.settingsKv).insert(
      SettingsKvCompanion.insert(key: key, value: value),
      onConflict: DoUpdate((old) => SettingsKvCompanion.insert(key: key, value: value)));

  Future<void> remove(String key) =>
      (db.delete(db.settingsKv)..where((s) => s.key.equals(key))).go();

  Stream<String?> watch(String key) {
    final query = db.select(db.settingsKv)..where((s) => s.key.equals(key));
    return query.watchSingleOrNull().map((row) => row?.value);
  }

  Future<Map<String, String>> getAll() async {
    final rows = await db.select(db.settingsKv).get();
    return {for (final r in rows) r.key: r.value};
  }
}

/// 备份服务：全量导出 / 覆盖导入
class BackupService {
  final AppDatabase db;
  BackupService(this.db);

  Future<Map<String, dynamic>> exportAll() async {
    return {
      'version': 2,
      'exportedAt': DateTime.now().toIso8601String(),
      'projects': (await db.select(db.projects).get()).map(_projectJson).toList(),
      'tasks': (await db.select(db.tasks).get()).map(_taskJson).toList(),
      'reminders': (await db.select(db.reminders).get()).map(_reminderJson).toList(),
      'focusSessions': (await db.select(db.focusSessions).get()).map(_sessionJson).toList(),
      'settings': (await db.select(db.settingsKv).get())
          .map((s) => {'key': s.key, 'value': s.value})
          .toList(),
    };
  }

  Map<String, dynamic> _projectJson(Project r) => {
        'id': r.id,
        'name': r.name,
        'color': r.color,
        'note': r.note,
        'archived': r.archived,
        'createdAt': r.createdAt.toIso8601String(),
        'sortOrder': r.sortOrder,
      };

  Map<String, dynamic> _taskJson(Task r) => {
        'id': r.id,
        'projectId': r.projectId,
        'title': r.title,
        'note': r.note,
        'status': r.status,
        'dueDate': r.dueDate?.toIso8601String(),
        'priority': r.priority,
        'sortOrder': r.sortOrder,
        'doneAt': r.doneAt?.toIso8601String(),
        'createdAt': r.createdAt.toIso8601String(),
        'isToday': r.isToday,
      };

  Map<String, dynamic> _reminderJson(Reminder r) => {
        'id': r.id,
        'taskId': r.taskId,
        'title': r.title,
        'type': r.type,
        'fireAt': r.fireAt.toIso8601String(),
        'weekdays': r.weekdays,
        'dayOfMonth': r.dayOfMonth,
        'enabled': r.enabled,
        'lastFiredAt': r.lastFiredAt?.toIso8601String(),
      };

  Map<String, dynamic> _sessionJson(FocusSession r) => {
        'id': r.id,
        'taskId': r.taskId,
        'startedAt': r.startedAt.toIso8601String(),
        'plannedMinutes': r.plannedMinutes,
        'endedAt': r.endedAt?.toIso8601String(),
        'outcome': r.outcome,
        'pauseCount': r.pauseCount,
      };

  /// 全量覆盖式导入，返回导入数量统计
  Future<({int projects, int tasks, int reminders, int sessions})> importAll(
      Map<String, dynamic> data) async {
    int taskCount = 0, reminderCount = 0, sessionCount = 0;
    await db.transaction(() async {
      await db.delete(db.reminders).go();
      await db.delete(db.focusSessions).go();
      await db.delete(db.tasks).go();
      await db.delete(db.projects).go();
      await db.delete(db.settingsKv).go();

      final now = DateTime.now();
      for (final j in (data['projects'] as List).cast<Map<String, dynamic>>()) {
        await db.into(db.projects).insert(ProjectsCompanion.insert(
              id: Value(j['id'] as int),
              name: j['name'] as String,
              color: Value(j['color'] as int? ?? 0xFF4A9B8E),
              note: Value(j['note'] as String? ?? ''),
              archived: Value(j['archived'] as bool? ?? false),
              createdAt: Value(_dt(j['createdAt']) ?? now),
              updatedAt: Value(now),
              sortOrder: Value(j['sortOrder'] as int? ?? 0),
            ));
      }
      for (final j in (data['tasks'] as List).cast<Map<String, dynamic>>()) {
        await db.into(db.tasks).insert(TasksCompanion.insert(
              id: Value(j['id'] as int),
              projectId: Value(j['projectId'] as int?),
              title: j['title'] as String,
              note: Value(j['note'] as String? ?? ''),
              status: Value(j['status'] as String? ?? 'todo'),
              dueDate: Value(_dt(j['dueDate'])),
              priority: Value(j['priority'] as int? ?? 0),
              sortOrder: Value(j['sortOrder'] as int? ?? 0),
              doneAt: Value(_dt(j['doneAt'])),
              createdAt: Value(_dt(j['createdAt']) ?? now),
              updatedAt: Value(now),
              isToday: Value(j['isToday'] as bool? ?? false),
            ));
        taskCount++;
      }
      for (final j in (data['reminders'] as List).cast<Map<String, dynamic>>()) {
        await db.into(db.reminders).insert(RemindersCompanion.insert(
              id: Value(j['id'] as int),
              taskId: Value(j['taskId'] as int?),
              title: Value(j['title'] as String?),
              type: j['type'] as String,
              fireAt: _dt(j['fireAt']) ?? now,
              weekdays: Value(j['weekdays'] as String?),
              dayOfMonth: Value(j['dayOfMonth'] as int?),
              enabled: Value(j['enabled'] as bool? ?? true),
              lastFiredAt: Value(_dt(j['lastFiredAt'])),
              createdAt: Value(now),
              updatedAt: Value(now),
            ));
        reminderCount++;
      }
      for (final j in ((data['focusSessions'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        await db.into(db.focusSessions).insert(FocusSessionsCompanion.insert(
              id: Value(j['id'] as int),
              taskId: Value(j['taskId'] as int?),
              startedAt: _dt(j['startedAt']) ?? now,
              plannedMinutes: j['plannedMinutes'] as int,
              endedAt: Value(_dt(j['endedAt'])),
              outcome: Value(j['outcome'] as String? ?? 'completed'),
              pauseCount: Value(j['pauseCount'] as int? ?? 0),
              createdAt: Value(now),
            ));
        sessionCount++;
      }
      for (final j in (data['settings'] as List? ?? []).cast<Map<String, dynamic>>()) {
        await db.into(db.settingsKv).insert(
            SettingsKvCompanion.insert(key: j['key'] as String, value: j['value'] as String));
      }
    });

    return (
      projects: (data['projects'] as List).length,
      tasks: taskCount,
      reminders: reminderCount,
      sessions: sessionCount,
    );
  }

  static DateTime? _dt(dynamic iso) =>
      iso == null ? null : DateTime.parse(iso as String);

  /// 导出为格式化 JSON 字符串
  Future<String> exportJson() =>
      exportAll().then((d) => const JsonEncoder.withIndent('  ').convert(d));

  /// 导入前自动备份当前数据为本地文件
  Future<String> backupDbFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = p.join(dir.path, 'backups');
    await Directory(backupDir).create(recursive: true);
    final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final dest = p.join(backupDir, 'pre-import-$ts.json');
    final content = await exportJson();
    await File(dest).writeAsString(content);
    return dest;
  }
}
