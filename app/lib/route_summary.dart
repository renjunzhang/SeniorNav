/// 路线摘要的领域模型与文案生成。
///
/// 对应方案 v0.2 §3.3（摘要页文案规则）、§3.4（自动推荐）、§4.4（RouteSummary）。
/// 这一层不认识百度：无论数据来自 Web API 代理（§4.2 方案 A）还是 Android SDK
/// （方案 B），都先转成这里的结构，文案规则只写一遍。D1 决策切换数据源时，
/// 本文件不需要改动。
library;

import 'dart:math';

/// 出行方式。
// `transit` is the bus option; metro is selected separately.
enum RouteMode { metro, transit, walking }

/// 线路类型。取自 `vehicle_info.detail.type`，实测 0 = 普通公交、1 = 地铁/轻轨。
enum LineType {
  bus,
  metro,
  unknown;

  static LineType fromBaidu(Object? raw) => switch (raw) {
        0 => LineType.bus,
        1 => LineType.metro,
        _ => LineType.unknown,
      };
}

/// 一段乘车。
///
/// §4.4 把 `lineName`/`direction`/`boardStop`/`alightStop`/`stopCount` 列成
/// RouteSummary 的扁平字段，但 1 次换乘的线路有 2 段乘车，扁平结构装不下，
/// 因此实现上必须是列表。
///
/// 字段一律可空：§4.4 要求「每个字段缺失时要有降级文案，不能编造」，
/// 用空串占位会让渲染层分不清「百度没给」和「百度给了空值」。
class TransitLeg {
  const TransitLeg({
    this.lineName,
    this.lineType = LineType.unknown,
    this.direction,
    this.boardStop,
    this.alightStop,
    this.stopCount,
    this.firstTime,
    this.lastTime,
    this.boardWalkM = 0,
  });

  final String? lineName;
  final LineType lineType;

  /// 行车方向，来自 `detail.direct_text`（形如「合肥火车站方向」）。
  ///
  /// 绝不能取 `detail.end_info.end_name`：那是**下车站**。实测
  /// 大蜀山→省立医院的 85 路，`direct_text` 是「合肥火车站方向」而
  /// `end_name` 是「长丰路桥站」，照 §4.4 原文实现会给老人指错行车方向
  /// （ADR 0002 A2）。
  final String? direction;

  final String? boardStop;
  final String? alightStop;

  /// 站间数，实测恒等于 `len(stop_info) + 1`，5 段样本全部吻合，
  /// 因此 §3.3 的「坐 N 站」文案成立（ADR 0002 §2.5）。
  final int? stopCount;

  /// 首末班时间，形如 `06:00`。百度**不校验运营时间**：凌晨 2 点查询
  /// 照样返回首班 06:12 的地铁方案，因此必须在客户端比对（ADR 0002 A7）。
  final String? firstTime;
  final String? lastTime;

  /// 上车前的步行距离（米）。
  final int boardWalkM;
}

/// 一条完整路线。
class RouteSummary {
  const RouteSummary({
    required this.mode,
    required this.durationSec,
    required this.distanceM,
    required this.fetchedAt,
    this.walkM = 0,
    this.legs = const [],
    this.arriveTime,
    this.crossingCount = 0,
  });

  final RouteMode mode;
  final int durationSec;
  final int distanceM;

  /// 各步行段距离之和。统计 `trans_type == 0`（普通步行）与 `== 4`（换乘步行）；
  /// `trans_type == 3` 是同站换乘标记，距离恒为 1 米，计入会让步行数虚高。
  final int walkM;

  final List<TransitLeg> legs;

  /// 百度给的到达时间，形如 `2026-11-12 03:00:37`。仅用于展示，不参与推荐。
  final String? arriveTime;

  /// 步行方案里含过街词的步骤数（天桥/地下通道/斑马线/红绿灯/过街/横穿/马路）。
  final int crossingCount;

  final DateTime fetchedAt;

  /// §4.4：换乘次数 = 车辆段数 − 1。做成派生属性而不是存储字段，
  /// 免得两处各算一遍算出不同的值。
  int get transfers => legs.isEmpty ? 0 : legs.length - 1;

  bool get isTransit => mode != RouteMode.walking;

  /// §4.4：摘要页显示查询时间，超过 5 分钟提示重新查询。
  bool isStaleAt(DateTime now, {Duration threshold = const Duration(minutes: 5)}) =>
      now.difference(fetchedAt) > threshold;
}

/// 渲染后的摘要文案。
///
/// §3.3 要求「摘要最多 6 行」，因此这里给出的是**已经排好行数**的结果：
/// headline 1 行 + emphasis 1 行 + steps 最多 4 行 = 6 行。
class SummaryText {
  const SummaryText({
    required this.headline,
    this.emphasis,
    this.steps = const [],
    this.warnings = const [],
  });

  /// 「约 35 分钟（含步行）」。
  final String headline;

  /// 老人最关心的一行。公交是「不用换车」/「要换 1 次车」，步行是过街提示。
  ///
  /// §3.3 的文案规则说「先写不用换车」，但同节的示例把它排在步骤之后，
  /// 两者矛盾。这里按规则实现（紧跟 headline），示例视为排版示意。
  final String? emphasis;

  /// 带 ①②③ 序号的步骤行，最多 4 行。
  final List<String> steps;

  /// 首末班、距离过远等提示。不计入 6 行预算，用不同样式单独展示。
  final List<String> warnings;

  int get lineCount => 1 + (emphasis == null ? 0 : 1) + steps.length;
}

const List<String> _stepMarks = ['①', '②', '③', '④'];

/// 米数取整到 10 米、公里取整到 0.1 公里，与百度自己的
/// 「走740米 / 走1.0公里」写法一致，避免出现「753 米」这种假精度。
String formatDistance(int meters) {
  if (meters < 1000) return '约 ${(meters / 10).round() * 10} 米';
  return '约 ${(meters / 100).round() / 10} 公里';
}

String formatDuration(int seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '约 $minutes 分钟';
  final rest = minutes % 60;
  return rest == 0 ? '约 ${minutes ~/ 60} 小时' : '约 ${minutes ~/ 60} 小时 $rest 分钟';
}

/// 把 `HH:mm` 解析成当天的分钟数；解析不了返回 null，不猜。
int? _minutesOfDay(String? hhmm) {
  if (hhmm == null) return null;
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// 生成摘要文案。`now` 由调用方传入，便于用 fixture 里录制的时刻做确定性测试。
SummaryText renderSummary(RouteSummary s, {required DateTime now}) {
  return s.isTransit ? _renderTransit(s, now: now) : _renderWalking(s);
}

SummaryText _renderTransit(RouteSummary s, {required DateTime now}) {
  final warnings = <String>[];

  if (s.legs.isEmpty) {
    // 走到这里说明上游把一条没有乘车段的方案当成公交摘要传进来了。
    // 不编造线路，直接给时长并提示以百度为准。
    return SummaryText(
      headline: '${formatDuration(s.durationSec)}（含步行）',
      warnings: ['查不到具体线路，请打开百度地图查看'],
    );
  }

  for (final leg in s.legs) {
    final first = _minutesOfDay(leg.firstTime);
    final last = _minutesOfDay(leg.lastTime);
    if (first == null && last == null) continue;
    final minuteNow = now.hour * 60 + now.minute;
    final label = leg.lineName ?? '该线路';
    if (first != null && minuteNow < first) {
      warnings.add('$label 首班 ${leg.firstTime}，现在可能还没发车');
    } else if (last != null && minuteNow > last) {
      warnings.add('$label 末班 ${leg.lastTime}，现在可能已经收车');
    }
  }

  final lines = <String>[];

  final firstLeg = s.legs.first;
  if (firstLeg.boardWalkM > 0) {
    final to = firstLeg.boardStop == null ? '' : ' → ${firstLeg.boardStop}';
    lines.add('步行${formatDistance(firstLeg.boardWalkM)}$to');
  }

  for (var i = 0; i < s.legs.length; i++) {
    final leg = s.legs[i];
    final ride = _renderLeg(leg, isFirst: i == 0);
    // 换乘步行并进换乘行，不单独占一行：4 行预算下单独一行会把「换哪路车」挤掉。
    lines.add(i > 0 && leg.boardWalkM > 0
        ? '步行${formatDistance(leg.boardWalkM)}，$ride'
        : ride);
  }

  final trailingWalk = s.walkM - s.legs.fold<int>(0, (sum, l) => sum + l.boardWalkM);
  if (trailingWalk > 0) {
    lines.add('步行${formatDistance(trailingWalk)}到终点');
  }

  // §4.4：steps 最多 4 段；§3.3：摘要总共最多 6 行（headline + emphasis + 4）。
  // 因此这条兜底行要占掉预算里的最后一格，而不是追加在第 4 行之后。
  if (lines.length > _stepMarks.length) {
    lines.removeRange(_stepMarks.length - 1, lines.length);
    lines.add('之后的换乘请打开百度地图查看');
  }

  final steps = [
    for (var i = 0; i < lines.length; i++) '${_stepMarks[i]} ${lines[i]}',
  ];

  return SummaryText(
    headline: '${formatDuration(s.durationSec)}（含步行）',
    emphasis: s.transfers == 0 ? '不用换车' : '要换 ${s.transfers} 次车',
    steps: steps,
    warnings: warnings,
  );
}

String _renderLeg(TransitLeg leg, {required bool isFirst}) {
  final buffer = StringBuffer(isFirst ? '坐 ' : '换 ');
  buffer.write(leg.lineName ?? '公交');

  // 方向缺失时整段括号省略，而不是写「开往 未知 方向」。
  if (leg.direction != null && leg.direction!.isNotEmpty) {
    buffer.write('（开往 ${leg.direction}）');
  }
  if (leg.stopCount != null) {
    buffer.write('，${leg.stopCount} 站');
  }
  if (leg.alightStop != null && leg.alightStop!.isNotEmpty) {
    buffer.write('，${leg.alightStop}下车');
  }
  return buffer.toString();
}

SummaryText _renderWalking(RouteSummary s) {
  final warnings = <String>[];
  if (s.distanceM > 3000) {
    warnings.add('距离较远，建议直接打开百度地图');
  }
  return SummaryText(
    headline: '${formatDuration(s.durationSec)} · ${formatDistance(s.distanceM)}',
    // 过街词命中数为 0 时不写「沿途不需要过马路」：百度没提到不等于没有，
    // 这种断言会让老人在真实路口放松警惕。
    emphasis: s.crossingCount > 0 ? '途中需要过马路（${s.crossingCount} 处）' : null,
    warnings: warnings,
  );
}

/// §3.4 的自动推荐结果。
enum ModeAdvice {
  /// 推荐走路。
  walk,

  /// 推荐坐公交。
  transit,

  /// 没有公交方案且步行超过 3 公里：提示距离较远，优先打开百度地图。
  walkFarWarning,
}

/// §3.4：按表格自上而下匹配，第一条命中即返回。
///
/// 全部用实际路线结果比较，不用直线距离估算（§3.4 规则细节第一条）。
/// `transit` 为 null 表示没有公交方案——判据是 `status == 0 且 routes 为空`，
/// 不是 `status != 0`（ADR 0002 A6）。
ModeAdvice recommendMode({RouteSummary? transit, required RouteSummary walking}) {
  if (walking.distanceM <= 1000 && walking.durationSec <= 20 * 60) {
    return ModeAdvice.walk;
  }
  if (transit == null) {
    return walking.distanceM > 3000 ? ModeAdvice.walkFarWarning : ModeAdvice.walk;
  }
  // §3.4 写「公交总时长比步行少 5 分钟以上」。取严格大于：正好快 5 分钟时
  // 交给下一条规则判断，否则第 3 条（步行 2 公里内且不慢 10 分钟以上）
  // 在边界上永远轮不到，老人会被多带去换乘。
  if (transit.durationSec + 5 * 60 < walking.durationSec) {
    return ModeAdvice.transit;
  }
  if (walking.distanceM <= 2000 && walking.durationSec <= transit.durationSec + 10 * 60) {
    return ModeAdvice.walk;
  }
  return ModeAdvice.transit;
}

/// §4.4：只选 1 条推荐方案——先比换乘次数，再比步行距离，最后比时长。
///
/// 与百度返回的顺序无关。实测 `tactics_incity=2`（少步行）的响应里，
/// 0 换乘的轨道交通 2 号线被排在第 5 位（87.6 分钟/1 换乘的方案反而在第 1 位），
/// 按本规则重排才能把它选出来（ADR 0002 §2.7）。
///
/// **绕路保护**：少换乘不能以明显绕路为代价。先剔掉「比最快方案慢 10 分钟以上」
/// 或「比最短方案远 1 倍以上」的候选，再在剩下的里面比换乘。否则一条 0 换乘但
/// 绕出去几十分钟的方案会赢过一条快得多的 1 换乘方案，老人白白多坐半小时。
/// 10 分钟与 2 倍是 M0 暂定阈值，待真机与老人试用后校准（ADR 0002 §4）。
///
/// 时长过滤永远非空（最快方案自身满足）；若叠加距离过滤后为空，退回只按时长过滤，
/// 保证任何输入都有结果，不抛异常。
RouteSummary selectRoute(Iterable<RouteSummary> routes) {
  final list = routes.toList();
  if (list.isEmpty) {
    throw StateError('没有可选路线；调用方应先判断 routes 是否为空');
  }

  final fastest = list.map((r) => r.durationSec).reduce(min);
  final shortest = list.map((r) => r.distanceM).reduce(min);
  bool withinTime(RouteSummary r) => r.durationSec <= fastest + 10 * 60;
  bool withinDistance(RouteSummary r) => r.distanceM <= shortest * 2;

  var pool = list.where((r) => withinTime(r) && withinDistance(r)).toList();
  if (pool.isEmpty) pool = list.where(withinTime).toList();

  pool.sort((a, b) {
    final byTransfers = a.transfers.compareTo(b.transfers);
    if (byTransfers != 0) return byTransfers;
    final byWalk = a.walkM.compareTo(b.walkM);
    if (byWalk != 0) return byWalk;
    return a.durationSec.compareTo(b.durationSec);
  });
  return pool.first;
}
