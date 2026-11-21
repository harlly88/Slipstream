import 'package:drift/drift.dart';

part 'database.g.dart';

/// 项目表：一个项目对应一个看板
class Projects extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 100)();
  IntColumn get color => integer().withDefault(const Constant(0xFF4A9B8E))();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// 任务表：status = todo / doing / done；projectId 可空（临时任务）
class Tasks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get projectId => integer().nullable().references(Projects, #id)();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('todo'))();
  DateTimeColumn get dueDate => dateTime().nullable()();
  IntColumn get priority => integer().withDefault(const Constant(0))(); // 0 普通 1 重要 2 紧急
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get doneAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isToday => boolean().withDefault(const Constant(false))();
}

/// 提醒表：type = once / daily / weekly / monthly；taskId 可空（独立闹钟）+ title（闹钟标题）
class Reminders extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get taskId => integer().nullable().references(Tasks, #id)();
  TextColumn get title => text().nullable()();
  TextColumn get type => text()();
  DateTimeColumn get fireAt => dateTime()(); // 首次触发时间（含时分）
  TextColumn get weekdays => text().nullable()(); // weekly 用："1,3,5"（周一=1 周日=7）
  IntColumn get dayOfMonth => integer().nullable()(); // monthly 用
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastFiredAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 专注记录表：outcome = completed / abandoned / manual
class FocusSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get taskId => integer().nullable().references(Tasks, #id)();
  DateTimeColumn get startedAt => dateTime()();
  IntColumn get plannedMinutes => integer()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get outcome => text().withDefault(const Constant('completed'))();
  IntColumn get pauseCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 键值设置表
class SettingsKv extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Projects, Tasks, Reminders, FocusSessions, SettingsKv])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from == 1) {
            // v2：tasks.project_id 改可空 + tasks.is_today；reminders.task_id 改可空 + reminders.title
            // 先补新列，再 TableMigration 重建表改约束（按列名拷贝，旧值安全）
            await m.addColumn(tasks, tasks.isToday);
            await m.alterTable(TableMigration(tasks));
            await m.addColumn(reminders, reminders.title);
            await m.alterTable(TableMigration(reminders));
          }
        },
      );
}
