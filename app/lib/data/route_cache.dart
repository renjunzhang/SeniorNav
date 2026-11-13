/// RouteBundle 的本地缓存编解码。
///
/// 只编码路线摘要与提示文案，**不编码 origin**：缓存里不允许出现起点坐标，
/// 否则「不记录行踪」的隐私承诺就不成立了。解码对任何畸形输入返回 null，
/// 缓存读不出来就当没有，绝不抛异常影响查询页。
library;

import 'dart:convert';

import '../core/contracts.dart';
import '../route_summary.dart';

const int _version = 1;

String encodeRouteBundle(RouteBundle bundle) => jsonEncode({
  'v': _version,
  'recommendedMode': bundle.recommendedMode.name,
  'fetchedAt': bundle.fetchedAt.millisecondsSinceEpoch,
  'metro': _encodeSummary(bundle.metro),
  'transit': _encodeSummary(bundle.transit),
  'walking': _encodeSummary(bundle.walking),
  'metroMessage': bundle.metroMessage,
  'transitMessage': bundle.transitMessage,
  'walkingMessage': bundle.walkingMessage,
});

RouteBundle? decodeRouteBundle(String source) {
  try {
    final json = jsonDecode(source);
    if (json is! Map || json['v'] != _version) return null;
    final recommendedMode = RouteMode.values.byName(json['recommendedMode']);
    final fetchedAt = DateTime.fromMillisecondsSinceEpoch(
      _requireInt(json['fetchedAt']),
    );
    return RouteBundle(
      recommendedMode: recommendedMode,
      fetchedAt: fetchedAt,
      metro: _decodeSummary(json['metro']),
      transit: _decodeSummary(json['transit']),
      walking: _decodeSummary(json['walking']),
      metroMessage: _string(json['metroMessage']),
      transitMessage: _string(json['transitMessage']),
      walkingMessage: _string(json['walkingMessage']),
    );
  } catch (_) {
    return null;
  }
}

Map<String, Object?>? _encodeSummary(RouteSummary? route) {
  if (route == null) return null;
  return {
    'mode': route.mode.name,
    'durationSec': route.durationSec,
    'distanceM': route.distanceM,
    'walkM': route.walkM,
    'arriveTime': route.arriveTime,
    'crossingCount': route.crossingCount,
    'fetchedAt': route.fetchedAt.millisecondsSinceEpoch,
    'legs': [
      for (final leg in route.legs)
        {
          'lineName': leg.lineName,
          'lineType': leg.lineType.name,
          'direction': leg.direction,
          'boardStop': leg.boardStop,
          'alightStop': leg.alightStop,
          'stopCount': leg.stopCount,
          'firstTime': leg.firstTime,
          'lastTime': leg.lastTime,
          'boardWalkM': leg.boardWalkM,
        },
    ],
  };
}

RouteSummary? _decodeSummary(Object? json) {
  if (json == null) return null;
  if (json is! Map) throw const FormatException('summary');
  return RouteSummary(
    mode: RouteMode.values.byName(json['mode']),
    durationSec: _requireInt(json['durationSec']),
    distanceM: _requireInt(json['distanceM']),
    walkM: _int(json['walkM']) ?? 0,
    arriveTime: _string(json['arriveTime']),
    crossingCount: _int(json['crossingCount']) ?? 0,
    fetchedAt: DateTime.fromMillisecondsSinceEpoch(
      _requireInt(json['fetchedAt']),
    ),
    legs: [
      for (final leg in (json['legs'] as List? ?? const [])) _decodeLeg(leg),
    ],
  );
}

TransitLeg _decodeLeg(Object? json) {
  if (json is! Map) throw const FormatException('leg');
  return TransitLeg(
    lineName: _string(json['lineName']),
    lineType: LineType.values.byName(json['lineType']),
    direction: _string(json['direction']),
    boardStop: _string(json['boardStop']),
    alightStop: _string(json['alightStop']),
    stopCount: _int(json['stopCount']),
    firstTime: _string(json['firstTime']),
    lastTime: _string(json['lastTime']),
    boardWalkM: _int(json['boardWalkM']) ?? 0,
  );
}

int _requireInt(Object? value) {
  if (value is int) return value;
  throw const FormatException('int');
}

int? _int(Object? value) => value is int ? value : null;
String? _string(Object? value) => value is String ? value : null;