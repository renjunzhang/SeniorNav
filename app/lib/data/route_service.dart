import 'dart:convert';

import 'package:coordtransform_dart/coordtransform_dart.dart';
import 'package:geolocator/geolocator.dart';

import '../baidu_route_parser.dart';
import '../core/contracts.dart';
import '../route_summary.dart';
import 'baidu_client.dart';

typedef CurrentLocation = Future<GeoPoint> Function();

Future<GeoPoint> foregroundLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const AppFailure('请让家人打开手机定位，也可以直接打开百度地图。');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw const AppFailure('无法获取位置，请让家人打开定位权限。');
  }
  final Position position;
  try {
    // This timeout cancels local GPS acquisition, not a Baidu route request.
    position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
  } catch (_) {
    throw const AppFailure('位置不确定，请到开阔处再试，或直接打开百度地图。');
  }
  if (!position.accuracy.isFinite ||
      position.accuracy > 100 ||
      DateTime.now().difference(position.timestamp) >
          const Duration(minutes: 2)) {
    throw const AppFailure('位置可能不准，请到开阔处再试，或直接打开百度地图。');
  }
  final bd = CoordinateTransformUtil.wgs84ToBd09(
    position.longitude,
    position.latitude,
  );
  return GeoPoint(bd[1], bd[0]);
}

class SdkRouteService implements RouteService {
  SdkRouteService(this.client, {CurrentLocation? location})
    : _location = location ?? foregroundLocation;
  final BaiduClient client;
  final CurrentLocation _location;
  @override
  bool get busy => client.busy;

  @override
  Future<RouteBundle> load(SavedPlace destination) => client.run((
    session,
  ) async {
    if (destination.verifiedAt == null) {
      throw const AppFailure('这个地点还没有核对入口，请让家人先完成设置。');
    }
    final origin = await _location();
    final at = DateTime.now();
    final args = <String, Object?>{
      'fromLat': origin.latitude,
      'fromLng': origin.longitude,
      'toLat': destination.latitude,
      'toLng': destination.longitude,
    };
    // One operation lock, at most three distinct queries, always awaited in order.
    // A UI timeout must not free the native slot. Never retry an uncertain request.
    final results = <RouteMode, RouteParseResult>{};
    final messages = <RouteMode, String>{};
    AppFailure? firstFailure;
    for (final mode in [
      RouteMode.metro,
      RouteMode.transit,
      RouteMode.walking,
    ]) {
      if (client.blocked) {
        messages[mode] = '上一条查询尚未确认结束，未继续查询，请打开百度地图。';
        continue;
      }
      try {
        final walking = mode == RouteMode.walking;
        final raw = await session.call(walking ? 'walking' : 'transit', {
          ...args,
          if (!walking) 'policy': mode == RouteMode.metro ? 5 : 3,
        });
        results[mode] = walking
            ? parseWalking(_json(raw), fetchedAt: at)
            : parseTransit(_json(raw), fetchedAt: at, mode: mode);
      } on AppFailure catch (error) {
        firstFailure ??= error;
        messages[mode] = error.message;
      }
    }
    final metro = _ride(results[RouteMode.metro], metro: true);
    final transit = _ride(results[RouteMode.transit], metro: false);
    final walking = _selected(results[RouteMode.walking]);
    if (client.blocked && metro == null && transit == null && walking == null) {
      throw firstFailure ?? const AppFailure('查询尚未确认结束，请打开百度地图。');
    }
    final rides = [?metro, ?transit];
    final ride = rides.isEmpty ? null : selectRoute(rides);
    final advice = walking == null
        ? null
        : recommendMode(transit: ride, walking: walking);
    final recommendedMode = walking != null && advice != ModeAdvice.transit
        ? RouteMode.walking
        : ride?.mode ?? RouteMode.metro;

    String? message(RouteMode mode, RouteSummary? route, String label) {
      final parts = <String>[
        if (messages[mode] != null) messages[mode]!,
        if (route == null && messages[mode] == null)
          _message(results[mode], label) ?? '暂时没有符合条件的$label方案，请打开百度地图核对。',
        if (route != null && client.blocked) '后续查询未完成，已保留这条路线，请以百度地图为准。',
        if (mode == RouteMode.walking && advice == ModeAdvice.walkFarWarning)
          '步行距离较远，出发前请让家人协助确认。',
      ];
      return parts.isEmpty ? null : parts.join('\n');
    }

    return RouteBundle(
      recommendedMode: recommendedMode,
      fetchedAt: at,
      origin: origin,
      metro: metro,
      transit: transit,
      walking: walking,
      metroMessage: message(RouteMode.metro, metro, '地铁'),
      transitMessage: message(RouteMode.transit, transit, '公交'),
      walkingMessage: message(RouteMode.walking, walking, '步行'),
    );
  });

  static RouteSummary? _ride(RouteParseResult? result, {required bool metro}) {
    if (result is! RouteParsed) return null;
    final candidates = result.routes.where((route) {
      if (route.legs.isEmpty ||
          route.legs.any((leg) => leg.lineType == LineType.unknown)) {
        return false;
      }
      // 地铁只保留全程地铁的方案，公交接驳路线不进地铁选项。
      return metro
          ? route.legs.every((leg) => leg.lineType == LineType.metro)
          : route.legs.every((leg) => leg.lineType == LineType.bus);
    }).toList();
    return candidates.isEmpty ? null : selectRoute(candidates);
  }

  static Map<String, dynamic> _json(Object? raw) {
    try {
      final value = raw is String ? jsonDecode(raw) : raw;
      if (value is Map) return Map<String, dynamic>.from(value);
    } catch (_) {
      // No raw response logging, even for malformed replies.
    }
    throw const AppFailure('路线信息暂时无法读取，请打开百度地图。');
  }

  static RouteSummary? _selected(RouteParseResult? result) => switch (result) {
    RouteParsed(:final routes) => routes.isEmpty ? null : selectRoute(routes),
    _ => null,
  };
  static String? _message(RouteParseResult? result, String mode) =>
      switch (result) {
        RouteEmpty() => '没有查到$mode路线，可以切换出行方式或打开百度地图。',
        RouteParsed() => null,
        _ => '$mode路线暂时查不到，请以百度地图为准。',
      };
}

class SdkPoiService implements PoiService {
  SdkPoiService(this.client);
  final BaiduClient client;
  @override
  Future<List<PoiCandidate>> search({
    required String query,
    required String city,
  }) => client.run((session) async {
    if (query.trim().isEmpty || city.trim().isEmpty) {
      throw const AppFailure('请填写城市和地点名称。');
    }
    final raw = await session.call('searchPoi', {
      'query': query.trim(),
      'city': city.trim(),
    });
    if (raw is! List) throw const AppFailure('地点结果暂时无法读取。');
    return raw.map((value) => _candidate(value, fallbackCity: city)).toList();
  });

  @override
  Future<PoiCandidate> detail(PoiCandidate candidate) => client.run(
    (session) async => _candidate(
      await session.call('poiDetail', {'uid': candidate.uid}),
      fallbackCity: candidate.city,
      fallbackAddress: candidate.address,
    ),
  );

  static PoiCandidate _candidate(
    Object? raw, {
    required String fallbackCity,
    String fallbackAddress = '',
  }) {
    if (raw is! Map) throw const AppFailure('地点信息不完整，请重新选择。');
    final lat = raw['latitude'];
    final lng = raw['longitude'];
    final uid = raw['uid'];
    final name = raw['name'];
    if (lat is! num ||
        lng is! num ||
        uid is! String ||
        uid.isEmpty ||
        name is! String ||
        name.isEmpty ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat.abs() > 90 ||
        lng.abs() > 180) {
      throw const AppFailure('地点坐标不完整，请重新选择。');
    }
    final navLat = raw['naviLatitude'];
    final navLng = raw['naviLongitude'];
    final navValid =
        navLat is num &&
        navLng is num &&
        navLat.isFinite &&
        navLng.isFinite &&
        navLat.abs() <= 90 &&
        navLng.abs() <= 180;
    final city = raw['city'];
    return PoiCandidate(
      uid: uid,
      name: name,
      address: raw['address'] is String && (raw['address'] as String).isNotEmpty
          ? raw['address'] as String
          : fallbackAddress,
      city: city is String && city.isNotEmpty ? city : fallbackCity,
      point: GeoPoint(lat.toDouble(), lng.toDouble()),
      navigationPoint: navValid
          ? GeoPoint(navLat.toDouble(), navLng.toDouble())
          : null,
    );
  }
}
