import 'package:flutter/foundation.dart';

import '../baidu_uri.dart';
import '../route_summary.dart';

class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);
  final double latitude;
  final double longitude;
}

class PoiCandidate {
  const PoiCandidate({
    required this.uid,
    required this.name,
    required this.address,
    required this.city,
    required this.point,
    this.navigationPoint,
  });
  final String uid;
  final String name;
  final String address;
  final String city;
  final GeoPoint point;
  final GeoPoint? navigationPoint;
  GeoPoint get preferredPoint => navigationPoint ?? point;
}

class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.slot,
    required this.label,
    required this.icon,
    required this.name,
    required this.address,
    required this.city,
    required this.latitude,
    required this.longitude,
    required this.updatedAt,
    this.poiUid,
    this.verifiedAt,
    this.sortOrder = 0,
    this.rev = 1,
    this.deletedAt,
  });
  final String id;
  final int slot;
  final String label;
  final String icon;
  final String name;
  final String address;
  final String city;
  final double latitude;
  final double longitude;
  final String? poiUid;
  final DateTime updatedAt;
  final DateTime? verifiedAt;
  final int sortOrder;
  final int rev;
  final DateTime? deletedAt;
  GeoPoint get point => GeoPoint(latitude, longitude);
  Destination get destination => Destination(
    name: name,
    uid: poiUid,
    latitude: latitude,
    longitude: longitude,
    region: city,
  );
}

abstract class PlaceRepository extends ChangeNotifier {
  List<SavedPlace> get places;
  bool get privacyAccepted;
  bool get hasPin;
  Future<void> initialize();
  Future<void> savePlace(SavedPlace place);
  Future<void> deletePlace(String id);
  Future<void> reorderMore(List<String> ids);
  Future<void> acceptPrivacy();
  Future<void> setPin(String pin);
  Future<bool> verifyPin(String pin);
}

abstract interface class PoiService {
  Future<List<PoiCandidate>> search({
    required String query,
    required String city,
  });
  Future<PoiCandidate> detail(PoiCandidate candidate);
}

class RouteBundle {
  const RouteBundle({
    required this.recommendedMode,
    required this.fetchedAt,
    this.origin,
    this.metro,
    this.transit,
    this.walking,
    this.metroMessage,
    this.transitMessage,
    this.walkingMessage,
  });
  final RouteMode recommendedMode;
  final DateTime fetchedAt;
  final GeoPoint? origin;
  final RouteSummary? metro;

  /// Bus-only option; the historic `transit` name is retained for callers.
  final RouteSummary? transit;
  final RouteSummary? walking;
  final String? metroMessage;
  final String? transitMessage;
  final String? walkingMessage;
}

abstract interface class RouteService {
  bool get busy;
  Future<RouteBundle> load(SavedPlace destination);
}

/// 上次路线摘要的本地缓存，断网/定位失败时兜底展示。
/// 只存路线本身，绝不存起点坐标；读写失败不抛异常，不能影响正常查询。
abstract interface class RouteCache {
  Future<void> save(String placeId, RouteBundle bundle);
  Future<RouteBundle?> read(String placeId);
}

/// 进行中的行程：出发时钉住一条路线，途中重开不变，直到显式结束。
class ActiveTrip {
  const ActiveTrip({
    required this.placeId,
    required this.bundle,
    required this.startedAt,
  });
  final String placeId;
  final RouteBundle bundle;
  final DateTime startedAt;
}

/// 同一时刻只有一条进行中行程。行程路线同样不存起点坐标；
/// 读取失败按无行程处理，开始/结束失败要抛异常让界面提示。
abstract interface class TripStore {
  Future<ActiveTrip?> readTrip();
  Future<void> startTrip(
    String placeId,
    RouteBundle bundle, {
    DateTime? startedAt,
  });
  Future<void> endTrip();
}

enum NavigationOutcome { nativeApp, web, unavailable }

abstract interface class NavigationService {
  Future<NavigationOutcome> open(
    SavedPlace place,
    RouteMode mode, {
    GeoPoint? origin,
  });
  Future<NavigationOutcome> verifyPlace(PoiCandidate candidate);
}

class AppFailure implements Exception {
  const AppFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppServices {
  const AppServices({
    required this.places,
    required this.poi,
    required this.routes,
    required this.navigation,
    required this.cache,
    required this.trip,
  });
  final PlaceRepository places;
  final PoiService poi;
  final RouteService routes;
  final NavigationService navigation;
  final RouteCache cache;
  final TripStore trip;
}
