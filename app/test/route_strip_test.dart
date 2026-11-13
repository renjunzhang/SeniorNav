import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/features/route/route_strip.dart';
import 'package:seniornav/route_summary.dart';

RouteSummary _direct() => RouteSummary(
  mode: RouteMode.metro,
  durationSec: 1740,
  distanceM: 10953,
  fetchedAt: DateTime(2026, 11, 13, 8, 15),
  walkM: 313,
  legs: const [
    TransitLeg(
      lineName: '轨道交通1号线',
      lineType: LineType.metro,
      direction: '张洼方向',
      boardStop: '合肥南站(C口)',
      alightStop: '合肥火车站',
      stopCount: 10,
      boardWalkM: 60,
    ),
  ],
);

RouteSummary _transfer() => RouteSummary(
  mode: RouteMode.metro,
  durationSec: 3819,
  distanceM: 14931,
  fetchedAt: DateTime(2026, 11, 13, 8, 15),
  walkM: 941,
  legs: const [
    TransitLeg(
      lineName: '轨道交通5号线',
      lineType: LineType.metro,
      direction: '汲桥路方向',
      boardStop: '合肥南站(C口)',
      alightStop: '中国科大东区站',
      stopCount: 5,
      boardWalkM: 60,
    ),
    TransitLeg(
      lineName: '省二院健康专线',
      lineType: LineType.bus,
      direction: '仁济医院方向',
      boardStop: '安徽省第二人民医院(黄山路院区)站',
      alightStop: '站前广场站',
      stopCount: 5,
      boardWalkM: 495,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  RouteSummary route, {
  double scale = 1,
  String destination = '火车站',
  String startLabel = '当前位置',
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RouteStrip(
            route: route,
            destination: destination,
            startLabel: startLabel,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('直达示意图：起点、上下车站、方向、站数、各段步行与终点齐全', (tester) async {
    await _pump(tester, _direct());
    expect(find.text('当前位置'), findsOneWidget);
    expect(find.text('上车站'), findsOneWidget);
    expect(find.text('下车站'), findsOneWidget);
    expect(find.text('终点'), findsOneWidget);
    expect(find.text('合肥南站(C口)'), findsOneWidget);
    expect(find.text('合肥火车站'), findsOneWidget);
    expect(find.text('火车站'), findsOneWidget);
    expect(find.text('轨道交通1号线'), findsOneWidget);
    expect(find.text('开往 张洼方向'), findsOneWidget);
    expect(find.textContaining('坐 10 站'), findsOneWidget);
    expect(find.text('步行约 60 米'), findsOneWidget);
    expect(find.text('步行约 250 米'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存路线的起点标签显示上次查询位置', (tester) async {
    await _pump(tester, _direct(), startLabel: '上次查询位置');
    expect(find.text('上次查询位置'), findsOneWidget);
    expect(find.text('当前位置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换乘示意图：换乘标签、两段线路与换乘步行独立可见', (tester) async {
    await _pump(tester, _transfer());
    expect(find.text('下车 · 换乘'), findsOneWidget);
    expect(find.text('上车站'), findsNWidgets(2));
    expect(find.text('轨道交通5号线'), findsOneWidget);
    expect(find.text('省二院健康专线'), findsOneWidget);
    expect(find.text('安徽省第二人民医院(黄山路院区)站'), findsOneWidget);
    expect(find.text('步行约 500 米'), findsOneWidget);
    expect(find.text('步行约 390 米'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三段乘车不截断，线路全部可见', (tester) async {
    final route = RouteSummary(
      mode: RouteMode.transit,
      durationSec: 3600,
      distanceM: 20000,
      fetchedAt: DateTime(2026, 11, 13, 8, 15),
      walkM: 300,
      legs: const [
        TransitLeg(lineName: '示例一线', lineType: LineType.bus, boardWalkM: 100),
        TransitLeg(lineName: '示例二线', lineType: LineType.bus, boardWalkM: 100),
        TransitLeg(lineName: '示例三线', lineType: LineType.bus, boardWalkM: 100),
      ],
    );
    await _pump(tester, route);
    expect(find.text('示例一线'), findsOneWidget);
    expect(find.text('示例二线'), findsOneWidget);
    expect(find.text('示例三线'), findsOneWidget);
    expect(find.text('下车 · 换乘'), findsNWidgets(2));
    expect(find.textContaining('请打开百度地图查看'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('字段缺失时降级显示，不编造站名、方向与站数', (tester) async {
    final route = RouteSummary(
      mode: RouteMode.transit,
      durationSec: 1200,
      distanceM: 5000,
      fetchedAt: DateTime(2026, 11, 13, 8, 15),
      legs: const [TransitLeg()],
    );
    await _pump(tester, route);
    expect(find.text('公交'), findsOneWidget);
    expect(find.text('站名以百度地图为准'), findsNWidgets(2));
    expect(find.textContaining('开往'), findsNothing);
    expect(find.textContaining('坐 '), findsNothing);
    expect(find.textContaining('步行'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('2 倍字体长站名换乘方案可滚动且不出错', (tester) async {
    await _pump(tester, _transfer(), scale: 2);
    await tester.ensureVisible(find.text('终点'));
    expect(find.text('终点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}