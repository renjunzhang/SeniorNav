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
  });
  final PlaceRepository places;
  final PoiService poi;
  final RouteService routes;
  final NavigationService navigation;
}
