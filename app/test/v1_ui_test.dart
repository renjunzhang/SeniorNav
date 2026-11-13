import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/features/route/route_page.dart';
import 'package:seniornav/main.dart' show StartupFailureApp;
import 'package:seniornav/route_summary.dart';
import 'package:seniornav/seniornav_app.dart';

final _place = SavedPlace(
  id: 'public-example',
  slot: 1,
  label: '回家',
  icon: 'home',
  name: '公共测试地点',
  address: '示例地址',
  city: '合肥',
  latitude: 31.8,
  longitude: 117.3,
  updatedAt: DateTime(2026),
  verifiedAt: DateTime(2026),
);

class _Places extends PlaceRepository {
  _Places({this.accepted = true, this.saved = const []});
  bool accepted;
  List<SavedPlace> saved;
  @override
  List<SavedPlace> get places => saved;
  @override
  bool get privacyAccepted => accepted;
  @override
  bool get hasPin => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> acceptPrivacy() async {
    accepted = true;
    notifyListeners();
  }

  @override
  Future<void> savePlace(SavedPlace place) async {}
  @override
  Future<void> deletePlace(String id) async {}
  @override
  Future<void> reorderMore(List<String> ids) async {}
  @override
  Future<void> setPin(String pin) async {}
  @override
  Future<bool> verifyPin(String pin) async => false;
}

class _Poi implements PoiService {
  @override
  Future<List<PoiCandidate>> search({
    required String query,
    required String city,
  }) async => [];
  @override
  Future<PoiCandidate> detail(PoiCandidate candidate) async => candidate;
}

class _Routes implements RouteService {
  int calls = 0;
  @override
  bool busy = false;
  Future<RouteBundle> Function()? handler;
  @override
  Future<RouteBundle> load(SavedPlace destination) async {
    calls++;
    busy = true;
    try {
      if (handler != null) return await handler!();
      throw const AppFailure('网络不好，请打开百度地图。');
    } finally {
      busy = false;
    }
  }
}

class _Navigation implements NavigationService {
  int calls = 0;
  RouteMode? lastMode;
  GeoPoint? lastOrigin;
  @override
  Future<NavigationOutcome> open(
    SavedPlace place,
    RouteMode mode, {
    GeoPoint? origin,
  }) async {
    calls++;
    lastMode = mode;
    lastOrigin = origin;
    return NavigationOutcome.nativeApp;
  }

  @override
  Future<NavigationOutcome> verifyPlace(PoiCandidate candidate) async =>
      NavigationOutcome.nativeApp;
}

void _size(WidgetTester tester, {double scale = 1}) {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

AppServices _services({
  _Places? places,
  _Routes? routes,
  _Navigation? navigation,
}) => AppServices(
  places: places ?? _Places(saved: [_place]),
  poi: _Poi(),
  routes: routes ?? _Routes(),
  navigation: navigation ?? _Navigation(),
);

void main() {
  testWidgets('1.3 倍字体首页五个入口同时可见且触控高度至少 72', (tester) async {
    _size(tester, scale: 1.3);
    await tester.pumpWidget(SeniorNavApp(services: _services()));
    for (var i = 1; i <= 5; i++) {
      final tile = find.byKey(ValueKey('home-slot-$i'));
      expect(tile.hitTestable(), findsOneWidget);
      expect(tester.getSize(tile).height, greaterThanOrEqualTo(72));
      expect(tester.getBottomRight(tile).dy, lessThanOrEqualTo(740));
    }
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('2 倍字体首页允许滚动且最后一个入口可操作', (tester) async {
    _size(tester, scale: 2);
    await tester.pumpWidget(SeniorNavApp(services: _services()));
    await tester.ensureVisible(find.byKey(const ValueKey('home-slot-5')));
    expect(
      find.byKey(const ValueKey('home-slot-5')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('home-slot-5')));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有更多地点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未配置地点只提示设置，不发路线查询', (tester) async {
    _size(tester);
    final routes = _Routes();
    await tester.pumpWidget(
      SeniorNavApp(
        services: _services(places: _Places(), routes: routes),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(find.text('这个地点还没设置'), findsOneWidget);
    expect(routes.calls, 0);
  });

  testWidgets('拒绝隐私确认不查询位置和路线', (tester) async {
    _size(tester);
    final routes = _Routes();
    await tester.pumpWidget(
      SeniorNavApp(
        services: _services(
          places: _Places(accepted: false, saved: [_place]),
          routes: routes,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂不查询'));
    await tester.pumpAndSettle();
    expect(routes.calls, 0);
    expect(find.byType(RoutePage), findsNothing);
  });

  testWidgets('路线失败仍可打开地图并选择步行', (tester) async {
    _size(tester);
    final navigation = _Navigation();
    await tester.pumpWidget(
      SeniorNavApp(services: _services(navigation: navigation)),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(find.text('网络不好，请打开百度地图。'), findsOneWidget);
    await tester.tap(find.text('走路'));
    await tester.tap(find.byKey(const ValueKey('open-map')));
    await tester.pumpAndSettle();
    expect(navigation.calls, 1);
    expect(navigation.lastMode, RouteMode.walking);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('超过 5 秒只提示等待，反复点击和退出重进不重发', (tester) async {
    _size(tester);
    final completer = Completer<RouteBundle>();
    final routes = _Routes()..handler = () => completer.future;
    await tester.pumpWidget(SeniorNavApp(services: _services(routes: routes)));
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('仍在查询…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('refresh-routes')))
          .onPressed,
      isNull,
    );
    expect(routes.calls, 1);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(routes.calls, 1);
    expect(find.textContaining('上一条查询仍在处理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-map')).hitTestable(),
      findsOneWidget,
    );
    completer.completeError(const AppFailure('查询未完成'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('refresh-routes')))
          .onPressed,
      isNotNull,
    );
    expect(routes.calls, 1);
    expect(find.text('可以重新查询路线，或直接打开百度地图。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('长站名摘要在 2 倍字体下可滚动而导航按钮仍可见', (tester) async {
    _size(tester, scale: 2);
    final now = DateTime.now();
    final routes = _Routes()
      ..handler = () async => RouteBundle(
        recommendedMode: RouteMode.transit,
        fetchedAt: now,
        transit: RouteSummary(
          mode: RouteMode.transit,
          durationSec: 1200,
          distanceM: 5000,
          fetchedAt: now,
          legs: const [
            TransitLeg(
              lineName: '公共示例公交线路',
              direction: '公共示例终点站方向',
              boardStop: '公共示例换乘中心公交站（东侧入口）',
              alightStop: '公共示例终点公交站',
              stopCount: 6,
            ),
          ],
        ),
      );
    await tester.pumpWidget(SeniorNavApp(services: _services(routes: routes)));
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('open-map')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('不用换车'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('有摘要时仍展示补查提示和长距离告警', (tester) async {
    _size(tester);
    final now = DateTime.now();
    final routes = _Routes()
      ..handler = () async => RouteBundle(
        recommendedMode: RouteMode.walking,
        fetchedAt: now,
        walking: RouteSummary(
          mode: RouteMode.walking,
          durationSec: 3600,
          distanceM: 4000,
          fetchedAt: now,
        ),
        walkingMessage: '位置可能不准，请核对起点。',
      );
    await tester.pumpWidget(SeniorNavApp(services: _services(routes: routes)));
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(find.text('距离较远，建议直接打开百度地图'), findsOneWidget);
    expect(find.text('位置可能不准，请核对起点。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('启动失败不自动重试、不泄漏异常，显式重试期间防连点', (tester) async {
    _size(tester, scale: 2);
    var attempts = 0;
    final attempt = Completer<void>();
    await tester.pumpWidget(
      StartupFailureApp(
        onRetry: () {
          attempts++;
          return attempt.future;
        },
      ),
    );
    await tester.pump(const Duration(seconds: 10));
    expect(attempts, 0);
    await tester.ensureVisible(find.byKey(const ValueKey('retry-startup')));
    await tester.tap(find.byKey(const ValueKey('retry-startup')));
    await tester.pump();
    expect(attempts, 1);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('retry-startup')))
          .onPressed,
      isNull,
    );
    attempt.completeError(Exception('internal storage detail'));
    await tester.pumpAndSettle();
    expect(find.textContaining('internal storage detail'), findsNothing);
    expect(find.text('暂时无法打开常用地点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final stale in [false, true]) {
    testWidgets(stale ? '旧摘要不向导航回退传递过期起点' : '新摘要可向导航回退传递有效起点', (tester) async {
      _size(tester);
      final point = const GeoPoint(31.8, 117.3);
      final routes = _Routes()
        ..handler = () async => RouteBundle(
          recommendedMode: RouteMode.walking,
          fetchedAt: DateTime.now().subtract(Duration(minutes: stale ? 6 : 0)),
          origin: point,
        );
      final navigation = _Navigation();
      await tester.pumpWidget(
        SeniorNavApp(
          services: _services(routes: routes, navigation: navigation),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('home-slot-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-map')));
      await tester.pumpAndSettle();
      expect(navigation.lastOrigin, stale ? isNull : same(point));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('正式界面与启动失败页均加载中文系统文案', (tester) async {
    _size(tester);
    await tester.pumpWidget(SeniorNavApp(services: _services()));
    await tester.pumpAndSettle();
    final homeContext = tester.element(find.text('SeniorNav'));
    expect(Localizations.localeOf(homeContext), const Locale('zh', 'CN'));
    expect(MaterialLocalizations.of(homeContext).cancelButtonLabel, '取消');
    await tester.pumpWidget(StartupFailureApp(onRetry: () async {}));
    await tester.pumpAndSettle();
    final failureContext = tester.element(find.text('暂时无法打开常用地点'));
    expect(Localizations.localeOf(failureContext), const Locale('zh', 'CN'));
    expect(MaterialLocalizations.of(failureContext).backButtonTooltip, '返回');
  });
}
