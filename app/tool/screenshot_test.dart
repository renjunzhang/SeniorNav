// 宣传截图生成器：全部虚构数据，离线渲染，不发起任何百度请求。
// 用法（app/ 目录下）：flutter test tool/screenshot_test.dart --update-goldens
// 产物写入 docs/screenshots/，人工查看确认无真实地点后再入库。
// 需要本机存在 Noto Sans CJK SC 字体（见 _fontCandidates）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/features/home/home_page.dart';
import 'package:seniornav/route_summary.dart';

const _fontCandidates = [
  '.local/share/fonts/dsh/NotoSansCJKsc-Regular.otf',
  '.local/share/fonts/NotoSansCJKsc-Regular.otf',
];

SavedPlace _place(String id, int slot, String label, String icon, String name) =>
    SavedPlace(
      id: id,
      slot: slot,
      label: label,
      icon: icon,
      name: name,
      address: '示例地址',
      city: '合肥',
      latitude: 31.8,
      longitude: 117.3,
      updatedAt: DateTime(2026),
      verifiedAt: DateTime(2026),
    );

final _places = [
  _place('home', 1, '回家', 'home', '示例小区'),
  _place('family', 2, '去家人家', 'family', '示例家人家'),
  _place('hospital', 3, '医院', 'hospital', '示例人民医院'),
  _place('market', 4, '超市', 'shop', '示例超市'),
];

RouteBundle _bundle() {
  final now = DateTime.now();
  return RouteBundle(
    recommendedMode: RouteMode.transit,
    fetchedAt: now,
    transit: RouteSummary(
      mode: RouteMode.transit,
      durationSec: 1500,
      distanceM: 6200,
      walkM: 480,
      fetchedAt: now,
      legs: const [
        TransitLeg(
          lineName: '1路',
          lineType: LineType.bus,
          direction: '火车站方向',
          boardStop: '中山公园站',
          alightStop: '人民医院站',
          stopCount: 6,
          boardWalkM: 260,
        ),
      ],
    ),
    metro: RouteSummary(
      mode: RouteMode.metro,
      durationSec: 1860,
      distanceM: 7400,
      walkM: 900,
      fetchedAt: now,
      legs: const [
        TransitLeg(
          lineName: '地铁2号线',
          lineType: LineType.metro,
          direction: '火车站方向',
          boardStop: '中山公园站',
          alightStop: '人民医院站',
          stopCount: 4,
          boardWalkM: 450,
        ),
      ],
    ),
    walking: RouteSummary(
      mode: RouteMode.walking,
      durationSec: 720,
      distanceM: 950,
      fetchedAt: now,
    ),
  );
}

class _Places extends PlaceRepository {
  @override
  List<SavedPlace> get places => _places;
  @override
  bool get privacyAccepted => true;
  @override
  bool get hasPin => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> acceptPrivacy() async {}
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
  Future<List<PoiCandidate>> search({required String query, required String city}) async => [];
  @override
  Future<PoiCandidate> detail(PoiCandidate candidate) async => candidate;
}

class _Routes implements RouteService {
  @override
  bool busy = false;
  @override
  Future<RouteBundle> load(SavedPlace destination) async => _bundle();
}

class _Navigation implements NavigationService {
  @override
  Future<NavigationOutcome> open(SavedPlace place, RouteMode mode, {GeoPoint? origin}) async =>
      NavigationOutcome.nativeApp;
  @override
  Future<NavigationOutcome> verifyPlace(PoiCandidate candidate) async => NavigationOutcome.nativeApp;
}

class _Cache implements RouteCache {
  @override
  Future<void> save(String placeId, RouteBundle bundle) async {}
  @override
  Future<RouteBundle?> read(String placeId) async => null;
}

class _Trip implements TripStore {
  _Trip({this.trip});
  ActiveTrip? trip;
  @override
  Future<ActiveTrip?> readTrip() async => trip;
  @override
  Future<void> startTrip(String placeId, RouteBundle bundle, {DateTime? startedAt}) async {}
  @override
  Future<void> endTrip() async {}
}

AppServices _services({_Trip? trip}) => AppServices(
  places: _Places(),
  poi: _Poi(),
  routes: _Routes(),
  navigation: _Navigation(),
  cache: _Cache(),
  trip: trip ?? _Trip(),
);

// 镜像 seniornav_app.dart 的主题，仅给各 TextStyle 显式加 fontFamily: 'Roboto'。
// 测试引擎对 fontFamily 为 null 的样式（AppBar 标题、按钮主题）会用内置方框字体，
// 且无法通过 FontLoader 覆盖；显式指定后离线渲染才有真实字形。改动主题时需同步此处。
Widget _app(AppServices services) {
  const family = 'Roboto';
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1465D8),
    brightness: Brightness.light,
  );
  return MaterialApp(
    title: '回家',
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.light,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: family,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF5F8FD),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontFamily: family, fontSize: 22, height: 1.45),
        bodyMedium: TextStyle(fontFamily: family, fontSize: 20, height: 1.4),
        bodySmall: TextStyle(fontFamily: family, fontSize: 18, height: 1.35),
        titleLarge: TextStyle(fontFamily: family, fontSize: 26, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontFamily: family, fontSize: 22, fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF5F8FD),
        foregroundColor: Color(0xFF16335B),
        centerTitle: false,
        toolbarHeight: 80,
        titleTextStyle: TextStyle(
          fontFamily: family,
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: Color(0xFF16335B),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(72, 72),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          textStyle: const TextStyle(fontFamily: family, fontSize: 24, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(72, 72),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          textStyle: const TextStyle(fontFamily: family, fontSize: 22, fontWeight: FontWeight.w600),
          side: const BorderSide(color: Color(0xFF52749D), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(72, 72),
          textStyle: const TextStyle(fontFamily: family, fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(72, 72)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      ),
    ),
    home: HomePage(services: services),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _loadFonts() async {
  final home = Platform.environment['HOME'] ?? '';
  File? cjk;
  for (final candidate in _fontCandidates) {
    final file = File('$home/$candidate');
    if (file.existsSync()) {
      cjk = file;
      break;
    }
  }
  if (cjk == null) {
    throw StateError('未找到 Noto Sans CJK SC 字体，无法生成中文截图');
  }
  // 注册为 Roboto：_app 里所有样式都显式 fontFamily: 'Roboto'，落到真实字形。
  final bytes = cjk.readAsBytesSync().buffer.asByteData();
  await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
  final icons = File(
    '$home/development/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(icons.readAsBytesSync().buffer.asByteData()));
  await iconLoader.load();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('首页五入口', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_services()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/screenshots/home.png'),
    );
  });

  testWidgets('路线页公交示意图', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_services()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-slot-3')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/screenshots/route_bus.png'),
    );
  });

  testWidgets('路线页地铁示意图', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_services()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-slot-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('route-mode-metro')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/screenshots/route_metro.png'),
    );
  });

  testWidgets('首页行程横幅', (tester) async {
    _phone(tester);
    final trip = _Trip(
      trip: ActiveTrip(
        placeId: 'hospital',
        bundle: _bundle(),
        startedAt: DateTime(2026, 11, 14, 9, 5),
      ),
    );
    await tester.pumpWidget(_app(_services(trip: trip)));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/screenshots/home_trip.png'),
    );
  });
}