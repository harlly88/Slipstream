import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../data/repositories.dart';
import '../providers.dart';

/// 设置页：数据备份 / 归档 / 关于
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '设置',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('数据备份'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.file_upload_outlined,
                      color: AppPalette.accentBright,
                    ),
                    title: const Text(
                      '导出 JSON 备份',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppPalette.textPrimary,
                      ),
                    ),
                    subtitle: const Text(
                      '全量：项目 / 任务 / 提醒 / 专注记录',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                    onTap: () => _export(context, ref),
                  ),
                  _divider(),
                  ListTile(
                    leading: const Icon(
                      Icons.file_download_outlined,
                      color: AppPalette.accentBright,
                    ),
                    title: const Text(
                      '导入备份（覆盖恢复）',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppPalette.textPrimary,
                      ),
                    ),
                    subtitle: const Text(
                      '导入前会自动备份当前数据',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                    onTap: () => _import(context, ref),
                  ),
                ],
              ),
            ),
            _section('归档'),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.archive_outlined,
                  color: AppPalette.warning,
                ),
                title: const Text(
                  '查看归档项目',
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppPalette.textPrimary,
                  ),
                ),
                onTap: () => _showArchived(context, ref),
              ),
            ),
            _section('关于'),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '轻流 v0.4.0',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppPalette.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Local-first 个人项目跟进工具。数据全部存储在本机，'
                      '默认零网络请求，开源可审计（MIT License）。',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 1,
        color: AppPalette.textSecondary,
      ),
    ),
  );

  Widget _divider() => const Divider(
    height: 1,
    indent: 16,
    endIndent: 16,
    color: AppPalette.background,
  );

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final db = await ref.read(databaseProvider.future);
      final json = await BackupService(db).exportJson();
      final ts = DateTime.now().toIso8601String().split('T').first;
      final fileName = 'qingliu-backup-$ts.json';
      if (!context.mounted) return;

      // 选择：分享 / 保存到本地
      final choice = await showModalBottomSheet<int>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '导出备份',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.share_outlined,
                  color: AppPalette.accentBright,
                ),
                title: const Text('分享'),
                subtitle: const Text(
                  '发送到微信、邮件等',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.textSecondary,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, 0),
              ),
              ListTile(
                leading: const Icon(
                  Icons.save_outlined,
                  color: AppPalette.warning,
                ),
                title: const Text('保存到本地'),
                subtitle: const Text(
                  '选择下载等目录保存 JSON 文件',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.textSecondary,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, 1),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (choice == null || !context.mounted) return;

      if (choice == 0) {
        // 分享
        final tempFile = File(
          p.join((await getTemporaryDirectory()).path, fileName),
        );
        await tempFile.writeAsString(json, flush: true);
        if (context.mounted) {
          await SharePlus.instance.share(
            ShareParams(files: [XFile(tempFile.path)], text: '轻流数据备份'),
          );
        }
      } else {
        // 保存到本地（SAF 存储选择器，可选下载等目录）
        final path = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: Uint8List.fromList(utf8.encode(json)),
        );
        if (path == null) return; // 用户取消
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已保存：$path')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final file = picked?.files.single;
    final bytes = file?.bytes;
    if (bytes == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('导入备份？', style: TextStyle(fontSize: 16)),
        content: const Text(
          '将覆盖当前全部数据（覆盖前自动备份）',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppPalette.danger),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;

    try {
      final db = await ref.read(databaseProvider.future);
      final backup = BackupService(db);
      await backup.backupDbFile();
      final result = await backup.importAll(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
      await rescheduleAllReminders(db, ref.read(notificationServiceProvider));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导入 ${result.projects} 项目 / ${result.tasks} 任务 / ${result.reminders} 提醒',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  Future<void> _showArchived(BuildContext context, WidgetRef ref) async {
    final db = await ref.read(databaseProvider.future);
    final archived = await ProjectRepo(db).getAll(includeArchived: true);
    final list = archived.where((p) => p.archived).toList();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '归档项目',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '暂无归档项目',
                    style: TextStyle(color: AppPalette.textSecondary),
                  ),
                ),
              ),
            for (final p in list)
              ListTile(
                leading: Icon(Icons.archive, color: Color(p.color)),
                title: Text(
                  p.name,
                  style: const TextStyle(color: AppPalette.textPrimary),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      child: const Text('恢复'),
                      onPressed: () async {
                        await ProjectRepo(db).archive(p.id, archived: false);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: AppPalette.danger,
                      ),
                      tooltip: '删除',
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (d) => AlertDialog(
                            backgroundColor: AppPalette.surface,
                            title: const Text(
                              '删除项目？',
                              style: TextStyle(fontSize: 16),
                            ),
                            content: Text(
                              '「${p.name}」及其全部任务、提醒、专注记录将被永久删除，无法恢复。',
                              style: const TextStyle(fontSize: 13, height: 1.5),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(d, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(d, true),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppPalette.danger,
                                ),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await ProjectRepo(db).delete(p.id);
                        // 级联删除后重建提醒调度，清理已删任务的系统通知
                        await rescheduleAllReminders(
                          db,
                          ref.read(notificationServiceProvider),
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
