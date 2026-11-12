/// 消费 tools/sdk-probe 真机产出的 JSON dump，复用现有解析器判定字段完整性。
///
/// 探针把 SDK getter 序列化成 Web API 形状，因此这里直接调 parseTransit /
/// parseWalking，不另写一套映射——SDK 字段够不够，用 V1 真正会用的那条代码路径判。
///
/// 用法（六个 dump 对应三条 OD × 公交/步行）：
///   adb pull /sdcard/Android/data/com.seniornav.seniornav/files/sdk_probe_metro_direct_transit.json /tmp/
///   dart run tool/parse_sdk_dump.dart /tmp/sdk_probe_metro_direct_transit.json transit
///   dart run tool/parse_sdk_dump.dart /tmp/sdk_probe_metro_direct_walking.json walking
library;

import 'dart:convert';
import 'dart:io';

import 'package:seniornav/baidu_route_parser.dart';
import 'package:seniornav/route_summary.dart';

void main(List<String> args) {
  if (args.length != 2 || (args[1] != 'transit' && args[1] != 'walking')) {
    stderr.writeln('用法: dart run tool/parse_sdk_dump.dart <dump.json> <transit|walking>');
    exit(2);
  }
  final payload = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final now = DateTime.now();
  final result = args[1] == 'transit'
      ? parseTransit(payload, fetchedAt: now)
      : parseWalking(payload, fetchedAt: now);

  switch (result) {
    case RouteRejected(:final status, :final message):
      stdout.writeln('被拒绝 status=$status message=$message');
      exit(1);
    case RouteMalformed(:final detail):
      stdout.writeln('结构畸形：$detail');
      exit(1);
    case RouteEmpty():
      stdout.writeln('没有方案（RouteEmpty）。');
    case RouteParsed(:final routes):
      stdout.writeln('解析出 ${routes.length} 条方案。');
      for (var i = 0; i < routes.length; i++) {
        final r = routes[i];
        stdout.writeln('--- 方案 $i：${r.durationSec}s ${r.distanceM}m '
            'walk=${r.walkM}m transfers=${r.transfers}');
        for (final leg in r.legs) {
          final missing = <String>[
            if (leg.lineName == null) 'lineName',
            if (leg.direction == null) 'direction',
            if (leg.boardStop == null) 'boardStop',
            if (leg.alightStop == null) 'alightStop',
            if (leg.stopCount == null) 'stopCount',
            if (leg.firstTime == null) 'firstTime',
            if (leg.lastTime == null) 'lastTime',
          ];
          stdout.writeln('    ${leg.lineName}｜开往 ${leg.direction}｜'
              '${leg.boardStop} → ${leg.alightStop}｜${leg.stopCount} 站｜'
              '首 ${leg.firstTime} 末 ${leg.lastTime}｜上车前步行 ${leg.boardWalkM}m'
              '${missing.isEmpty ? '' : '｜缺失: ${missing.join(',')}'}');
        }
        final text = renderSummary(r, now: now);
        stdout.writeln('    摘要 ${text.lineCount} 行：${text.headline} / ${text.emphasis}');
        for (final s in text.steps) {
          stdout.writeln('      $s');
        }
      }
      if (args[1] == 'transit' && routes.isNotEmpty) {
        final best = selectRoute(routes);
        stdout.writeln('selectRoute 选中：${best.durationSec}s transfers=${best.transfers}');
      }
  }
}