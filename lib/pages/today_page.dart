import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/database.dart';
import '../data/repositories.dart';
import '../providers.dart';
import '../widgets/edit_sheets.dart';
import '../widgets/task_card.dart';

/// 今日页（v0.2）：今日闹钟区 + 显式勾选的今日任务（项目任务 + 临时任务）
class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(todayTasksProvider);
    final alarmsAsync = ref.watch(todayAlarmsProvider);
    final pomodoro = ref.watch(pomodoroProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('今日', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        actions: [
          if (pomodoro.isRunning)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
                onTap: () => ref.read(homeTabIndexProvider.notifier).state = 2,
                child: Row(
                  children: [
                    const Icon(Icons.timer, color: AppPalette.accentBright, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      _fmtRemaining(pomodoro.remainingOf(DateTime.now())),
                      style: const TextStyle(color: AppPalette.accentBright, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSheet(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
      body: RefreshIndicator(
        color: AppPalette.accent,
        onRefresh: () async => ref.refresh(todayAlarmsProvider.future),
        child: tasksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: AppPalette.accent)),
          error: (e, _) => Center(child: Text('加载失败: $e', style: const TextStyle(color: AppPalette.danger))),
          data: (rows) {
            final alarms = alarmsAsync.value ?? const <Reminder>[];
            if (rows.isEmpty && alarms.isEmpty) {
              return ListView(children: const [
                SizedBox(height: 120),
                EmptyHint('今天还没有安排\n点击「添加」从项目任务选择，或创建临时任务', icon: Icons.wb_sunny_outlined),
              ]);
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                if (alarms.isNotEmpty) ...[
                  const SectionHeader('今日闹钟'),
                  ...alarms.map((r) => _alarmTile(context, ref, r)),
                ],
                if (rows.isNotEmpty) ...[
                  const SectionHeader('今日任务'),
                  for (final (task, project) in rows)
                    _taskTile(context, ref, task, project),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------- 今日闹钟 ----------

  Widget _alarmTile(BuildContext context, WidgetRef ref, Reminder r) {
    final title = r.taskId == null ? (r.title ?? '闹钟') : '任务提醒';
    final hm = '${r.fireAt.hour.toString().padLeft(2, '0')}:${r.fireAt.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: InkWell(
          onTap: () => ref.read(homeTabIndexProvider.notifier).state = 3,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.alarm, size: 20, color: AppPalette.warning),
                const SizedBox(width: 10),
                Text(hm, style: const TextStyle(fontSize: 15, color: AppPalette.textPrimary)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppPalette.textSecondary),
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: AppPalette.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 今日任务 ----------

  Widget _taskTile(BuildContext context, WidgetRef ref, Task task, Project? project) {
    return Dismissible(
      key: ValueKey('today-${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        decoration: BoxDecoration(
          color: AppPalette.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.remove_circle_outline, color: AppPalette.textSecondary),
      ),
      onDismissed: (_) async {
        final db = await ref.read(databaseProvider.future);
        await TaskRepo(db).setToday(task.id, value: false);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TaskCard(
          task: task,
          project: project,
          temporary: project == null,
          trailing: Tooltip(
            message: '移出今日',
            child: IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18, color: AppPalette.textSecondary),
              onPressed: () async {
                final db = await ref.read(databaseProvider.future);
                await TaskRepo(db).setToday(task.id, value: false);
              },
            ),
          ),
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (_) => TaskEditSheet(project: project, task: task),
          ),
          onToggleDone: () async {
            final db = await ref.read(databaseProvider.future);
            await TaskRepo(db).setDone(task.id, done: task.status != 'done');
          },
        ),
      ),
    );
  }

  // ---------- 添加入口 ----------

  Future<void> _showAddSheet(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('添加到今日', style: TextStyle(fontWeight: FontWeight.w600))),
            ListTile(
              leading: const Icon(Icons.playlist_add_check, color: AppPalette.accentBright),
              title: const Text('从项目任务选择'),
              subtitle: const Text('勾选已有项目任务加入今日', style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
              onTap: () => Navigator.pop(ctx, 0),
            ),
            ListTile(
              leading: const Icon(Icons.bolt_outlined, color: AppPalette.warning),
              title: const Text('添加临时任务'),
              subtitle: const Text('不关联项目的当日事项', style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
              onTap: () => Navigator.pop(ctx, 1),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 0) {
      await _pickProjectTask(context, ref);
    } else {
      await _addTempTask(context, ref);
    }
  }

  /// 从项目任务选择：按项目分组列出未完成任务，点选加入今日
  Future<void> _pickProjectTask(BuildContext context, WidgetRef ref) async {
    final db = await ref.read(databaseProvider.future);
    final options = await TaskRepo(db).getOpenTasksWithProject();
    if (!context.mounted) return;
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有未完成的项目任务，可添加临时任务')),
      );
      return;
    }
    // 按项目分组
    final grouped = <Project, List<Task>>{};
    for (final (t, p) in options) {
      grouped.putIfAbsent(p, () => []).add(t);
    }
    final selected = await showModalBottomSheet<Task>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择任务加入今日', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final entry in grouped.entries)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Row(
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: Color(entry.key.color), shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(entry.key.name, style: const TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
                      ],
                    ),
                  ),
                  for (final t in entry.value)
                    ListTile(
                      dense: true,
                      title: Text(t.title, style: const TextStyle(fontSize: 14, color: AppPalette.textPrimary)),
                      trailing: const Icon(Icons.add_circle_outline, size: 20, color: AppPalette.accent),
                      onTap: () => Navigator.pop(ctx, t),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await TaskRepo(db).setToday(selected.id, value: true);
  }

  /// 添加临时任务：输入标题 → 创建无项目任务并加入今日
  Future<void> _addTempTask(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('添加临时任务', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppPalette.textPrimary),
          decoration: const InputDecoration(hintText: '要做什么？'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            style: FilledButton.styleFrom(backgroundColor: AppPalette.accent, foregroundColor: AppPalette.background),
            child: const Text('加入今日'),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    final db = await ref.read(databaseProvider.future);
    await TaskRepo(db).create(TasksCompanion.insert(
      title: title.trim(),
      isToday: const Value(true),
    ));
  }

  static String _fmtRemaining(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }
}
