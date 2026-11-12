import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/baidu_route_parser.dart';
import 'package:seniornav/route_summary.dart';

/// fixture 的录制时刻，约凌晨 02:00。首末班校验的断言依赖它。
final DateTime recordedAt = DateTime(2026, 11, 12, 2, 0);

Map<String, dynamic> fixture(String name) => jsonDecode(
      File('test/fixtures/$name.json').readAsStringSync(),
    ) as Map<String, dynamic>;

List<RouteSummary> parsed(RouteParseResult result) => (result as RouteParsed).routes;

RouteSummary bestTransit(String name) =>
    selectRoute(parsed(parseTransit(fixture(name), fetchedAt: recordedAt)));

void main() {
  group('数字文案', () {
    test('米数取整到 10 米、公里取整到 0.1 公里', () {
      expect(formatDistance(62), '约 60 米');
      expect(formatDistance(755), '约 760 米');
      expect(formatDistance(95), '约 100 米');
      expect(formatDistance(10638), '约 10.6 公里');
    });

    test('时长用「约」，不写「实时」', () {
      expect(formatDuration(1733), '约 29 分钟');
      expect(formatDuration(5257), '约 1 小时 28 分钟');
      expect(formatDuration(3600), '约 1 小时');
      expect(formatDuration(81), '约 1 分钟');
      expect(formatDuration(1733), isNot(contains('实时')));
    });
  });

  group('公交摘要（§3.3 文案规则）', () {
    test('直达线路：不用换车，且行数在 6 行预算内', () {
      final text = renderSummary(bestTransit('metro_direct_transit'), now: recordedAt);

      expect(text.headline, '约 29 分钟（含步行）');
      expect(text.emphasis, '不用换车');
      expect(text.steps, [
        '① 步行约 60 米 → 合肥南站(C口)',
        '② 坐 轨道交通1号线（开往 张洼方向），10 站，合肥火车站下车',
        '③ 步行约 250 米到终点',
      ]);
      expect(text.lineCount, lessThanOrEqualTo(6));
    });

    test('1 次换乘：emphasis 写「要换 1 次车」，两段线路都出现', () {
      final routes = parsed(parseTransit(fixture('bus_transfer_transit'), fetchedAt: recordedAt));
      final text = renderSummary(routes[0], now: recordedAt);

      expect(text.emphasis, '要换 1 次车');
      expect(text.headline, '约 1 小时 28 分钟（含步行）');
      expect(text.steps, [
        '① 步行约 760 米 → 大铺头站',
        '② 坐 85路（开往 合肥火车站方向），8 站，长丰路桥站下车',
        '③ 换 320路（开往 省立医院方向），10 站，省立医院站下车',
        '④ 步行约 110 米到终点',
      ]);
      expect(text.lineCount, 6);
    });

    test('方向写的是 direct_text，不是下车站', () {
      // 安全相关：§4.4 原文让 direction 取「终点站名」，实测那是 end_info.end_name，
      // 等于下车站。这里锁住渲染结果，防止回退到错误字段（ADR 0002 A2）。
      final routes = parsed(parseTransit(fixture('bus_transfer_transit'), fetchedAt: recordedAt));
      final text = renderSummary(routes[0], now: recordedAt);

      expect(text.steps[1], contains('开往 合肥火车站方向'));
      expect(text.steps[1], isNot(contains('开往 长丰路桥站')));
    });

    test('2 次换乘时截断到 4 段，并把细节交给百度地图', () {
      final routes = parsed(parseTransit(fixture('bus_transfer_transit'), fetchedAt: recordedAt));
      final text = renderSummary(routes[2], now: recordedAt);

      expect(routes[2].legs, hasLength(3));
      expect(text.steps, hasLength(4));
      expect(text.steps.last, '④ 之后的换乘请打开百度地图查看');
      expect(text.lineCount, lessThanOrEqualTo(6));
    });

    test('凌晨查询要提示首班车还没发（百度不校验运营时间）', () {
      // 实测 02:00 查询照样返回首班 06:12 的地铁方案，客户端必须自己拦（ADR 0002 A7）。
      final text = renderSummary(bestTransit('metro_direct_transit'), now: recordedAt);
      expect(text.warnings, ['轨道交通1号线 首班 06:12，现在可能还没发车']);
    });

    test('白天查询不产生首末班告警', () {
      final noon = DateTime(2026, 11, 12, 12, 0);
      final text = renderSummary(bestTransit('metro_direct_transit'), now: noon);
      expect(text.warnings, isEmpty);
    });

    test('末班之后提示已收车', () {
      final late = DateTime(2026, 11, 12, 23, 50);
      final text = renderSummary(bestTransit('metro_direct_transit'), now: late);
      expect(text.warnings, ['轨道交通1号线 末班 23:35，现在可能已经收车']);
    });
  });

  group('缺失字段的降级文案（§4.4：不能编造）', () {
    SummaryText renderWith(TransitLeg leg) => renderSummary(
          RouteSummary(
            mode: RouteMode.transit,
            durationSec: 600,
            distanceM: 3000,
            legs: [leg],
            fetchedAt: recordedAt,
          ),
          now: recordedAt,
        );

    test('方向缺失时整段括号省略，不写「开往 未知」', () {
      final text = renderWith(const TransitLeg(lineName: '85路', stopCount: 8));
      expect(text.steps.single, '① 坐 85路，8 站');
      expect(text.steps.single, isNot(contains('开往')));
      expect(text.steps.single, isNot(contains('未知')));
    });

    test('线路名缺失时退化成「坐 公交」', () {
      expect(renderWith(const TransitLeg()).steps.single, '① 坐 公交');
    });

    test('站数缺失时不写「0 站」', () {
      final text = renderWith(const TransitLeg(lineName: '85路', direction: '火车站方向'));
      expect(text.steps.single, '① 坐 85路（开往 火车站方向）');
      expect(text.steps.single, isNot(matches(RegExp(r'\d+ 站'))));
    });

    test('没有乘车段时不编造线路，引导打开百度地图', () {
      final text = renderSummary(
        RouteSummary(
          mode: RouteMode.transit,
          durationSec: 600,
          distanceM: 3000,
          fetchedAt: recordedAt,
        ),
        now: recordedAt,
      );
      expect(text.steps, isEmpty);
      expect(text.emphasis, isNull);
      expect(text.warnings.single, contains('打开百度地图'));
    });
  });

  group('步行摘要', () {
    test('给出总时长、总距离与过街提示', () {
      final walk = parsed(parseWalking(fixture('metro_direct_walking'), fetchedAt: recordedAt)).single;
      final text = renderSummary(walk, now: recordedAt);

      expect(text.headline, '约 3 小时 10 分钟 · 约 12.5 公里');
      expect(text.emphasis, '途中需要过马路（1 处）');
      expect(text.warnings, ['距离较远，建议直接打开百度地图']);
    });

    test('过街词命中为 0 时不断言「不需要过马路」', () {
      // 百度没提到不等于没有路口，写「不需要」会让老人在真实路口放松警惕。
      final walk = parsed(parseWalking(fixture('walk_short_walking'), fetchedAt: recordedAt)).single;
      final text = renderSummary(walk, now: recordedAt);

      expect(walk.crossingCount, 0);
      expect(text.emphasis, isNull);
      expect(text.headline, '约 1 分钟 · 约 100 米');
      expect(text.warnings, isEmpty);
    });

    test('天桥计入过街提示', () {
      final walk = parsed(parseWalking(fixture('bus_transfer_walking'), fetchedAt: recordedAt)).single;
      expect(renderSummary(walk, now: recordedAt).emphasis, '途中需要过马路（2 处）');
    });
  });

  group('查询时间（§4.4）', () {
    test('超过 5 分钟判为过期', () {
      final summary = bestTransit('metro_direct_transit');
      expect(summary.isStaleAt(recordedAt.add(const Duration(minutes: 4))), isFalse);
      expect(summary.isStaleAt(recordedAt.add(const Duration(minutes: 6))), isTrue);
    });

    test('fetchedAt 用调用方给的时刻，不用 arrive_time', () {
      // arrive_time 是到达时间；拿它当查询时间会让过期判断永远不过期。
      final summary = bestTransit('metro_direct_transit');
      expect(summary.arriveTime, isNot(isNull));
      expect(summary.fetchedAt, recordedAt);
    });
  });
}
