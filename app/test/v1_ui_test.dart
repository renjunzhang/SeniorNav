import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/features/route/route_page.dart';
import 'package:seniornav/features/route/route_strip.dart';
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
  NavigationOutcome outcome = NavigationOutcome.nativeApp;
  @override
  Future<NavigationOutcome> open(
    SavedPlace place,
    RouteMode mode, {
    GeoPoint? origin,
  }) async {
    calls++;
    lastMode = mode;
    lastOrigin = origin;
    return outcome;
  }

  @override
  Future<NavigationOutcome> verifyPlace(PoiCandidate candidate) async =>
      NavigationOutcome.nativeApp;
}

class _Cache implements RouteCache {
  final Map<String, RouteBundle> store = {};
  int saves = 0;
  @override
  Future<void> save(String placeId, RouteBundle bundle) async {
    saves++;
    store[placeId] = bundle;
  }

  @override
  Future<RouteBundle?> read(String placeId) async => store[placeId];
}

void _size(
  WidgetTester tester, {
  double scale = 1,
  Size size = const Size(360, 740),
}) {
  tester.view.physicalSize = size;
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
  _Cache? cache,
}) => AppServices(
  places: places ?? _Places(saved: [_place]),
  poi: _Poi(),
  routes: routes ?? _Routes(),
  navigation: navigation ?? _Navigation(),
  cache: cache ?? _Cache(),
);

Finder _modeFinder(RouteMode mode) =>
    find.byKey(ValueKey('route-mode-${mode.name}'));

SemanticsProperties _modeSemantics(WidgetTester tester, RouteMode mode) =>
    tester
        .widget<Semantics>(
          find
              .descendant(
                of: _modeFinder(mode),
                matching: find.byType(Semantics),
              )
              .first,
        )
        .properties;

RouteBundle _threeModes({RouteMode recommended = RouteMode.metro}) {
  final now = DateTime.now();
  return RouteBundle(
    recommendedMode: recommended,
    fetchedAt: now,
    metro: RouteSummary(
      mode: RouteMode.metro,
      durationSec: 900,
      distanceM: 5000,
      fetchedAt: now,
      legs: const [
        TransitLeg(
          lineName: '示例地铁线',
          lineType: LineType.metro,
          direction: '公共地标方向',
          boardStop: '示例上车站',
          alightStop: '示例下车站',
          stopCount: 4,
        ),
      ],
    ),
    transit: RouteSummary(
      mode: RouteMode.transit,
      durationSec: 1800,
      distanceM: 6000,
      fetchedAt: now,
      legs: const [
        TransitLeg(
          lineName: '示例公交线',
          lineType: LineType.bus,
          direction: '公共地标方向',
          boardStop: '示例公交上车站',
          alightStop: '示例公交下车站',
          stopCount: 8,
        ),
      ],
    ),
    walking: RouteSummary(
      mode: RouteMode.walking,
      durationSec: 720,
      distanceM: 950,
      fetchedAt: now,
    ),
    metroMessage: '这是地铁方案提示。',
    transitMessage: '这是公交方案提示。',
    walkingMessage: '这是步行方案提示。',
  );
}

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
    final homeContext = tester.element(
      find.byKey(const ValueKey('family-entry')),
    );
    expect(Localizations.localeOf(homeContext), const Locale('zh', 'CN'));
    expect(MaterialLocalizations.of(homeContext).cancelButtonLabel, '取消');
    await tester.pumpWidget(StartupFailureApp(onRetry: () async {}));
    await tester.pumpAndSettle();
    final failureContext = tester.element(find.text('暂时无法打开常用地点'));
    expect(Localizations.localeOf(failureContext), const Locale('zh', 'CN'));
    expect(MaterialLocalizations.of(failureContext).backButtonTooltip, '返回');
  });

  testWidgets('地铁排第一且独立切换三种摘要，推荐和导航方式准确且不重查', (tester) async {
    _size(tester);
    final routes = _Routes()..handler = () async => _threeModes();
    final navigation = _Navigation();
    await tester.pumpWidget(
      SeniorNavApp(
        services: _services(routes: routes, navigation: navigation),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(_modeSemantics(tester, RouteMode.metro).selected, isTrue);
    expect(_modeSemantics(tester, RouteMode.metro).label, '坐地铁，推荐');
    expect(
      tester.getTopLeft(_modeFinder(RouteMode.metro)).dx,
      lessThan(tester.getTopLeft(_modeFinder(RouteMode.transit)).dx),
    );
    expect(find.textContaining('示例地铁线'), findsOneWidget);
    expect(find.text('这是地铁方案提示。'), findsOneWidget);
    for (final mode in [
      RouteMode.metro,
      RouteMode.transit,
      RouteMode.walking,
    ]) {
      await tester.ensureVisible(_modeFinder(mode));
      await tester.tap(_modeFinder(mode));
      await tester.pump();
      expect(_modeSemantics(tester, mode).selected, isTrue);
      if (mode == RouteMode.transit) {
        expect(find.textContaining('示例公交线'), findsOneWidget);
        expect(find.textContaining('示例地铁线'), findsNothing);
        expect(find.text('这是公交方案提示。'), findsOneWidget);
      } else if (mode == RouteMode.walking) {
        expect(find.textContaining('示例公交线'), findsNothing);
        expect(find.text('这是步行方案提示。'), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('open-map')));
      await tester.pumpAndSettle();
      expect(navigation.lastMode, mode);
    }
    expect(routes.calls, 1);
    expect(navigation.calls, 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('地铁空结果显示对应原因，仍可切到有方案的公交', (tester) async {
    _size(tester);
    final full = _threeModes();
    final routes = _Routes()
      ..handler = () async => RouteBundle(
        recommendedMode: RouteMode.transit,
        fetchedAt: full.fetchedAt,
        transit: full.transit,
        metroMessage: '附近暂时没有地铁方案。',
        walkingMessage: '暂时没有步行方案。',
      );
    await tester.pumpWidget(SeniorNavApp(services: _services(routes: routes)));
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(_modeSemantics(tester, RouteMode.transit).selected, isTrue);
    await tester.tap(_modeFinder(RouteMode.metro));
    await tester.pump();
    expect(find.text('暂时没有地铁方案'), findsOneWidget);
    expect(find.text('附近暂时没有地铁方案。'), findsOneWidget);
    await tester.tap(_modeFinder(RouteMode.walking));
    await tester.pump();
    expect(find.text('暂时没有步行方案'), findsOneWidget);
    expect(find.text('暂时没有步行方案。'), findsOneWidget);
    await tester.tap(_modeFinder(RouteMode.transit));
    await tester.pump();
    expect(find.textContaining('示例公交线'), findsOneWidget);
    expect(routes.calls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('加载期间手选公交不会被返回的地铁推荐覆盖', (tester) async {
    _size(tester);
    final pending = Completer<RouteBundle>();
    final routes = _Routes()..handler = () => pending.future;
    final navigation = _Navigation();
    await tester.pumpWidget(
      SeniorNavApp(
        services: _services(routes: routes, navigation: navigation),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    await tester.tap(_modeFinder(RouteMode.transit));
    await tester.pump();
    pending.complete(_threeModes());
    await tester.pumpAndSettle();
    expect(_modeSemantics(tester, RouteMode.transit).selected, isTrue);
    expect(_modeSemantics(tester, RouteMode.metro).selected, isFalse);
    expect(_modeSemantics(tester, RouteMode.metro).label, '坐地铁，推荐');
    expect(find.textContaining('示例公交线'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-map')));
    await tester.pumpAndSettle();
    expect(navigation.lastMode, RouteMode.transit);
    expect(routes.calls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('窄屏 $scale 倍字体方式标签保持完整，不拆成单字', (tester) async {
      _size(tester, scale: scale, size: const Size(320, 740));
      final routes = _Routes()..handler = () async => _threeModes();
      await tester.pumpWidget(
        SeniorNavApp(services: _services(routes: routes)),
      );
      await tester.tap(find.byKey(const ValueKey('home-slot-1')));
      await tester.pumpAndSettle();
      for (final label in ['坐地铁', '坐公交', '走路']) {
        await tester.ensureVisible(find.text(label));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: label.length),
        );
        expect(boxes, isNotEmpty);
        expect(boxes.map((box) => box.top).toSet(), hasLength(1));
        expect(
          boxes.last.right,
          lessThanOrEqualTo(paragraph.constraints.maxWidth + .1),
        );
      }
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('open-map')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('公交/地铁摘要用线路示意图替代文字步骤，步行仍用文字', (tester) async {
    _size(tester);
    final routes = _Routes()..handler = () async => _threeModes();
    await tester.pumpWidget(SeniorNavApp(services: _services(routes: routes)));
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(find.byType(RouteStrip), findsOneWidget);
    expect(find.text('示例上车站'), findsOneWidget);
    expect(find.text('示例下车站'), findsOneWidget);
    expect(find.textContaining('①'), findsNothing);
    await tester.tap(_modeFinder(RouteMode.walking));
    await tester.pump();
    expect(find.byType(RouteStrip), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('网页回退明确要求重新核对出行方式', (tester) async {
    _size(tester);
    final navigation = _Navigation()..outcome = NavigationOutcome.web;
    await tester.pumpWidget(
      SeniorNavApp(services: _services(navigation: navigation)),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    await tester.tap(_modeFinder(RouteMode.metro));
    await tester.tap(find.byKey(const ValueKey('open-map')));
    await tester.pumpAndSettle();
    expect(find.textContaining('网页未必保留当前选择，请重新核对起点和出行方式'), findsOneWidget);
    expect(navigation.lastMode, RouteMode.metro);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('查询失败展示上次路线，明确过期提示并带日期', (tester) async {
    _size(tester);
    final old = DateTime.now().subtract(const Duration(days: 1));
    final cache = _Cache();
    cache.store[_place.id] = RouteBundle(
      recommendedMode: RouteMode.transit,
      fetchedAt: old,
      transit: RouteSummary(
        mode: RouteMode.transit,
        durationSec: 1800,
        distanceM: 6000,
        fetchedAt: old,
        legs: const [
          TransitLeg(
            lineName: '示例公交线',
            lineType: LineType.bus,
            boardStop: '示例公交上车站',
            alightStop: '示例公交下车站',
            stopCount: 8,
          ),
        ],
      ),
    );
    final routes = _Routes();
    await tester.pumpWidget(
      SeniorNavApp(services: _services(routes: routes, cache: cache)),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    // 打开页面直接展示缓存，不发起查询，也没有失败原因。
    expect(routes.calls, 0);
    expect(find.text('这是上次查询的路线'), findsOneWidget);
    expect(find.textContaining('可能已过期'), findsOneWidget);
    expect(find.textContaining('点「重新查询」获取最新路线'), findsOneWidget);
    expect(find.textContaining('网络不好'), findsNothing);
    expect(find.text('上次查询位置'), findsOneWidget);
    expect(find.textContaining('${old.month}月${old.day}日'), findsWidgets);
    expect(find.textContaining('示例公交线'), findsOneWidget);
    expect(_modeSemantics(tester, RouteMode.transit).selected, isTrue);
    expect(find.text('路线已超过 5 分钟，请重新查询。'), findsNothing);
    expect(cache.saves, 0);
    // 重新查询失败后才展示失败原因，仍保留缓存路线。
    await tester.tap(find.byKey(const ValueKey('refresh-routes')));
    await tester.pumpAndSettle();
    expect(routes.calls, 1);
    expect(find.textContaining('网络不好，请打开百度地图。'), findsOneWidget);
    expect(find.textContaining('示例公交线'), findsOneWidget);
    expect(cache.saves, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('查询成功写入缓存，再次失败时展示缓存路线', (tester) async {
    _size(tester);
    final cache = _Cache();
    final routes = _Routes()..handler = () async => _threeModes();
    await tester.pumpWidget(
      SeniorNavApp(services: _services(routes: routes, cache: cache)),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(cache.saves, 1);
    expect(cache.store[_place.id], isNotNull);
    expect(find.text('这是上次查询的路线'), findsNothing);
    routes.handler = () async => throw const AppFailure('网络不好，请打开百度地图。');
    await tester.tap(find.byKey(const ValueKey('refresh-routes')));
    await tester.pumpAndSettle();
    expect(find.text('这是上次查询的路线'), findsOneWidget);
    expect(find.textContaining('示例地铁线'), findsOneWidget);
    expect(routes.calls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('缓存路线即使新鲜也不向导航传递起点', (tester) async {
    _size(tester);
    final now = DateTime.now();
    final cache = _Cache();
    cache.store[_place.id] = RouteBundle(
      recommendedMode: RouteMode.walking,
      fetchedAt: now,
      origin: const GeoPoint(31.8, 117.3),
      walking: RouteSummary(
        mode: RouteMode.walking,
        durationSec: 720,
        distanceM: 950,
        fetchedAt: now,
      ),
    );
    final routes = _Routes();
    final navigation = _Navigation();
    await tester.pumpWidget(
      SeniorNavApp(
        services: _services(routes: routes, navigation: navigation, cache: cache),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    // 5 分钟内的缓存按当前路线展示：不查询、无过期卡，但起点仍不传给导航。
    expect(routes.calls, 0);
    expect(find.text('这是上次查询的路线'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('open-map')));
    await tester.pumpAndSettle();
    expect(navigation.lastMode, RouteMode.walking);
    expect(navigation.lastOrigin, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('缓存展示时点重新查询，成功后按当前路线展示并覆盖缓存', (tester) async {
    _size(tester);
    final old = DateTime.now().subtract(const Duration(hours: 2));
    final cache = _Cache();
    cache.store[_place.id] = RouteBundle(
      recommendedMode: RouteMode.transit,
      fetchedAt: old,
      transit: RouteSummary(
        mode: RouteMode.transit,
        durationSec: 1800,
        distanceM: 6000,
        fetchedAt: old,
        legs: const [
          TransitLeg(lineName: '示例公交线', lineType: LineType.bus),
        ],
      ),
    );
    final routes = _Routes()..handler = () async => _threeModes();
    await tester.pumpWidget(
      SeniorNavApp(services: _services(routes: routes, cache: cache)),
    );
    await tester.tap(find.byKey(const ValueKey('home-slot-1')));
    await tester.pumpAndSettle();
    expect(routes.calls, 0);
    expect(find.text('这是上次查询的路线'), findsOneWidget);
    expect(find.text('上次查询位置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('refresh-routes')));
    await tester.pumpAndSettle();
    expect(routes.calls, 1);
    expect(cache.saves, 1);
    expect(find.text('这是上次查询的路线'), findsNothing);
    expect(find.textContaining('示例地铁线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
