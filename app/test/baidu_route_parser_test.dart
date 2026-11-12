import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/baidu_route_parser.dart';
import 'package:seniornav/route_summary.dart';

/// fixture 是 2026-11-12 凌晨用真实 AK 录制的百度响应，坐标已降到 6 位小数。
/// 录制时刻约 02:00，首末班校验的测试依赖这个时间点。
final DateTime recordedAt = DateTime(2026, 11, 12, 2, 0);

Map<String, dynamic> fixture(String name) => jsonDecode(
      File('test/fixtures/$name.json').readAsStringSync(),
    ) as Map<String, dynamic>;

List<RouteSummary> parsed(RouteParseResult result) =>
    (result as RouteParsed).routes;

void main() {
  group('公交响应结构（§4.3 的实测修正）', () {
    test('steps 是列表的列表，解析不抛类型错误', () {
      // 方案 §4.3 把 routes[].steps 写成对象数组，直接取字段会失败。
      final raw = fixture('metro_direct_transit')['result']['routes'][0]['steps'];
      expect(raw, isA<List>());
      expect(raw[0], isA<List>(), reason: '外层元素应仍是数组');

      final routes = parsed(parseTransit(fixture('metro_direct_transit'), fetchedAt: recordedAt));
      expect(routes, hasLength(5));
    });

    test('线路字段在 vehicle_info.detail 里，不在 vehicle_info 这一层', () {
      final routes = parsed(parseTransit(fixture('metro_direct_transit'), fetchedAt: recordedAt));
      final leg = routes[0].legs.single;

      expect(leg.lineName, '轨道交通1号线');
      expect(leg.lineType, LineType.metro);
      expect(leg.boardStop, '合肥南站(C口)');
      expect(leg.alightStop, '合肥火车站');
      expect(leg.stopCount, 10);
      expect(leg.firstTime, '06:12');
      expect(leg.lastTime, '23:35');
    });

    test('direction 取 direct_text，不取 end_info.end_name', () {
      // 安全相关回归测试：end_name 是下车站。85 路开往合肥火车站，
      // 下车站是长丰路桥站，用错字段就会给老人指错行车方向（ADR 0002 A2）。
      final routes = parsed(parseTransit(fixture('bus_transfer_transit'), fetchedAt: recordedAt));
      final leg = routes[0].legs.first;

      expect(leg.direction, '合肥火车站方向');
      expect(leg.alightStop, '长丰路桥站');
      expect(leg.direction, isNot(leg.alightStop));
    });

    test('步行段统计 trans_type 0 与 4，同站换乘标记不计入', () {
      final routes = parsed(parseTransit(fixture('bus_transfer_transit'), fetchedAt: recordedAt));
      // r0 = 755 + 107，其中 trans_type == 3 的换乘标记距离是 1 米。
      expect(routes[0].walkM, 862);
      expect(routes[0].legs, hasLength(2));
      expect(routes[0].transfers, 1);
    });

    test('换乘步行段 trans_type == 4 计入 walkM 与下一段 boardWalkM', () {
      // 回归：旧实现只认 trans_type == 0，把 228/338 米的换乘步行整段丢掉，
      // 摘要里「步行到上车站」那一行随之消失。fixture 里该段 instructions
      // 就是「步行228米」，确属步行而非标记。
      final routes = parsed(parseTransit(fixture('metro_direct_transit'), fetchedAt: recordedAt));

      expect(routes[3].walkM, 2213 + 228 + 82);
      expect(routes[3].legs[1].boardWalkM, 228);
      expect(routes[4].walkM, 2213 + 338 + 386);
      expect(routes[4].legs[1].boardWalkM, 338);
    });

    test('同组多条车辆段是备选线路，只算一段乘车', () {
      // 回归：metro_direct 第 5 条方案的一组里有 4路/T38路/T37路/T12路 四条
      // 备选线路，距离之和 19081 米 > 整条 route.distance 14114 米，证明是
      // 「同段任选」而非连续乘车。旧实现建 4 个 leg，把 1 次换乘算成 3 次。
      final routes = parsed(parseTransit(fixture('metro_direct_transit'), fetchedAt: recordedAt));
      final r = routes[4];

      expect(r.legs, hasLength(2));
      expect(r.transfers, 1);
      expect(r.legs[0].lineName, '4路');
      expect(r.legs[1].lineName, '省二院健康专线');
    });

    test('换乘线路的每一段都保留各自的站数与首末班', () {
      final routes = parsed(parseTransit(fixture('bus_transfer_transit'), fetchedAt: recordedAt));
      final legs = routes[0].legs;

      expect(legs[0].lineName, '85路');
      expect(legs[0].lineType, LineType.bus);
      expect(legs[0].stopCount, 8);
      expect(legs[0].lastTime, '22:00');
      expect(legs[1].lineName, '320路');
      expect(legs[1].direction, '省立医院方向');
      expect(legs[1].stopCount, 10);
      expect(legs[1].lastTime, '19:00');
      // 第二段的上车前步行是同站换乘，距离为 0。
      expect(legs[1].boardWalkM, 0);
    });

    test('status == 0 但 routes 为空是「没有公交方案」，不是失败', () {
      // 95 米的起终点会返回这种形状。当成失败会让老人看到「暂时查不到路线」，
      // 而正确答案是「走路」（ADR 0002 A6）。
      final result = parseTransit(fixture('walk_short_transit'), fetchedAt: recordedAt);
      expect(result, isA<RouteEmpty>());
    });
  });

  group('步行响应结构', () {
    test('steps 是扁平对象数组，与公交的嵌套形状不同', () {
      final raw = fixture('metro_direct_walking')['result']['routes'][0]['steps'];
      expect(raw[0], isA<Map>());

      final routes = parsed(parseWalking(fixture('metro_direct_walking'), fetchedAt: recordedAt));
      final walk = routes.single;
      expect(walk.mode, RouteMode.walking);
      expect(walk.distanceM, 12510);
      expect(walk.durationSec, 11395);
      expect(walk.legs, isEmpty);
    });

    test('过街词命中数来自 instructions，且先剥掉 <b> 标签', () {
      expect(
        parsed(parseWalking(fixture('metro_direct_walking'), fetchedAt: recordedAt)).single.crossingCount,
        1,
        reason: '19 步中只有「过马路右转」一处',
      );
      expect(
        parsed(parseWalking(fixture('bus_transfer_walking'), fetchedAt: recordedAt)).single.crossingCount,
        2,
        reason: '上天桥 / 下天桥 两处',
      );
      expect(
        parsed(parseWalking(fixture('walk_short_walking'), fetchedAt: recordedAt)).single.crossingCount,
        0,
      );
    });

    test('短距离步行方案完整解析', () {
      final walk = parsed(parseWalking(fixture('walk_short_walking'), fetchedAt: recordedAt)).single;
      expect(walk.distanceM, 95);
      expect(walk.durationSec, 81);
    });
  });

  group('失败与畸形响应', () {
    test('status != 0 时带回状态码与消息', () {
      final result = parseTransit(
        {'status': 210, 'message': 'AK 不存在或者验证未通过'},
        fetchedAt: recordedAt,
      );
      expect(result, isA<RouteRejected>());
      expect((result as RouteRejected).status, 210);
      expect(result.message, contains('AK'));
    });

    test('缺少 status 字段时判为畸形而不是崩溃', () {
      expect(parseTransit({'result': {}}, fetchedAt: recordedAt), isA<RouteMalformed>());
    });

    test('百度改了结构时判为畸形，让 UI 走 §3.7 的回退', () {
      expect(
        parseTransit({
          'status': 0,
          'result': {
            'routes': [
              {'duration': 100, 'distance': 200, 'steps': 'not-a-list'}
            ]
          }
        }, fetchedAt: recordedAt),
        isA<RouteMalformed>(),
      );
      expect(
        parseTransit({
          'status': 0,
          'result': {
            'routes': [
              {'distance': 200, 'steps': <Object?>[]}
            ]
          }
        }, fetchedAt: recordedAt),
        isA<RouteMalformed>(),
        reason: 'duration 缺失必须被发现，不能默认成 0',
      );
    });

    test('线路字段缺失时留空，不用占位串编造', () {
      final routes = parsed(parseTransit({
        'status': 0,
        'result': {
          'routes': [
            {
              'duration': 600,
              'distance': 3000,
              'steps': [
                [
                  {
                    'trans_type': -1,
                    'distance': 3000,
                    'duration': 600,
                    'vehicle_info': {'type': 3, 'detail': {'type': 0}}
                  }
                ]
              ]
            }
          ]
        }
      }, fetchedAt: recordedAt));

      final leg = routes.single.legs.single;
      expect(leg.lineName, isNull);
      expect(leg.direction, isNull);
      expect(leg.stopCount, isNull);
      expect(leg.lineType, LineType.bus);
    });
  });

  group('选路规则（§4.4）', () {
    test('先比换乘、再比步行、最后比时长', () {
      final routes = parsed(parseTransit(fixture('bus_transfer_transit'), fetchedAt: recordedAt));
      final best = selectRoute(routes);

      // 百度按 tactics_incity=2（少步行）把 87.6 分钟/1 换乘的方案排在第 1 位，
      // 0 换乘的轨道交通 2 号线排在第 5 位。按 §4.4 重排才能选对（ADR 0002 §2.7）。
      expect(best.durationSec, 2395);
      expect(best.transfers, 0);
      expect(best.walkM, 1302);
      expect(best.legs.single.lineName, '轨道交通2号线');
    });

    test('地铁直达场景选中的就是百度排第一的方案', () {
      final routes = parsed(parseTransit(fixture('metro_direct_transit'), fetchedAt: recordedAt));
      final best = selectRoute(routes);

      expect(best.durationSec, 1733);
      expect(best.transfers, 0);
      expect(best.walkM, 315);
    });

    test('没有路线时抛错，由调用方先判空', () {
      expect(() => selectRoute(const []), throwsStateError);
    });

    // 绕路保护：少换乘不能以明显绕路为代价。阈值为 M0 暂定（慢 10 分钟 / 远 1 倍）。
    RouteSummary plan({
      required int seconds,
      required int meters,
      int transfers = 0,
    }) =>
        RouteSummary(
          mode: RouteMode.transit,
          durationSec: seconds,
          distanceM: meters,
          fetchedAt: recordedAt,
          legs: List.generate(transfers + 1, (_) => const TransitLeg()),
        );

    test('0 换乘但比最快方案慢 11 分钟 → 选更快的 1 换乘', () {
      final best = selectRoute([
        plan(seconds: 40 * 60, meters: 10000, transfers: 0),
        plan(seconds: 29 * 60, meters: 10000, transfers: 1),
      ]);
      expect(best.transfers, 1);
      expect(best.durationSec, 29 * 60);
    });

    test('0 换乘只慢 9 分钟 → 仍选少换乘', () {
      final best = selectRoute([
        plan(seconds: 38 * 60, meters: 10000, transfers: 0),
        plan(seconds: 29 * 60, meters: 10000, transfers: 1),
      ]);
      expect(best.transfers, 0);
    });

    test('正好慢 10 分钟在容忍边界内 → 仍选少换乘', () {
      final best = selectRoute([
        plan(seconds: 39 * 60, meters: 10000, transfers: 0),
        plan(seconds: 29 * 60, meters: 10000, transfers: 1),
      ]);
      expect(best.transfers, 0);
    });

    test('时长相同但距离 2.5 倍 → 选不绕路的 1 换乘', () {
      final best = selectRoute([
        plan(seconds: 30 * 60, meters: 25000, transfers: 0),
        plan(seconds: 30 * 60, meters: 10000, transfers: 1),
      ]);
      expect(best.transfers, 1);
      expect(best.distanceM, 10000);
    });

    test('两个过滤条件互斥时退回时长过滤，不抛异常', () {
      // 最快方案绕远、最短方案超时：交集为空，必须仍有结果。
      final best = selectRoute([
        plan(seconds: 30 * 60, meters: 30000, transfers: 0),
        plan(seconds: 50 * 60, meters: 10000, transfers: 1),
      ]);
      expect(best.durationSec, 30 * 60);
    });
  });

  group('自动推荐（§3.4）', () {
    RouteSummary walk({required int meters, required int seconds}) => RouteSummary(
          mode: RouteMode.walking,
          distanceM: meters,
          durationSec: seconds,
          fetchedAt: recordedAt,
        );
    RouteSummary transit({required int seconds, int walkMeters = 500}) => RouteSummary(
          mode: RouteMode.transit,
          durationSec: seconds,
          distanceM: 5000,
          walkM: walkMeters,
          legs: const [TransitLeg(lineName: '1路')],
          fetchedAt: recordedAt,
        );

    test('95 米且无公交方案 → 走路', () {
      // walk_short fixture 的真实形状：公交 RouteEmpty，步行 95 米。
      final walking = parsed(parseWalking(fixture('walk_short_walking'), fetchedAt: recordedAt)).single;
      expect(recommendMode(transit: null, walking: walking), ModeAdvice.walk);
    });

    test('步行 1 公里内且 20 分钟内 → 走路，即使公交更快', () {
      expect(
        recommendMode(transit: transit(seconds: 300), walking: walk(meters: 900, seconds: 660)),
        ModeAdvice.walk,
      );
    });

    test('公交比步行快 5 分钟以上 → 坐公交', () {
      expect(
        recommendMode(transit: transit(seconds: 1733), walking: walk(meters: 12510, seconds: 11395)),
        ModeAdvice.transit,
      );
    });

    test('公交正好快 5 分钟时仍推荐走路，把判断交给第 3 条规则', () {
      expect(
        recommendMode(transit: transit(seconds: 1200), walking: walk(meters: 1800, seconds: 1500)),
        ModeAdvice.walk,
      );
    });

    test('公交快 5 分钟以上才推荐公交', () {
      expect(
        recommendMode(transit: transit(seconds: 1200), walking: walk(meters: 1800, seconds: 1501)),
        ModeAdvice.transit,
      );
    });

    test('步行 2 公里内且不比公交慢 10 分钟以上 → 走路', () {
      expect(
        recommendMode(transit: transit(seconds: 1500), walking: walk(meters: 1800, seconds: 1700)),
        ModeAdvice.walk,
      );
    });

    test('步行超过 2 公里且公交没快 5 分钟 → 坐公交', () {
      expect(
        recommendMode(transit: transit(seconds: 1500), walking: walk(meters: 2500, seconds: 1700)),
        ModeAdvice.transit,
      );
    });

    test('无公交且步行超过 3 公里 → 距离较远提示', () {
      expect(
        recommendMode(transit: null, walking: walk(meters: 3500, seconds: 2800)),
        ModeAdvice.walkFarWarning,
      );
    });

    test('用真实 fixture 的地铁直达与步行方案比较', () {
      final t = selectRoute(parsed(parseTransit(fixture('metro_direct_transit'), fetchedAt: recordedAt)));
      final w = parsed(parseWalking(fixture('metro_direct_walking'), fetchedAt: recordedAt)).single;
      expect(recommendMode(transit: t, walking: w), ModeAdvice.transit);
    });
  });
}
