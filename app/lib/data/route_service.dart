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
    // Never replace these awaits with Future.wait. POI shares the same lock.
    final transitResult = parseTransit(
      _json(await session.call('transit', {...args, 'policy': 0})),
      fetchedAt: at,
    );
    var transit = _selected(transitResult);
    RouteParseResult walkingResult;
    var walkingFailed = false;
    try {
      walkingResult = parseWalking(
        _json(await session.call('walking', args)),
        fetchedAt: at,
      );
    } on AppFailure {
      if (transit == null) rethrow;
      walkingFailed = true;
      walkingResult = const RouteRejected(-1, 'WALKING_UNAVAILABLE');
    }
    final walking = _selected(walkingResult);
    var transitMessage = _message(transitResult, '公交');
    if (transit != null &&
        transit.transfers >= 1 &&
        !walkingFailed &&
        !client.blocked) {
      // One alternate-policy query after both callbacks; never a network retry.
      try {
        final alternative = parseTransit(
          _json(await session.call('transit', {...args, 'policy': 1})),
          fetchedAt: at,
        );
        if (alternative case RouteParsed(:final routes)) {
          transit = selectRoute([
            ...(transitResult as RouteParsed).routes,
            ...routes,
          ]);
        } else if (alternative is RouteRejected ||
            alternative is RouteMalformed) {
          transitMessage = '少换乘方案暂时查不到，下面保留已查到的路线。';
        }
      } on AppFailure {
        transitMessage = '少换乘查询未完成，下面保留已查到的路线，请以百度地图为准。';
      }
    }
    final advice = walking == null
        ? null
        : recommendMode(transit: transit, walking: walking);
    return RouteBundle(
      recommendedMode: advice == ModeAdvice.transit || walking == null
          ? RouteMode.transit
          : RouteMode.walking,
      fetchedAt: at,
      origin: origin,
      transit: transit,
      walking: walking,
      transitMessage: transitMessage,
      walkingMessage: advice == ModeAdvice.walkFarWarning
          ? '步行距离较远，出发前请让家人协助确认。'
          : _message(walkingResult, '步行'),
    );
  });

  static Map<String, dynamic> _json(Object? raw) {
    try {
      final value = raw is String ? jsonDecode(raw) : raw;
      if (value is Map) return Map<String, dynamic>.from(value);
    } catch (_) {
      // No raw response logging, even for malformed replies.
    }
    throw const AppFailure('路线信息暂时无法读取，请打开百度地图。');
  }

  static RouteSummary? _selected(RouteParseResult result) => switch (result) {
    RouteParsed(:final routes) => routes.isEmpty ? null : selectRoute(routes),
    _ => null,
  };
  static String? _message(RouteParseResult result, String mode) =>
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
