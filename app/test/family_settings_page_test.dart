import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/features/places/family_settings_page.dart';
import 'package:seniornav/route_summary.dart';

class _Places extends PlaceRepository {
  String? pin;
  bool accepted = false;
  final List<SavedPlace> saved = [];
  @override
  List<SavedPlace> get places => List.unmodifiable(saved);
  @override
  bool get privacyAccepted => accepted;
  @override
  bool get hasPin => pin != null;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> acceptPrivacy() async {
    accepted = true;
    notifyListeners();
  }

  @override
  Future<void> setPin(String value) async {
    if (!RegExp(r'^\d{4,6}$').hasMatch(value)) {
      throw const AppFailure('请使用 4 至 6 位数字');
    }
    pin = value;
    notifyListeners();
  }

  @override
  Future<bool> verifyPin(String value) async => value == pin;
  @override
  Future<void> savePlace(SavedPlace place) async {
    saved.add(place);
    notifyListeners();
  }

  @override
  Future<void> deletePlace(String id) async {}
  @override
  Future<void> reorderMore(List<String> ids) async {}
}

const _candidate = PoiCandidate(
  uid: 'test-poi',
  name: '虚构测试公园',
  address: '虚构测试地址',
  city: '合肥',
  point: GeoPoint(31.86, 117.28),
  navigationPoint: GeoPoint(31.85, 117.27),
);

class _Poi implements PoiService {
  int searches = 0;
  int details = 0;
  Completer<List<PoiCandidate>>? pending;
  @override
  Future<List<PoiCandidate>> search({
    required String query,
    required String city,
  }) {
    searches++;
    return pending?.future ?? Future.value([_candidate]);
  }

  @override
  Future<PoiCandidate> detail(PoiCandidate candidate) async {
    details++;
    return candidate;
  }
}

class _Navigation implements NavigationService {
  int verifications = 0;
  NavigationOutcome outcome = NavigationOutcome.nativeApp;
  @override
  Future<NavigationOutcome> verifyPlace(PoiCandidate candidate) async {
    verifications++;
    return outcome;
  }

  @override
  Future<NavigationOutcome> open(
    SavedPlace place,
    RouteMode mode, {
    GeoPoint? origin,
  }) async => outcome;
}

class _Routes implements RouteService {
  @override
  bool get busy => false;
  @override
  Future<RouteBundle> load(SavedPlace destination) =>
      throw UnimplementedError();
}

class _Cache implements RouteCache {
  @override
  Future<void> save(String placeId, RouteBundle bundle) async {}
  @override
  Future<RouteBundle?> read(String placeId) async => null;
}

void main() {
  late _Places places;
  late _Poi poi;
  late _Navigation navigation;

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FamilySettingsPage(
          services: AppServices(
            places: places,
            poi: poi,
            routes: _Routes(),
            navigation: navigation,
            cache: _Cache(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> unlock(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, '2468');
    await tapVisible(tester, find.text('进入家属设置'));
  }

  setUp(() {
    places = _Places();
    poi = _Poi();
    navigation = _Navigation();
  });

  testWidgets(
    'first setup requires matching PIN then explicit consent before search',
    (tester) async {
      await show(tester);
      expect(find.text('先设置家属密码'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), '2468');
      await tester.enterText(find.byType(TextField).at(1), '1357');
      await tapVisible(tester, find.text('保存密码并继续'));
      expect(places.hasPin, isFalse);
      expect(find.text('两次输入不一致，请重新输入'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), '2468');
      await tapVisible(tester, find.text('保存密码并继续'));
      expect(find.text('使用前请家属确认'), findsOneWidget);
      expect(places.privacyAccepted, isFalse);
      expect(poi.searches, 0);
      await tapVisible(tester, find.text('已了解，同意使用'));
      expect(places.privacyAccepted, isTrue);
      expect(find.text('首页常用地点'), findsOneWidget);
    },
  );

  testWidgets('wrong PIN cannot enter management', (tester) async {
    places.pin = '2468';
    places.accepted = true;
    await show(tester);
    await tester.enterText(find.byType(TextField).first, '1357');
    await tapVisible(tester, find.text('进入家属设置'));
    expect(find.text('家属密码不正确，请重新输入'), findsOneWidget);
    expect(find.text('首页常用地点'), findsNothing);
    await unlock(tester);
    expect(find.text('首页常用地点'), findsOneWidget);
  });

  testWidgets(
    'typing does not query; save requires map open and explicit entrance confirmation',
    (tester) async {
      places.pin = '2468';
      places.accepted = true;
      await show(tester);
      await unlock(tester);
      await tapVisible(tester, find.text('设置地点').first);
      await tester.enterText(find.widgetWithText(TextField, '城市'), '合肥');
      await tester.enterText(find.widgetWithText(TextField, '地点名称'), '测试公园');
      await tester.pump(const Duration(seconds: 1));
      expect(poi.searches, 0);
      await tapVisible(tester, find.text('搜索地点'));
      expect(poi.searches, 1);
      await tapVisible(tester, find.text('虚构测试公园'));
      expect(poi.details, 1);
      await tester.scrollUntilVisible(
        find.text('保存地点'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存地点'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile))
            .onChanged,
        isNull,
      );
      navigation.outcome = NavigationOutcome.unavailable;
      await tapVisible(tester, find.text('打开地图核对入口'));
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile))
            .onChanged,
        isNull,
      );
      navigation.outcome = NavigationOutcome.nativeApp;
      await tapVisible(tester, find.text('打开地图核对入口'));
      expect(places.saved, isEmpty);
      await tapVisible(tester, find.text('我已核对地图，确认这是要去的入口'));
      await tapVisible(tester, find.text('保存地点'));
      expect(places.saved, hasLength(1));
      expect(places.saved.single.slot, 1);
      expect(places.saved.single.label, '回家');
      expect(places.saved.single.latitude, 31.85);
      expect(places.saved.single.longitude, 117.27);
      expect(places.saved.single.verifiedAt, isNotNull);
    },
  );

  testWidgets('pending POI search disables a second query', (tester) async {
    places.pin = '2468';
    places.accepted = true;
    poi.pending = Completer<List<PoiCandidate>>();
    await show(tester);
    await unlock(tester);
    await tapVisible(tester, find.text('设置地点').first);
    await tester.enterText(find.widgetWithText(TextField, '城市'), '合肥');
    await tester.enterText(find.widgetWithText(TextField, '地点名称'), '测试公园');
    await tapVisible(tester, find.text('搜索地点'));
    expect(poi.searches, 1);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请稍候…'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('请稍候…'));
    await tester.pump();
    expect(poi.searches, 1);
    poi.pending!.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('没有找到地点，请检查城市或换一个名称。'), findsOneWidget);
  });
}
