import 'package:flutter/material.dart';

import '../app.dart';
import '../data/database.dart';

/// 优先级显示
extension TaskPriorityX on Task {
  String get priorityLabel => switch (priority) { 2 => '紧急', 1 => '重要', _ => '' };
  IconData get priorityIcon => switch (priority) {
        2 => Icons.flag,
        1 => Icons.flag_outlined,
        _ => Icons.flag_outlined,
      };
}

/// 任务卡片（今日页 / 看板共用）
class TaskCard extends StatelessWidget {
  final Task task;
  final Project? project;
  final VoidCallback? onTap;
  final VoidCallback? onToggleDone;
  final Widget? trailing;

  /// 临时任务（无项目）标记，元信息行显示「临时」
  final bool temporary;

  const TaskCard({
    super.key,
    required this.task,
    this.project,
    this.onTap,
    this.onToggleDone,
    this.trailing,
    this.temporary = false,
  });

  @override
  Widget build(BuildContext context) {
    final done = task.status == 'done';
    final overdue = task.dueDate != null &&
        !done &&
        task.dueDate!.isBefore(DateTime.now());

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // 完成勾选
              if (onToggleDone != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GestureDetector(
                    onTap: onToggleDone,
                    child: Icon(
                      done ? Icons.check_circle : Icons.circle_outlined,
                      color: done ? AppPalette.accent : AppPalette.textSecondary,
                      size: 22,
                    ),
                  ),
                ),
              // 项目色条
              if (project != null)
                Container(
                  width: 3,
                  height: 34,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: Color(project!.color),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              // 主体
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (task.priority > 0) ...[
                          Icon(
                            task.priorityIcon,
                            size: 14,
                            color: task.priority == 2 ? AppPalette.danger : AppPalette.warning,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: done ? AppPalette.textSecondary : AppPalette.textPrimary,
                              decoration: done ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (project != null) ...[
                          Text(project!.name,
                              style: const TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
                          const SizedBox(width: 12),
                        ],
                        if (temporary)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppPalette.surfaceHigh,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('临时',
                                style: TextStyle(fontSize: 11, color: AppPalette.textSecondary)),
                          ),
                        if (temporary) const SizedBox(width: 12),
                        if (task.dueDate != null)
                          Row(
                            children: [
                              Icon(Icons.schedule,
                                  size: 13,
                                  color: overdue ? AppPalette.danger : AppPalette.textSecondary),
                              const SizedBox(width: 3),
                              Text(
                                _formatDue(task.dueDate!),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: overdue ? AppPalette.danger : AppPalette.textSecondary),
                              ),
                              const SizedBox(width: 12),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDue(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = day.difference(today).inDays;
    final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '明天 $hm';
    if (diff == -1) return '昨天 $hm';
    if (diff < 0) return '$diff 天前';
    return '${d.month}/${d.day} $hm';
  }
}

/// 空状态提示
class EmptyHint extends StatelessWidget {
  final String text;
  final IconData icon;
  const EmptyHint(this.text, {super.key, this.icon = Icons.inbox_outlined});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppPalette.textSecondary),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: AppPalette.textSecondary, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// 区块标题
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const SectionHeader(this.title, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}
