/// M0 任务 3 的材料生成器：把真实录制的百度响应渲染成纸面摘要样张。
///
/// 方案 §10 要求「按 §3.3 做纸面摘要，找实际老人读一遍，记录能否复述
/// 线路/方向/下车站」。样张必须由真实数据生成，不能手抄——手抄会顺手
/// 把文案改顺，测出来的是我写的句子而不是渲染器的输出。
///
/// 用法（在 app/ 目录下）：
///   dart run tool/render_paper_summary.dart
///
/// 内置的三条线路起终点都是公共地标（GIT_COMMIT_RULES §3.1 允许入库）。
/// 给老人做正式测试时应换成真实目的地，届时用 --transit/--walking 指定
/// 本机临时录制的 fixture，不要把真实住址的 fixture 写进仓库。
library;

import 'dart:convert';
import 'dart:io';

import 'package:seniornav/baidu_route_parser.dart';
import 'package:seniornav/route_summary.dart';

/// fixture 的录制时刻。首末班提示依赖它，因此样张上会显式印出查询时间。
final DateTime recordedAt = DateTime(2026, 11, 12, 2, 0);

const List<({String label, String origin, String destination, String id})> cases = [
  (
    label: '去火车站',
    origin: '合肥南站-地铁站',
    destination: '合肥火车站',
    id: 'metro_direct',
  ),
  (
    label: '去医院',
    origin: '大蜀山森林公园',
    destination: '安徽省立医院',
    id: 'bus_transfer',
  ),
  (
    label: '去地铁站',
    origin: '合肥南站',
    destination: '合肥南站-地铁站',
    id: 'walk_short',
  ),
];

Map<String, dynamic> readFixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

List<RouteSummary>? transitRoutes(String id) {
  final result = parseTransit(readFixture('${id}_transit'), fetchedAt: recordedAt);
  return switch (result) {
    RouteParsed(:final routes) => routes,
    // status == 0 且 routes 为空是「这段路没有公交方案」，不是失败（ADR 0002 A6）。
    RouteEmpty() => null,
    RouteRejected(:final status, :final message) =>
      throw StateError('$id transit 被拒：status=$status $message'),
    RouteMalformed(:final detail) => throw StateError('$id transit 结构异常：$detail'),
  };
}

RouteSummary? firstTransit(String id) {
  final routes = transitRoutes(id);
  return routes == null ? null : selectRoute(routes);
}

RouteSummary firstWalking(String id) {
  final result = parseWalking(readFixture('${id}_walking'), fetchedAt: recordedAt);
  return switch (result) {
    RouteParsed(:final routes) => selectRoute(routes),
    RouteEmpty() => throw StateError('$id walking 没有方案'),
    RouteRejected(:final status, :final message) =>
      throw StateError('$id walking 被拒：status=$status $message'),
    RouteMalformed(:final detail) => throw StateError('$id walking 结构异常：$detail'),
  };
}

String renderBlock(String title, SummaryText text) {
  // 按段落拼装再空行连接：步行摘要没有步骤行，逐行 writeln 会留下连续空行。
  final sections = <String>[
    title,
    [
      text.headline,
      if (text.emphasis != null) text.emphasis,
    ].join('\n'),
    if (text.steps.isNotEmpty) text.steps.join('\n'),
    if (text.warnings.isNotEmpty) text.warnings.map((w) => '⚠ $w').join('\n'),
  ];
  return sections.where((s) => s.isNotEmpty).join('\n\n');
}

void main(List<String> args) {
  for (final (index, item) in cases.indexed) {
    final transit = firstTransit(item.id);
    final walking = firstWalking(item.id);
    final advice = recommendMode(transit: transit, walking: walking);

    stdout
      ..writeln('=' * 46)
      ..writeln('样张 ${index + 1}｜${item.label}')
      ..writeln('${item.origin} → ${item.destination}')
      ..writeln('自动推荐：${switch (advice) {
        ModeAdvice.walk => '走路',
        ModeAdvice.transit => '坐公交',
        ModeAdvice.walkFarWarning => '距离较远，优先打开百度地图',
      }}')
      ..writeln();

    // 两种方式都要印：§3.4 规则细节要求「推荐只决定默认选中，不隐藏另一种」。
    if (transit != null) {
      stdout
        ..writeln(renderBlock(
          '${item.label} · 坐公交${advice == ModeAdvice.transit ? '（推荐）' : ''}',
          renderSummary(transit, now: recordedAt),
        ))
        ..writeln('-' * 46);
    } else {
      stdout
        ..writeln('${item.label} · 坐公交')
        ..writeln('这段路没有公交方案')
        ..writeln()
        ..writeln('-' * 46);
    }

    stdout
      ..writeln(renderBlock(
        '${item.label} · 走路${advice == ModeAdvice.walk ? '（推荐）' : ''}',
        renderSummary(walking, now: recordedAt),
      ))
      ..writeln('-' * 46)
      ..writeln('查询时间 02:00｜路线以百度地图为准｜数据来源：百度地图')
      ..writeln();
  }

  // 附加样张：上面三条推荐方案都是 0 换乘，朗读测试里「换几次车」「下车走多远」
  // 两问因此测不到。固定取 metro_direct 第 2 条（1 次换乘 + 495 米换乘步行），
  // 专测换乘文案，不是推荐结果。
  final transfer = transitRoutes('metro_direct')![1];
  stdout
    ..writeln('=' * 46)
    ..writeln('样张 4｜去火车站（换乘方案，非推荐）')
    ..writeln('合肥南站-地铁站 → 合肥火车站')
    ..writeln()
    ..writeln(renderBlock(
      '去火车站 · 坐公交（1 次换乘）',
      renderSummary(transfer, now: recordedAt),
    ))
    ..writeln('-' * 46)
    ..writeln('查询时间 02:00｜路线以百度地图为准｜数据来源：百度地图')
    ..writeln();
}
