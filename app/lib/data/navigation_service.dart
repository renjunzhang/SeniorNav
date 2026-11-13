import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../baidu_uri.dart';
import '../core/contracts.dart';
import '../route_summary.dart';

typedef UriOpener = Future<bool> Function(Uri uri);

class BaiduNavigationService implements NavigationService {
  BaiduNavigationService({
    UriOpener? opener,
    Future<bool> Function()? installed,
    Future<String?> Function()? version,
  }) : _opener =
           opener ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       _installed =
           installed ??
           (() => canLaunchUrl(Uri.parse('baidumap://map/direction'))),
       _version =
           version ??
           (() =>
               const MethodChannel('seniornav/baidu')
                   .invokeMethod<String>('getBaiduVersion'));
  final UriOpener _opener;
  final Future<bool> Function() _installed;
  final Future<String?> Function() _version;

  Future<bool> _try(Uri uri) async {
    try {
      return await _opener(uri);
    } catch (_) {
      return false;
    }
  }

  static bool supportsWalking(String? version) {
    if (version == null) return false;
    final parts = version.split('.');
    final major = int.tryParse(parts.first) ?? 0;
    final minor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return major > 8 || major == 8 && minor >= 8;
  }

  @override
  Future<NavigationOutcome> open(
    SavedPlace place,
    RouteMode mode, {
    GeoPoint? origin,
  }) async {
    final walking = mode == RouteMode.walking;
    final modeName = walking ? 'walking' : 'transit';
    final from = origin == null
        ? originMyLocation
        : baiduLatLng(origin.latitude, origin.longitude);
    bool native = false;
    try {
      native = await _installed();
      if (native && walking) native = supportsWalking(await _version());
    } catch (_) {
      native = false;
    }
    if (native) {
      if (walking && await _try(walkNavi(destination: place.destination))) {
        return NavigationOutcome.nativeApp;
      }
      if (await _try(
        direction(
          destination: place.destination,
          mode: modeName,
          origin: originMyLocation,
          sy: walking ? null : 0,
        ),
      )) {
        return NavigationOutcome.nativeApp;
      }
    }
    // A real BD-09 origin avoids treating the literal “my location” as a POI on web.
    if (await _try(
      webFallback(place.destination, mode: modeName, origin: from),
    )) {
      return NavigationOutcome.web;
    }
    return NavigationOutcome.unavailable;
  }

  @override
  Future<NavigationOutcome> verifyPlace(PoiCandidate candidate) async {
    final point = candidate.preferredPoint;
    final params = {
      'location': baiduLatLng(point.latitude, point.longitude),
      'coord_type': 'bd09ll',
      'title': candidate.name,
      'content': candidate.address,
      'src': srcAndroid,
    };
    try {
      if (await _installed() &&
          await _try(
            Uri.parse('baidumap://map/marker').replace(queryParameters: params),
          )) {
        return NavigationOutcome.nativeApp;
      }
    } catch (_) {
      /* Show the browser alternative below. */
    }
    if (await _try(
      Uri.https('api.map.baidu.com', '/marker', {...params, 'output': 'html'}),
    )) {
      return NavigationOutcome.web;
    }
    return NavigationOutcome.unavailable;
  }
}
