import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/database.dart';
import '../data/repositories.dart';
import '../providers.dart';
import '../widgets/edit_sheets.dart';
import '../widgets/task_card.dart';

/// 看板页：项目横向切换 + 三列（待办/进行中/已完成）拖拽
class BoardPage extends ConsumerStatefulWidget {
  const BoardPage({super.key});

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  static const _columns = [
    ('todo', '待办', Icons.inbox_outlined),
    ('doing', '进行中', Icons.play_circle_outline),
    ('done', '已完成', Icons.check_circle_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsProvider);
    final selectedId = ref.watch(selectedProjectIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '看板',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '新建项目',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => const ProjectEditSheet(),
            ),
          ),
        ],
      ),
      body: projectsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppPalette.accent),
        ),
        error: (e, _) => Center(
          child: Text(
            '加载失败: $e',
            style: const TextStyle(color: AppPalette.danger),
          ),
        ),
        data: (projects) {
          if (projects.isEmpty) {
            return EmptyHint(
              '还没有项目\n点击右上角新建一个',
              icon: Icons.dashboard_outlined,
            );
          }
          final project = projects.firstWhere(
            (p) => p.id == selectedId,
            orElse: () => projects.first,
          );
          return Column(
            children: [
              // 项目横向切换
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final p in projects)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onLongPress: () => _showProjectMenu(context, ref, p),
                          child: ChoiceChip(
                            label: Text(p.name),
                            selected: p.id == project.id,
                            onSelected: (_) =>
                                ref
                                    .read(selectedProjectIdProvider.notifier)
                                    .state = p
                                    .id,
                            avatar: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: Color(p.color),
                                shape: BoxShape.circle,
                              ),
                            ),
                            labelStyle: TextStyle(
                              fontSize: 13,
                              color: p.id == project.id
                                  ? AppPalette.background
                                  : AppPalette.textPrimary,
                            ),
                            selectedColor: Color(p.color),
                            backgroundColor: AppPalette.surface,
                            showCheckmark: false,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: _BoardView(project: project)),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          final projects = projectsAsync.value;
          if (projects == null || projects.isEmpty) return;
          final project = projects.firstWhere(
            (p) => p.id == ref.read(selectedProjectIdProvider),
            orElse: () => projects.first,
          );
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (_) => TaskEditSheet(project: project),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 长按项目 chip：编辑 / 归档 / 删除
  void _showProjectMenu(BuildContext context, WidgetRef ref, Project p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                p.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.edit_outlined,
                color: AppPalette.accentBright,
              ),
              title: const Text('编辑项目'),
              onTap: () {
                Navigator.pop(sheetCtx);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ProjectEditSheet(project: p),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.archive_outlined,
                color: AppPalette.warning,
              ),
              title: const Text('归档项目'),
              subtitle: const Text(
                '从看板隐藏，可在设置中恢复',
                style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                final ok = await _confirm(
                  context,
                  '归档项目？',
                  '「${p.name}」将从看板隐藏，任务数据保留，可随时在设置中恢复。',
                  '归档',
                  AppPalette.accent,
                );
                if (ok != true) return;
                final db = await ref.read(databaseProvider.future);
                await ProjectRepo(db).archive(p.id, archived: true);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppPalette.danger,
              ),
              title: const Text(
                '删除项目',
                style: TextStyle(color: AppPalette.danger),
              ),
              subtitle: const Text(
                '项目下全部任务、提醒、专注记录将一并删除',
                style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                final ok = await _confirm(
                  context,
                  '删除项目？',
                  '「${p.name}」及其全部任务、提醒、专注记录将被永久删除，无法恢复。',
                  '删除',
                  AppPalette.danger,
                );
                if (ok != true) return;
                final db = await ref.read(databaseProvider.future);
                await ProjectRepo(db).delete(p.id);
                // 级联删除后重建提醒调度，清理已删任务的系统通知
                await rescheduleAllReminders(
                  db,
                  ref.read(notificationServiceProvider),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('已删除「${p.name}」')));
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirm(
    BuildContext context,
    String title,
    String content,
    String action,
    Color actionColor,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Text(
          content,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: actionColor),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

/// 三列看板主体
class _BoardView extends ConsumerWidget {
  final Project project;
  const _BoardView({required this.project});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(projectTasksProvider(project.id));
    return tasksAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: AppPalette.accent),
      ),
      error: (e, _) => Center(
        child: Text(
          '加载失败: $e',
          style: const TextStyle(color: AppPalette.danger),
        ),
      ),
      data: (tasks) {
        // 自动将进行中任务移到看板时标记 doing
        return Row(
          children: [
            for (var i = 0; i < _BoardPageState._columns.length; i++)
              Expanded(
                child: _KanbanColumn(
                  project: project,
                  status: _BoardPageState._columns[i].$1,
                  title: _BoardPageState._columns[i].$2,
                  icon: _BoardPageState._columns[i].$3,
                  tasks: tasks
                      .where((t) => t.status == _BoardPageState._columns[i].$1)
                      .toList(),
                  allTasks: tasks,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 单列：DragTarget 接收跨列拖入；卡片 Draggable；卡上 DragTarget 实现同列排序
class _KanbanColumn extends ConsumerWidget {
  final Project project;
  final String status;
  final String title;
  final IconData icon;
  final List<Task> tasks;
  final List<Task> allTasks;

  const _KanbanColumn({
    required this.project,
    required this.status,
    required this.title,
    required this.icon,
    required this.tasks,
    required this.allTasks,
  });

  Future<void> _move(WidgetRef ref, Task task, {double? sortOrder}) async {
    final db = await ref.read(databaseProvider.future);
    await TaskRepo(db).moveTask(task.id, status: status, sortOrder: sortOrder);
  }

  double _sortOrderBefore(Task? before) {
    if (before == null) {
      // 追加到末尾
      return (tasks.isEmpty ? 0 : tasks.last.sortOrder) + 100;
    }
    final idx = tasks.indexOf(before);
    final prev = idx > 0 ? tasks[idx - 1].sortOrder : before.sortOrder - 200;
    return (prev + before.sortOrder) / 2;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<Task>(
      onWillAcceptWithDetails: (details) =>
          details.data.status != status || true,
      onAcceptWithDetails: (details) => _move(ref, details.data),
      builder: (context, candidate, __) {
        final highlighted = candidate.isNotEmpty;
        return Container(
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: highlighted
                ? AppPalette.surfaceHigh.withValues(alpha: 0.4)
                : AppPalette.background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: Row(
                  children: [
                    Icon(icon, size: 15, color: AppPalette.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${tasks.length}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? (highlighted
                          ? const SizedBox.expand()
                          : const Padding(
                              padding: EdgeInsets.all(12),
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: Text(
                                  '拖任务到这里',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppPalette.textSecondary,
                                  ),
                                ),
                              ),
                            ))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(4, 2, 4, 80),
                        itemCount: tasks.length,
                        itemBuilder: (context, index) {
                          final task = tasks[index];
                          return _DraggableCard(
                            task: task,
                            project: project,
                            allTasks: allTasks,
                            onInsertBefore: (moving) => _move(
                              ref,
                              moving,
                              sortOrder: _sortOrderBefore(task),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 可拖拽任务卡：卡片本体 Draggable，同时是 DragTarget（拖到某卡上方 = 插到它前面）
class _DraggableCard extends ConsumerWidget {
  final Task task;
  final Project project;
  final List<Task> allTasks;
  final void Function(Task moving) onInsertBefore;

  const _DraggableCard({
    required this.task,
    required this.project,
    required this.allTasks,
    required this.onInsertBefore,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TaskCard(
        task: task,
        project: null,
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
    );

    return LongPressDraggable<Task>(
      data: task,
      feedback: SizedBox(
        width: MediaQuery.of(context).size.width / 3 - 20,
        child: Opacity(opacity: 0.85, child: card),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: DragTarget<Task>(
        onWillAcceptWithDetails: (details) => details.data.id != task.id,
        onAcceptWithDetails: (details) => onInsertBefore(details.data),
        builder: (context, candidate, __) => Stack(
          children: [
            card,
            if (candidate.isNotEmpty)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(height: 3, color: AppPalette.accent),
              ),
          ],
        ),
      ),
    );
  }
}
