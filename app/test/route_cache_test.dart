import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/data/route_cache.dart';
import 'package:seniornav/route_summary.dart';

RouteBundle _bundle() {
  final at = DateTime(2026, 11, 13, 14, 52);
  return RouteBundle(
    recommendedMode: RouteMode.metro,
    fetchedAt: at,
    origin: const GeoPoint(31.804835, 117.297095),
    metro: RouteSummary(
      mode: RouteMode.metro,
      durationSec: 2700,
      distanceM: 12000,
      walkM: 900,
      fetchedAt: at,
      arriveTime: '2026-11-13 15:37:00',
      legs: const [
        TransitLeg(
          lineName: '轨道交通1号线',
          lineType: LineType.metro,
          direction: '张洼方向',
          boardStop: '合肥南站(C口)',
          alightStop: '合肥火车站',
          stopCount: 10,
          firstTime: '06:12',
          lastTime: '23:35',
          boardWalkM: 60,
        ),
        TransitLeg(
          lineName: '85路',
          lineType: LineType.bus,
          direction: '合肥火车站方向',
          boardStop: '大铺头站',
          alightStop: '长丰路桥站',
          stopCount: 8,
          boardWalkM: 500,
        ),
      ],
    ),
    transit: RouteSummary(
      mode: RouteMode.transit,
      durationSec: 3000,
      distanceM: 11000,
      walkM: 400,
      fetchedAt: at,
      legs: const [
        TransitLeg(lineName: '1路', lineType: LineType.bus, stopCount: 2),
      ],
    ),
    walking: RouteSummary(
      mode: RouteMode.walking,
      durationSec: 5400,
      distanceM: 4200,
      fetchedAt: at,
      crossingCount: 3,
    ),
    metroMessage: '暂时没有符合条件的地铁方案，请打开百度地图核对。',
    walkingMessage: '步行距离较远，出发前请让家人协助确认。',
  );
}

void main() {
  test('完整 bundle 编解码往返，字段不丢失', () {
    final decoded = decodeRouteBundle(encodeRouteBundle(_bundle()))!;
    final source = _bundle();
    expect(decoded.recommendedMode, source.recommendedMode);
    expect(decoded.fetchedAt, source.fetchedAt);
    expect(decoded.metroMessage, source.metroMessage);
    expect(decoded.transitMessage, isNull);
    expect(decoded.walkingMessage, source.walkingMessage);
    final metro = decoded.metro!;
    expect(metro.mode, RouteMode.metro);
    expect(metro.durationSec, 2700);
    expect(metro.distanceM, 12000);
    expect(metro.walkM, 900);
    expect(metro.arriveTime, '2026-11-13 15:37:00');
    expect(metro.fetchedAt, source.fetchedAt);
    expect(metro.legs, hasLength(2));
    final first = metro.legs.first;
    expect(first.lineName, '轨道交通1号线');
    expect(first.lineType, LineType.metro);
    expect(first.direction, '张洼方向');
    expect(first.boardStop, '合肥南站(C口)');
    expect(first.alightStop, '合肥火车站');
    expect(first.stopCount, 10);
    expect(first.firstTime, '06:12');
    expect(first.lastTime, '23:35');
    expect(first.boardWalkM, 60);
    final second = metro.legs[1];
    expect(second.lineType, LineType.bus);
    expect(second.firstTime, isNull);
    expect(second.lastTime, isNull);
    expect(decoded.transit!.legs.single.stopCount, 2);
    expect(decoded.walking!.crossingCount, 3);
    expect(decoded.walking!.legs, isEmpty);
  });

  test('缓存不保存起点坐标', () {
    final encoded = encodeRouteBundle(_bundle());
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    expect(json.containsKey('origin'), isFalse);
    expect(encoded.contains('31.804835'), isFalse);
    expect(encoded.contains('117.297095'), isFalse);
    expect(decodeRouteBundle(encoded)!.origin, isNull);
  });

  test('缺字段与空值按可空模型降级，不编造', () {
    final at = DateTime(2026, 11, 13);
    final sparse = RouteBundle(
      recommendedMode: RouteMode.walking,
      fetchedAt: at,
      walking: RouteSummary(
        mode: RouteMode.walking,
        durationSec: 600,
        distanceM: 800,
        fetchedAt: at,
      ),
    );
    final decoded = decodeRouteBundle(encodeRouteBundle(sparse))!;
    expect(decoded.metro, isNull);
    expect(decoded.transit, isNull);
    expect(decoded.metroMessage, isNull);
    final walking = decoded.walking!;
    expect(walking.walkM, 0);
    expect(walking.crossingCount, 0);
    expect(walking.arriveTime, isNull);
    expect(walking.legs, isEmpty);
  });

  test('畸形输入一律返回 null，不抛异常', () {
    final valid = jsonDecode(encodeRouteBundle(_bundle())) as Map<String, dynamic>;
    String mutate(void Function(Map<String, dynamic>) change) {
      final copy = jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
      change(copy);
      return jsonEncode(copy);
    }

    expect(decodeRouteBundle('not json'), isNull);
    expect(decodeRouteBundle('{}'), isNull);
    expect(decodeRouteBundle('[]'), isNull);
    expect(decodeRouteBundle(mutate((j) => j['v'] = 2)), isNull);
    expect(decodeRouteBundle(mutate((j) => j.remove('fetchedAt'))), isNull);
    expect(decodeRouteBundle(mutate((j) => j['fetchedAt'] = '昨天')), isNull);
    expect(
      decodeRouteBundle(mutate((j) => j['recommendedMode'] = 'driving')),
      isNull,
    );
    expect(
      decodeRouteBundle(mutate((j) => (j['metro'] as Map)['durationSec'] = '快')),
      isNull,
    );
    expect(
      decodeRouteBundle(
        mutate((j) => ((j['metro'] as Map)['legs'] as List).add('不是段')),
      ),
      isNull,
    );
    expect(
      decodeRouteBundle(
        mutate((j) => ((j['metro'] as Map)['legs'] as List).clear()),
      ),
      isNotNull,
    );
  });
}