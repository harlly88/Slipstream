import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'main.dart' show bootstrap;
import 'pages/alarm_page.dart';
import 'pages/board_page.dart';
import 'pages/focus_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/settings_page.dart';
import 'pages/today_page.dart';
import 'providers.dart';
import 'widgets/alarm_ring_overlay.dart';

/// 主题色板（参考 hemi-sync 设计：深蓝灰 + 紫蓝 + 青绿强调）
class AppPalette {
  static const background = Color(0xFF1A1D29);
  static const surface = Color(0xFF22263A);
  static const surfaceHigh = Color(0xFF2D3561);
  static const accent = Color(0xFF4A9B8E);
  static const accentBright = Color(0xFF6BC4B4);
  static const textPrimary = Color(0xFFE8E8E8);
  static const textSecondary = Color(0xFF9AA0B5);
  static const danger = Color(0xFFE06C6C);
  static const warning = Color(0xFFE0B36C);

  static const projectColors = [
    0xFF4A9B8E, 0xFF5B8DD9, 0xFF9B6CD9, 0xFFD96C9B,
    0xFFD98A5B, 0xFF8AD95B, 0xFF5BC4D9, 0xFFB8D95B,
  ];
}

class QingliuApp extends ConsumerStatefulWidget {
  const QingliuApp({super.key});

  @override
  ConsumerState<QingliuApp> createState() => _QingliuAppState();
}

class _QingliuAppState extends ConsumerState<QingliuApp> {
  @override
  void initState() {
    super.initState();
    // 延迟到首帧后执行启动引导（通知初始化等）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bootstrap(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final onboarded = ref.watch(onboardedProvider);

    return MaterialApp(
      title: '轻流',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.dark),
      // 闹钟响铃页覆盖在最上层（全屏意图/通知点击触发，v0.5）
      builder: (context, child) {
        final ringing = ref.watch(alarmRingProvider);
        return Stack(
          children: [
            child!,
            if (ringing != null)
              AlarmRingOverlay(alarmId: ringing.id, title: ringing.title),
          ],
        );
      },
      home: onboarded.when(
        loading: () => const _SplashScreen(),
        // 出错时把异常显示出来（而不是永远停在启动页，便于定位问题）
        error: (e, st) => _StartupErrorScreen(error: e, stackTrace: st),
        data: (done) => done ? const HomeShell() : const OnboardingPage(),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppPalette.accent,
      brightness: brightness,
    ).copyWith(
      surface: AppPalette.background,
      primary: AppPalette.accentBright,
      secondary: AppPalette.surfaceHigh,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppPalette.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppPalette.background,
        foregroundColor: AppPalette.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppPalette.surface,
        indicatorColor: AppPalette.accent.withValues(alpha: 0.3),
        iconTheme: WidgetStateProperty.resolveWith((states) => const IconThemeData(
              color: AppPalette.textSecondary,
            )),
        labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 11, color: AppPalette.textSecondary)),
      ),
      cardTheme: const CardThemeData(
        color: AppPalette.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: AppPalette.textSecondary),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppPalette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppPalette.accent,
        foregroundColor: AppPalette.background,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppPalette.surfaceHigh,
        contentTextStyle: TextStyle(color: AppPalette.textPrimary),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.water_drop_outlined, size: 56, color: AppPalette.accent),
            SizedBox(height: 12),
            Text('轻流', style: TextStyle(fontSize: 22, color: AppPalette.textPrimary)),
          ],
        ),
      ),
    );
  }
}

/// 启动失败提示页：显示异常详情 + 重试（避免无提示地卡在启动页）
class _StartupErrorScreen extends ConsumerWidget {
  final Object error;
  final StackTrace stackTrace;

  const _StartupErrorScreen({required this.error, required this.stackTrace});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppPalette.danger),
              const SizedBox(height: 12),
              const Text('启动失败了', style: TextStyle(fontSize: 18, color: AppPalette.textPrimary)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppPalette.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    '$error\n\n$stackTrace',
                    style: const TextStyle(fontSize: 12, color: AppPalette.textSecondary),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                // 刷新数据链路（数据库 + 引导状态）重试
                onPressed: () {
                  // ignore: unused_result
                  ref.refresh(databaseProvider);
                  // ignore: unused_result
                  ref.refresh(onboardedProvider);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部导航主框架：今日 / 看板 / 专注 / 闹钟 / 设置
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _pages = [
    TodayPage(),
    BoardPage(),
    FocusPage(),
    AlarmPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(homeTabIndexProvider);
    return Scaffold(
      body: _pages[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => ref.read(homeTabIndexProvider.notifier).state = i,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: '今日'),
          NavigationDestination(icon: Icon(Icons.view_kanban_outlined), selectedIcon: Icon(Icons.view_kanban), label: '看板'),
          NavigationDestination(icon: Icon(Icons.timer_outlined), selectedIcon: Icon(Icons.timer), label: '专注'),
          NavigationDestination(icon: Icon(Icons.alarm_outlined), selectedIcon: Icon(Icons.alarm), label: '闹钟'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
