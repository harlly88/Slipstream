import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/database.dart';
import '../data/repositories.dart';
import '../providers.dart';

/// 任务编辑弹层：创建 / 编辑，含提醒管理（v0.2：项目可空 = 临时任务）
class TaskEditSheet extends ConsumerStatefulWidget {
  final Project? project; // null = 临时任务
  final Task? task; // null = 新建
  final String? initialTitle;

  const TaskEditSheet({super.key, this.project, this.task, this.initialTitle});

  @override
  ConsumerState<TaskEditSheet> createState() => _TaskEditSheetState();
}

class _TaskEditSheetState extends ConsumerState<TaskEditSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _noteCtrl;
  late int _priority;
  DateTime? _dueDate;
  TimeOfDay? _dueTime;
  bool _saving = false;

  /// 当前所属项目（可切换，null = 临时任务）
  Project? _project;

  int? get _taskId => widget.task?.id;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _titleCtrl = TextEditingController(text: t?.title ?? widget.initialTitle ?? '');
    _noteCtrl = TextEditingController(text: t?.note ?? '');
    _priority = t?.priority ?? 0;
    _project = widget.project;
    if (t?.dueDate != null) {
      _dueDate = DateTime(t!.dueDate!.year, t.dueDate!.month, t.dueDate!.day);
      _dueTime = TimeOfDay.fromDateTime(t.dueDate!);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty || _saving) return;
    setState(() => _saving = true);
    final db = await ref.read(databaseProvider.future);
    final repo = TaskRepo(db);
    final due = _dueDate == null
        ? null
        : DateTime(
            _dueDate!.year,
            _dueDate!.month,
            _dueDate!.day,
            _dueTime?.hour ?? 9,
            _dueTime?.minute ?? 0,
          );

    if (widget.task == null) {
      await repo.create(TasksCompanion.insert(
        projectId: Value(_project?.id),
        title: _titleCtrl.text.trim(),
        note: Value(_noteCtrl.text.trim()),
        dueDate: Value(due),
        priority: Value(_priority),
        isToday: Value(widget.project == null), // 从今日页新建临时任务时默认已在今日
      ));
    } else {
      await repo.update(TasksCompanion(
        id: Value(_taskId!),
        projectId: Value(_project?.id),
        title: Value(_titleCtrl.text.trim()),
        note: Value(_noteCtrl.text.trim()),
        dueDate: Value(due),
        priority: Value(_priority),
      ));
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    if (_taskId == null) return;
    final db = await ref.read(databaseProvider.future);
    final notif = ref.read(notificationServiceProvider);
    // 取消关联提醒
    final reminders = await ReminderRepo(db).watchByTask(_taskId!).first;
    for (final r in reminders) {
      await notif.cancelReminder(r.id);
    }
    await TaskRepo(db).delete(_taskId!);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final reminders = _taskId == null
        ? AsyncValue<List<Reminder>>.data(const [])
        : ref.watch(taskRemindersProvider(_taskId!));

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 4, height: 20,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                      color: _project != null ? Color(_project!.color) : AppPalette.textSecondary,
                      borderRadius: BorderRadius.circular(2)),
                ),
                Expanded(
                  child: Text(
                    '${widget.task == null ? '新建任务' : '编辑任务'} · ${_project?.name ?? '临时任务（无项目）'}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppPalette.textPrimary),
                  ),
                ),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, color: AppPalette.textSecondary)),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _titleCtrl,
              autofocus: widget.task == null,
              textInputAction: TextInputAction.next,
              style: const TextStyle(color: AppPalette.textPrimary),
              decoration: const InputDecoration(hintText: '任务标题'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              style: const TextStyle(color: AppPalette.textPrimary),
              decoration: const InputDecoration(hintText: '备注（可选）'),
            ),
            const SizedBox(height: 12),
            // 所属项目（可切换为临时任务）
            _buildProjectRow(),
            const SizedBox(height: 16),
            // 截止
            _buildDueRow(),
            const SizedBox(height: 12),
            // 优先级
            _buildPriorityRow(),
            // 提醒
            if (_taskId != null) ...[
              const Divider(height: 32, color: AppPalette.surfaceHigh),
              _buildRemindersSection(reminders),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.task != null)
                  TextButton(onPressed: _delete, style: TextButton.styleFrom(foregroundColor: AppPalette.danger),
                      child: const Text('删除任务')),
                const Spacer(),
                FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(backgroundColor: AppPalette.accent, foregroundColor: AppPalette.background),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 所属项目选择行（null = 临时任务）
  Widget _buildProjectRow() {
    return InkWell(
      onTap: () async {
        final projects = ref.read(projectsProvider).value ?? const <Project>[];
        // 哨兵包装：区分「选了临时任务」与「关闭面板」
        final picked = await showModalBottomSheet<_ProjectPick>(
          context: context,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('所属项目', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                ListTile(
                  leading: const Icon(Icons.bolt_outlined, color: AppPalette.warning),
                  title: const Text('临时任务（无项目）'),
                  trailing: _project == null ? const Icon(Icons.check, color: AppPalette.accent) : null,
                  onTap: () => Navigator.pop(ctx, const _ProjectPick(null)),
                ),
                for (final p in projects)
                  ListTile(
                    leading: Container(width: 10, height: 10, decoration: BoxDecoration(color: Color(p.color), shape: BoxShape.circle)),
                    title: Text(p.name, style: const TextStyle(color: AppPalette.textPrimary)),
                    trailing: _project?.id == p.id ? const Icon(Icons.check, color: AppPalette.accent) : null,
                    onTap: () => Navigator.pop(ctx, _ProjectPick(p)),
                  ),
              ],
            ),
          ),
        );
        if (picked != null && mounted) {
          setState(() => _project = picked.project);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: AppPalette.background, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined, size: 20, color: AppPalette.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _project?.name ?? '临时任务（无项目）',
                style: const TextStyle(color: AppPalette.textPrimary, fontSize: 14),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: AppPalette.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildDueRow() {
    final label = _dueDate == null
        ? '设置截止时间'
        : '${_dueDate!.month}/${_dueDate!.day}'
            '${_dueTime != null ? ' ${_dueTime!.format(context)}' : ''}';
    return InkWell(
      onTap: () async {
        final d = await showDatePicker(
          context: context,
          initialDate: _dueDate ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (d == null) return;
        if (!mounted) return;
        final t = await showTimePicker(
          context: context,
          initialTime: _dueTime ?? TimeOfDay.now(),
        );
        setState(() {
          _dueDate = d;
          _dueTime = t;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: AppPalette.background, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            const Icon(Icons.event_outlined, size: 20, color: AppPalette.textSecondary),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(color: AppPalette.textPrimary)),
            const Spacer(),
            if (_dueDate != null)
              GestureDetector(
                onTap: () => setState(() { _dueDate = null; _dueTime = null; }),
                child: const Icon(Icons.close, size: 18, color: AppPalette.textSecondary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriorityRow() {
    const options = [(0, '普通', AppPalette.textSecondary), (1, '重要', AppPalette.warning), (2, '紧急', AppPalette.danger)];
    return Row(
      children: [
        for (final (v, label, color) in options) ...[
          ChoiceChip(
            label: Text(label),
            selected: _priority == v,
            onSelected: (_) => setState(() => _priority = v),
            labelStyle: TextStyle(color: _priority == v ? AppPalette.background : color, fontSize: 13),
            selectedColor: color,
            backgroundColor: AppPalette.background,
            showCheckmark: false,
          ),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _buildRemindersSection(AsyncValue<List<Reminder>> reminders) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('提醒', style: TextStyle(fontWeight: FontWeight.w600, color: AppPalette.textPrimary))),
            TextButton.icon(
              onPressed: () => _showReminderEditor(),
              icon: const Icon(Icons.add_alert, size: 18),
              label: const Text('添加', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
        reminders.when(
          loading: () => const SizedBox(height: 24),
          error: (e, _) => Text('加载失败: $e', style: const TextStyle(color: AppPalette.danger)),
          data: (list) => Column(
            children: [
              for (final r in list)
                _reminderTile(r),
              if (list.isEmpty)
                const Text('暂无提醒', style: TextStyle(color: AppPalette.textSecondary, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _reminderTile(Reminder r) {
    final typeLabel = switch (r.type) {
      'daily' => '每天',
      'weekly' => '每周${_weekdayNames(r.weekdays)}',
      'monthly' => '每月${r.dayOfMonth}日',
      _ => '一次',
    };
    final hm = '${r.fireAt.hour.toString().padLeft(2, '0')}:${r.fireAt.minute.toString().padLeft(2, '0')}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(r.type == 'once' ? Icons.alarm : Icons.repeat, color: AppPalette.accentBright, size: 20),
      title: Text('$typeLabel $hm', style: const TextStyle(color: AppPalette.textPrimary, fontSize: 14)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showReminderEditor(existing: r)),
          IconButton(icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => _deleteReminder(r)),
        ],
      ),
    );
  }

  static String _weekdayNames(String? weekdays) {
    if (weekdays == null) return '';
    const names = ['', '一', '二', '三', '四', '五', '六', '日'];
    return weekdays.split(',').where((s) => s.isNotEmpty).map((d) => names[int.parse(d)]).join();
  }

  Future<void> _deleteReminder(Reminder r) async {
    final db = await ref.read(databaseProvider.future);
    await ReminderRepo(db).delete(r.id);
    await ref.read(notificationServiceProvider).cancelReminder(r.id);
  }

  Future<void> _showReminderEditor({Reminder? existing}) async {
    if (_taskId == null) return;
    final type = await _showReminderTypePicker(existing?.type);
    if (type == null || !mounted) return;

    DateTime initial = existing?.fireAt ?? DateTime.now().add(const Duration(hours: 1));
    if (type == 'weekly') initial = _nextWeekday(initial, existing?.weekdays);
    if (type == 'monthly') initial = _nextMonthDay(initial, existing?.dayOfMonth);

    final date = await showDatePicker(
      context: context, initialDate: initial, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null) return;

    final fireAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);

    String? weekdays;
    int? dayOfMonth;
    if (type == 'weekly') {
      final selected = await _showWeekdayPicker(existing?.weekdays);
      if (selected == null || selected.isEmpty) return;
      weekdays = selected;
    } else if (type == 'monthly') {
      dayOfMonth = date.day;
    }

    final db = await ref.read(databaseProvider.future);
    final repo = ReminderRepo(db);
    final task = widget.task!;
    Reminder saved;
    if (existing == null) {
      saved = await repo.create(RemindersCompanion.insert(
        taskId: Value(task.id),
        type: type,
        fireAt: fireAt,
        weekdays: Value(weekdays),
        dayOfMonth: Value(dayOfMonth),
      ));
    } else {
      saved = existing;
      await repo.update(RemindersCompanion(
        id: Value(existing.id),
        type: Value(type),
        fireAt: Value(fireAt),
        weekdays: Value(weekdays),
        dayOfMonth: Value(dayOfMonth),
      ));
    }
    await ref.read(notificationServiceProvider).scheduleReminder(
      saved,
      taskTitle: task.title,
      projectName: _project?.name ?? '',
    );
  }

  Future<String?> _showReminderTypePicker([String? current]) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('提醒类型', style: TextStyle(fontWeight: FontWeight.w600))),
            for (final (v, label, sub) in [
              ('once', '一次性', '到点提醒一次'),
              ('daily', '每天', '按日重复'),
              ('weekly', '每周', '选择星期几'),
              ('monthly', '每月', '选择某日'),
            ])
              ListTile(
                leading: Icon(v == 'once' ? Icons.alarm : Icons.repeat, color: AppPalette.accentBright),
                title: Text(label),
                subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
                trailing: current == v ? const Icon(Icons.check, color: AppPalette.accent) : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _showWeekdayPicker([String? current]) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final selected = (current ?? '').split(',').where((s) => s.isNotEmpty).map(int.parse).toSet();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('选择星期', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 1; i <= 7; i++)
                      FilterChip(
                        label: Text(names[i - 1]),
                        selected: selected.contains(i),
                        onSelected: (on) => setSheet(() => on ? selected.add(i) : selected.remove(i)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    final list = selected.toList()..sort();
                    Navigator.pop(ctx, list.join(','));
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  DateTime _nextWeekday(DateTime base, String? weekdays) {
    // 找到选中星期中最近的日期
    final now = DateTime.now();
    var best = base;
    if (weekdays != null) {
      for (var add = 0; add <= 7; add++) {
        final d = now.add(Duration(days: add));
        if (weekdays.split(',').contains('${d.weekday}')) {
          best = DateTime(d.year, d.month, d.day, base.hour, base.minute);
          break;
        }
      }
    }
    return best;
  }

  DateTime _nextMonthDay(DateTime base, int? dayOfMonth) {
    if (dayOfMonth == null) return base;
    final now = DateTime.now();
    var d = DateTime(now.year, now.month, dayOfMonth, base.hour, base.minute);
    if (d.isBefore(now)) d = DateTime(now.year, now.month + 1, dayOfMonth, base.hour, base.minute);
    return d;
  }
}

/// 项目编辑弹层
class ProjectEditSheet extends ConsumerStatefulWidget {
  final Project? project;
  const ProjectEditSheet({super.key, this.project});

  @override
  ConsumerState<ProjectEditSheet> createState() => _ProjectEditSheetState();
}

class _ProjectEditSheetState extends ConsumerState<ProjectEditSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _noteCtrl;
  late int _color;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.project?.name ?? '');
    _noteCtrl = TextEditingController(text: widget.project?.note ?? '');
    _color = widget.project?.color ?? AppPalette.projectColors[0];
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) return;
    final db = await ref.read(databaseProvider.future);
    final repo = ProjectRepo(db);
    if (widget.project == null) {
      await repo.create(_nameCtrl.text.trim(), _color, _noteCtrl.text.trim());
    } else {
      await repo.update(ProjectsCompanion(
        id: Value(widget.project!.id),
        name: Value(_nameCtrl.text.trim()),
        color: Value(_color),
        note: Value(_noteCtrl.text.trim()),
      ));
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.project == null ? '新建项目' : '编辑项目',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppPalette.textPrimary)),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              autofocus: widget.project == null,
              style: const TextStyle(color: AppPalette.textPrimary),
              decoration: const InputDecoration(hintText: '项目名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              style: const TextStyle(color: AppPalette.textPrimary),
              decoration: const InputDecoration(hintText: '备注（可选）'),
            ),
            const SizedBox(height: 16),
            const Text('颜色标识', style: TextStyle(fontSize: 13, color: AppPalette.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in AppPalette.projectColors)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: _color == c ? Border.all(color: Colors.white, width: 2.5) : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.project != null)
                  TextButton(
                    onPressed: () async {
                      final db = await ref.read(databaseProvider.future);
                      await ProjectRepo(db).archive(widget.project!.id, archived: !widget.project!.archived);
                      if (mounted) Navigator.pop(context);
                    },
                    child: Text(widget.project!.archived ? '取消归档' : '归档项目',
                        style: const TextStyle(color: AppPalette.warning)),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(backgroundColor: AppPalette.accent, foregroundColor: AppPalette.background),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 项目选择哨兵：区分「选了临时任务(null)」与「关闭面板」
class _ProjectPick {
  final Project? project;
  const _ProjectPick(this.project);
}
