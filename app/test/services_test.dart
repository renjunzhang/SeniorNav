import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/baidu_route_parser.dart';
import 'package:seniornav/data/baidu_client.dart';
import 'package:seniornav/data/navigation_service.dart';
import 'package:seniornav/data/route_service.dart';
import 'package:seniornav/route_summary.dart';

SavedPlace samplePlace() => SavedPlace(
  id: 'public',
  slot: 1,
  label: '公共测试点',
  icon: 'home',
  name: '公共测试点',
  address: '公共测试点',
  city: '合肥',
  latitude: 31.89,
  longitude: 117.32,
  updatedAt: DateTime(2026),
  verifiedAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'privacy refusal causes no SDK initialization, location or requests',
    () async {
      var nativeCalls = 0;
      var locationCalls = 0;
      final client = BaiduClient(
        privacyAccepted: () => false,
        invoke: (_, _) async {
          nativeCalls++;
          return null;
        },
      );
      final routes = SdkRouteService(
        client,
        location: () async {
          locationCalls++;
          return const GeoPoint(31.8, 117.3);
        },
      );
      await expectLater(routes.load(samplePlace()), throwsA(isA<AppFailure>()));
      expect(nativeCalls, 0);
      expect(locationCalls, 0);
    },
  );

  test(
    'one lock covers route, POI and slow/abandoned callers until callback',
    () async {
      final firstCallback = Completer<Object?>();
      final calls = <String>[];
      final client = BaiduClient(
        privacyAccepted: () => true,
        invoke: (method, args) async {
          calls.add(method);
          if (method == 'transit') return firstCallback.future;
          if (method == 'walking') {
            return File('test/fixtures/walk_short_walking.json')
                .readAsStringSync();
          }
          return null;
        },
      );
      final routes = SdkRouteService(
        client,
        location: () async => const GeoPoint(31.8, 117.3),
      );
      final result = routes.load(samplePlace());
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['initialize', 'transit']);
      expect(routes.busy, isTrue);
      await expectLater(
        SdkPoiService(client).search(query: '公共地标', city: '合肥'),
        throwsA(isA<AppFailure>()),
      );
      await expectLater(routes.load(samplePlace()), throwsA(isA<AppFailure>()));
      expect(calls, ['initialize', 'transit']);
      firstCallback.complete('{"status":0,"result":{"routes":[]}}');
      final bundle = await result;
      expect(calls, ['initialize', 'transit', 'walking']);
      expect(routes.busy, isFalse);
      expect(bundle.transit, isNull);
      expect(bundle.walking, isNotNull);
      expect(bundle.recommendedMode, RouteMode.walking);
    },
  );

  test('uncertain native timeout permanently blocks this client, never retries walking', () async {
    final calls = <String>[];
    final client = BaiduClient(
      privacyAccepted: () => true,
      invoke: (method, args) async {
        calls.add(method);
        if (method == 'transit') {
          throw PlatformException(
            code: 'SESSION_BLOCKED',
            message: 'must not surface',
          );
        }
        return null;
      },
    );
    final routes = SdkRouteService(
      client,
      location: () async => const GeoPoint(31.8, 117.3),
    );
    await expectLater(routes.load(samplePlace()), throwsA(isA<AppFailure>()));
    expect(routes.busy, isTrue);
    await expectLater(routes.load(samplePlace()), throwsA(isA<AppFailure>()));
    expect(calls, ['initialize', 'transit']);
  });

  test(
    'both real fixtures are consumed sequentially without fake route fallback',
    () async {
      final calls = <String>[];
      final client = BaiduClient(
        privacyAccepted: () => true,
        invoke: (method, args) async {
          calls.add(method);
          if (method == 'initialize') return null;
          return File('test/fixtures/metro_direct_$method.json')
              .readAsStringSync();
        },
      );
      final bundle = await SdkRouteService(
        client,
        location: () async => const GeoPoint(31.8, 117.3),
      ).load(samplePlace());
      expect(calls, ['initialize', 'transit', 'walking']);
      expect(bundle.transit!.legs.first.direction, isNotEmpty);
      expect(bundle.walking, isNotNull);
    },
  );

  test('alternate-policy timeout preserves both completed routes and keeps the lock', () async {
    final fixture = jsonDecode(
      File('test/fixtures/metro_direct_transit.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final options = fixture['result']['routes'] as List;
    final oneTransfer = options.firstWhere((route) {
      final parsed = parseTransit({
        'status': 0,
        'result': {
          'routes': [route],
        },
      }, fetchedAt: DateTime(2026)) as RouteParsed;
      return parsed.routes.single.transfers >= 1;
    });
    final calls = <String>[];
    var transitCalls = 0;
    final client = BaiduClient(
      privacyAccepted: () => true,
      invoke: (method, args) async {
        calls.add(method);
        if (method == 'initialize') return null;
        if (method == 'walking') {
          return File('test/fixtures/metro_direct_walking.json')
              .readAsStringSync();
        }
        if (++transitCalls == 2) {
          throw PlatformException(code: 'SESSION_BLOCKED');
        }
        return jsonEncode({
          'status': 0,
          'result': {
            'routes': [oneTransfer],
          },
        });
      },
    );
    final service = SdkRouteService(
      client,
      location: () async => const GeoPoint(31.8, 117.3),
    );
    final bundle = await service.load(samplePlace());
    expect(bundle.transit, isNotNull);
    expect(bundle.walking, isNotNull);
    expect(bundle.transitMessage, contains('保留'));
    expect(client.busy, isTrue);
    await expectLater(service.load(samplePlace()), throwsA(isA<AppFailure>()));
    expect(calls, ['initialize', 'transit', 'walking', 'transit']);
  });

  test('walking timeout keeps an already successful transit route without further calls', () async {
    final calls = <String>[];
    final client = BaiduClient(
      privacyAccepted: () => true,
      invoke: (method, args) async {
        calls.add(method);
        if (method == 'initialize') return null;
        if (method == 'walking') {
          throw PlatformException(code: 'SESSION_BLOCKED');
        }
        return File('test/fixtures/metro_direct_transit.json')
            .readAsStringSync();
      },
    );
    final bundle = await SdkRouteService(
      client,
      location: () async => const GeoPoint(31.8, 117.3),
    ).load(samplePlace());
    expect(bundle.transit, isNotNull);
    expect(bundle.walking, isNull);
    expect(client.busy, isTrue);
    expect(calls, ['initialize', 'transit', 'walking']);
  });

  test('native transit navigation uses current location instead of an old summary origin', () async {
    final opened = <Uri>[];
    final navigation = BaiduNavigationService(
      installed: () async => true,
      opener: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    await navigation.open(
      samplePlace(),
      RouteMode.transit,
      origin: const GeoPoint(31.8, 117.3),
    );
    expect(opened.single.queryParameters['origin'], '我的位置');
  });

  test(
    'web fallback uses measured origin and preserves walking mode',
    () async {
      final opened = <Uri>[];
      final nav = BaiduNavigationService(
        installed: () async => false,
        opener: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      expect(
        await nav.open(
          samplePlace(),
          RouteMode.walking,
          origin: const GeoPoint(31.8, 117.3),
        ),
        NavigationOutcome.web,
      );
      expect(opened.single.host, 'api.map.baidu.com');
      expect(opened.single.queryParameters['origin'], '31.8,117.3');
      expect(opened.single.queryParameters['mode'], 'walking');
      expect(opened.single.queryParameters['coord_type'], 'bd09ll');
    },
  );

  test(
    'walknavi failure falls through to native direction then browser once each',
    () async {
      final opened = <Uri>[];
      final nav = BaiduNavigationService(
        installed: () async => true,
        version: () async => '21.15.0',
        opener: (uri) async {
          opened.add(uri);
          return uri.scheme == 'https';
        },
      );
      expect(
        await nav.open(samplePlace(), RouteMode.walking),
        NavigationOutcome.web,
      );
      expect(opened.map((u) => u.path), [
        '/walknavi',
        '/direction',
        '/direction',
      ]);
    },
  );

  test('old walking client is not sent an unsupported walknavi URI', () async {
    final opened = <Uri>[];
    final nav = BaiduNavigationService(
      installed: () async => true,
      version: () async => '8.6.9',
      opener: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    expect(
      await nav.open(samplePlace(), RouteMode.walking),
      NavigationOutcome.web,
    );
    expect(opened.single.scheme, 'https');
  });
}
