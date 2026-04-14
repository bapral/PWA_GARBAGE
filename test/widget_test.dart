// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ntpc_garbage_map/main.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: GarbageMapApp()));
    
    // 等待初始化動畫與非同步操作完成
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // 檢查標題或初始化文字是否出現
    expect(
      find.byWidgetPredicate((widget) => 
        widget is Text && (widget.data?.contains('新北市') == true || widget.data?.contains('初始化') == true)
      ), 
      findsWidgets
    );
  });
}
