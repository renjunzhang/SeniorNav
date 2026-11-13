import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
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

String ridePayload(List<List<int>> routes) => jsonEncode({
  'status': 0,
  'result': {
    'routes': [
      for (var i = 0; i < routes.length; i++)
        {
          'duration': 600 + i * 60,
          'distance': 3000,
          'steps': [
            for (final type in routes[i])
              [
                {
                  'trans_type': 1,
                  'vehicle_info': {
                    'detail': {'name': '公共测试线路', 'type': type},
                  },
                },
              ],
          ],
        },
    ],
  },
});

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
      expect(calls, ['initialize', 'transit', 'transit', 'walking']);
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
          final fixture = method == 'transit' && args?['policy'] == 3
              ? 'bus_transfer_transit'
              : 'metro_direct_$method';
          return File('test/fixtures/$fixture.json').readAsStringSync();
        },
      );
      final bundle = await SdkRouteService(
        client,
        location: () async => const GeoPoint(31.8, 117.3),
      ).load(samplePlace());
      expect(calls, ['initialize', 'transit', 'transit', 'walking']);
      expect(bundle.metro!.legs.first.direction, isNotEmpty);
      expect(
        bundle.metro!.legs.every((leg) => leg.lineType == LineType.metro),
        isTrue,
      );
      expect(
        bundle.transit!.legs.every((leg) => leg.lineType == LineType.bus),
        isTrue,
      );
      expect(bundle.walking, isNotNull);
    },
  );

  test(
    'bus query timeout preserves metro and does not start walking',
    () async {
      final calls = <String>[];
      final client = BaiduClient(
        privacyAccepted: () => true,
        invoke: (method, args) async {
          calls.add(method);
          if (method == 'initialize') return null;
          if (args?['policy'] == 3) {
            throw PlatformException(code: 'SESSION_BLOCKED');
          }
          return ridePayload([
            [1],
          ]);
        },
      );
      final service = SdkRouteService(
        client,
        location: () async => const GeoPoint(31.8, 117.3),
      );
      final bundle = await service.load(samplePlace());
      expect(bundle.metro, isNotNull);
      expect(bundle.transit, isNull);
      expect(bundle.walking, isNull);
      expect(bundle.metroMessage, contains('保留'));
      expect(client.busy, isTrue);
      await expectLater(
        service.load(samplePlace()),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, ['initialize', 'transit', 'transit']);
    },
  );

  test(
    'walking timeout preserves both completed ride modes without retry',
    () async {
      final calls = <String>[];
      final client = BaiduClient(
        privacyAccepted: () => true,
        invoke: (method, args) async {
          calls.add(method);
          if (method == 'initialize') return null;
          if (method == 'walking') {
            throw PlatformException(code: 'SESSION_BLOCKED');
          }
          return ridePayload([
            [args?['policy'] == 5 ? 1 : 0],
          ]);
        },
      );
      final bundle = await SdkRouteService(
        client,
        location: () async => const GeoPoint(31.8, 117.3),
      ).load(samplePlace());
      expect(bundle.metro, isNotNull);
      expect(bundle.transit, isNotNull);
      expect(bundle.walking, isNull);
      expect(client.busy, isTrue);
      expect(calls, ['initialize', 'transit', 'transit', 'walking']);
    },
  );

  test('three policies run serially with at most one native request', () async {
    final calls = <String>[];
    var active = 0;
    var maximum = 0;
    final client = BaiduClient(
      privacyAccepted: () => true,
      invoke: (method, args) async {
        if (method == 'initialize') return null;
        calls.add('$method:${args?['policy']}');
        active++;
        if (active > maximum) maximum = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        if (method == 'walking') {
          return File('test/fixtures/metro_direct_walking.json')
              .readAsStringSync();
        }
        // Both policies can return alternatives: classify actual legs, not the policy name.
        return ridePayload([
          [0],
          [1],
          [1, 0],
          [0, 9],
          [],
        ]);
      },
    );
    final bundle = await SdkRouteService(
      client,
      location: () async => const GeoPoint(31.8, 117.3),
    ).load(samplePlace());
    expect(calls, ['transit:5', 'transit:3', 'walking:null']);
    expect(maximum, 1);
    expect(bundle.metro!.mode, RouteMode.metro);
    expect(bundle.metro!.legs.single.lineType, LineType.metro);
    expect(bundle.transit!.legs.single.lineType, LineType.bus);
    expect(bundle.walking, isNotNull);
  });

  test('metro keeps only all-metro routes and unknown rides never become bus', () async {
    final client = BaiduClient(
      privacyAccepted: () => true,
      invoke: (method, args) async {
        if (method == 'initialize') return null;
        if (method == 'walking') return '{"status":0,"result":{"routes":[]}}';
        return args?['policy'] == 5
            ? ridePayload([
                [1, 0],
                [1, 1],
              ])
            : ridePayload([
                [1],
                [0, 9],
                [9],
              ]);
      },
    );
    final bundle = await SdkRouteService(
      client,
      location: () async => const GeoPoint(31.8, 117.3),
    ).load(samplePlace());
    expect(bundle.metro, isNotNull);
    expect(bundle.metro!.legs, hasLength(2));
    expect(
      bundle.metro!.legs.every((leg) => leg.lineType == LineType.metro),
      isTrue,
    );
    expect(bundle.metroMessage, isNull);
    expect(bundle.transit, isNull);
    expect(bundle.transitMessage, contains('符合条件'));
    expect(bundle.recommendedMode, RouteMode.metro);
  });

  test('metro with only feeder routes shows no metro option', () async {
    final client = BaiduClient(
      privacyAccepted: () => true,
      invoke: (method, args) async {
        if (method == 'initialize') return null;
        if (method == 'walking') return '{"status":0,"result":{"routes":[]}}';
        return args?['policy'] == 5
            ? ridePayload([
                [1, 0],
              ])
            : ridePayload([
                [0],
              ]);
      },
    );
    final bundle = await SdkRouteService(
      client,
      location: () async => const GeoPoint(31.8, 117.3),
    ).load(samplePlace());
    expect(bundle.metro, isNull);
    expect(bundle.metroMessage, contains('符合条件'));
    expect(bundle.transit, isNotNull);
    expect(bundle.recommendedMode, RouteMode.transit);
  });

  test('native metro and bus navigation use separate URI policies', () async {
    final opened = <Uri>[];
    final navigation = BaiduNavigationService(
      installed: () async => true,
      opener: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    await navigation.open(samplePlace(), RouteMode.metro);
    await navigation.open(samplePlace(), RouteMode.transit);
    expect(opened.map((uri) => uri.queryParameters['sy']), ['6', '4']);
    expect(
      opened.every((uri) => uri.queryParameters['mode'] == 'transit'),
      isTrue,
    );
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
