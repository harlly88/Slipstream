// 渲染启动页同款水滴图标为 PNG（用作应用图标源图）
// 运行：flutter test test/render_launcher_icon_test.dart --update-goldens
// 产物：test/goldens/icon_foreground.png（自适应图标前景，透明底）
//       test/goldens/icon_full.png（完整图标，圆角深底）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Flutter SDK 自带的 Material 图标合并字体（含水滴图标）
const _fontPath =
    r'C:\greensoft\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf';

// 与启动页 _SplashScreen 保持一致的颜色
const _accent = Color(0xFF4A9B8E);
const _background = Color(0xFF1A1D29);

Future<void> _loadMaterialIcons() async {
  final bytes = await File(_fontPath).readAsBytes();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(bytes.buffer.asByteData()));
  await loader.load();
}

void main() {
  setUpAll(() async {
    // 字体不存在则跳过（非本机环境）
    if (!File(_fontPath).existsSync()) {
      throw StateError('Material 图标字体不存在：$_fontPath');
    }
    await _loadMaterialIcons();
  });

  testWidgets('自适应图标前景：透明底水滴 1024x1024', (tester) async {
    tester.view.physicalSize = const Size(1024, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: const Center(
            child: Icon(Icons.water_drop_outlined, size: 440, color: _accent),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/icon_foreground.png'),
    );
  });

  testWidgets('完整图标：圆角深底水滴 512x512', (tester) async {
    tester.view.physicalSize = const Size(512, 512);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(115),
              child: Container(
                width: 512,
                height: 512,
                color: _background,
                alignment: Alignment.center,
                child: const Icon(Icons.water_drop_outlined,
                    size: 230, color: _accent),
              ),
            ),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/icon_full.png'),
    );
  });
}
