/// 百度路线 Web API 响应 → [RouteSummary]。
///
/// 字段映射全部以 `app/test/fixtures/` 下 6 份真实录制响应为准，
/// 而不是方案 v0.2 §4.3 的描述——§4.3 的响应结构与实测有出入，
/// 详见 docs/adr/0002-路线数据源WebAPI实测.md。
///
/// 若 §4.2 的 D1 决策最终选 Android SDK（方案 B），本文件整体替换，
/// 但 route_summary.dart 的模型与文案规则不变。
library;

import 'route_summary.dart';

/// 解析结果。分成四种而不是「成功/失败」两种，是因为 §3.7 的失败表需要
/// 区分「今天没有公交方案」和「百度改了结构」：前者要引导老人走路，
/// 后者是必须修的缺陷，两者的告警级别完全不同。
sealed class RouteParseResult {
  const RouteParseResult();
}

/// 至少解析出一条路线。
final class RouteParsed extends RouteParseResult {
  const RouteParsed(this.routes);

  final List<RouteSummary> routes;
}

/// `status == 0` 但 `routes` 为空。
///
/// 这是**成功响应**，不是错误：实测 95 米的起终点会返回这种形状，
/// 意思是这段路没有公交方案。把它当成失败会让老人看到「暂时查不到路线」，
/// 而正确答案是「走路」（ADR 0002 A6）。
final class RouteEmpty extends RouteParseResult {
  const RouteEmpty();
}

/// `status != 0`，例如配额不足、参数有误、SN 校验失败。
final class RouteRejected extends RouteParseResult {
  const RouteRejected(this.status, this.message);

  final int status;
  final String message;
}

/// 响应结构不符合预期（字段缺失或类型变了）。
///
/// 百度升级接口时会走到这里。§3.7 要求任何失败都保留「打开百度地图」出路，
/// 因此这种情况必须是可捕获的结果而不是异常，否则摘要页会白屏。
final class RouteMalformed extends RouteParseResult {
  const RouteMalformed(this.detail);

  final String detail;
}

/// 步行指令里的过街词。§3.3 要求步行摘要给出「是否需要过街提示」。
final RegExp _crossingWords = RegExp('天桥|地下通道|斑马线|红绿灯|过街|横穿|马路');

/// 百度把转向词包在 `<b>` 里（如 `走20米,<b>左转</b>`），摘要不展示 HTML。
final RegExp _htmlTags = RegExp('<[^>]+>');

int _asInt(Object? raw, {String context = ''}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  throw FormatException('期望数字，实际是 ${raw.runtimeType}', context);
}

int? _asOptionalInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

String? _asOptionalString(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  return text.isEmpty ? null : text;
}

Map<String, dynamic>? _asMap(Object? raw) => raw is Map<String, dynamic> ? raw : null;

/// 解析公交/地铁响应（`direction/v2/transit`）。
///
/// [fetchedAt] 由调用方给出真实查询时刻，不从响应里推断：
/// `arrive_time` 是到达时间，拿它当查询时间会让 §4.4 的 5 分钟过期判断失效。
RouteParseResult parseTransit(
  Map<String, dynamic> payload, {
  required DateTime fetchedAt,
}) {
  final status = _asOptionalInt(payload['status']);
  if (status == null) {
    return const RouteMalformed('响应缺少 status 字段');
  }
  if (status != 0) {
    return RouteRejected(status, payload['message']?.toString() ?? '');
  }

  final result = _asMap(payload['result']);
  final rawRoutes = result?['routes'];
  if (rawRoutes is! List) {
    return const RouteMalformed('result.routes 缺失或不是数组');
  }
  if (rawRoutes.isEmpty) return const RouteEmpty();

  final routes = <RouteSummary>[];
  for (var i = 0; i < rawRoutes.length; i++) {
    final route = _asMap(rawRoutes[i]);
    if (route == null) return RouteMalformed('routes[$i] 不是对象');
    try {
      routes.add(_transitRoute(route, fetchedAt: fetchedAt));
    } on FormatException catch (e) {
      return RouteMalformed('routes[$i]: ${e.message}');
    }
  }
  return RouteParsed(routes);
}

RouteSummary _transitRoute(Map<String, dynamic> route, {required DateTime fetchedAt}) {
  final legs = <TransitLeg>[];
  var walkM = 0;
  var pendingWalkM = 0;

  for (final segment in _transitSegments(route)) {
    final detail = _asMap(_asMap(segment['vehicle_info'])?['detail']);
    final transType = _asOptionalInt(segment['trans_type']);

    if (detail != null) {
      legs.add(TransitLeg(
        lineName: _asOptionalString(detail['name']),
        lineType: LineType.fromBaidu(_asOptionalInt(detail['type'])),
        direction: _asOptionalString(detail['direct_text']),
        boardStop: _asOptionalString(detail['on_station']),
        alightStop: _asOptionalString(detail['off_station']),
        stopCount: _asOptionalInt(detail['stop_num']),
        firstTime: _asOptionalString(detail['first_time']),
        lastTime: _asOptionalString(detail['last_time']),
        boardWalkM: pendingWalkM,
      ));
      pendingWalkM = 0;
      continue;
    }

    // trans_type == 3 是同站换乘标记，距离恒为 1 米；计入会让步行数虚高。
    if (transType == 0) {
      final distance = _asInt(segment['distance'], context: '步行段 distance');
      walkM += distance;
      pendingWalkM += distance;
    }
  }

  return RouteSummary(
    mode: RouteMode.transit,
    durationSec: _asInt(route['duration'], context: 'route duration'),
    distanceM: _asInt(route['distance'], context: 'route distance'),
    walkM: walkM,
    legs: legs,
    arriveTime: _asOptionalString(route['arrive_time']),
    fetchedAt: fetchedAt,
  );
}

/// `routes[].steps` 是**列表的列表**：外层是步骤，内层才是分段对象。
///
/// §4.3 把它写成对象数组，直接对元素取字段会抛类型错误（ADR 0002 §2.3）。
/// 同时容忍扁平形状，以免百度哪天改回去。
Iterable<Map<String, dynamic>> _transitSegments(Map<String, dynamic> route) sync* {
  final steps = route['steps'];
  if (steps is! List) {
    throw const FormatException('steps 缺失或不是数组');
  }
  for (final group in steps) {
    if (group is Map<String, dynamic>) {
      yield group;
    } else if (group is List) {
      for (final segment in group) {
        if (segment is Map<String, dynamic>) yield segment;
      }
    }
  }
}

/// 解析步行响应（`direction/v2/walking`）。
///
/// 步行的 `routes[].steps` 是**扁平对象数组**，与公交的嵌套形状不同，
/// 两个接口共用一个解析函数会踩坑。
RouteParseResult parseWalking(
  Map<String, dynamic> payload, {
  required DateTime fetchedAt,
}) {
  final status = _asOptionalInt(payload['status']);
  if (status == null) {
    return const RouteMalformed('响应缺少 status 字段');
  }
  if (status != 0) {
    return RouteRejected(status, payload['message']?.toString() ?? '');
  }

  final rawRoutes = _asMap(payload['result'])?['routes'];
  if (rawRoutes is! List) {
    return const RouteMalformed('result.routes 缺失或不是数组');
  }
  if (rawRoutes.isEmpty) return const RouteEmpty();

  final routes = <RouteSummary>[];
  for (var i = 0; i < rawRoutes.length; i++) {
    final route = _asMap(rawRoutes[i]);
    if (route == null) return RouteMalformed('routes[$i] 不是对象');
    try {
      routes.add(_walkingRoute(route, fetchedAt: fetchedAt));
    } on FormatException catch (e) {
      return RouteMalformed('routes[$i]: ${e.message}');
    }
  }
  return RouteParsed(routes);
}

RouteSummary _walkingRoute(Map<String, dynamic> route, {required DateTime fetchedAt}) {
  var crossings = 0;
  final steps = route['steps'];
  if (steps is List) {
    for (final step in steps) {
      final raw = _asMap(step)?['instructions'];
      if (raw == null) continue;
      if (_crossingWords.hasMatch(raw.toString().replaceAll(_htmlTags, ''))) crossings++;
    }
  }

  return RouteSummary(
    mode: RouteMode.walking,
    durationSec: _asInt(route['duration'], context: 'route duration'),
    distanceM: _asInt(route['distance'], context: 'route distance'),
    crossingCount: crossings,
    fetchedAt: fetchedAt,
  );
}
