// Explicit, debug-only device smoke. Never imported by lib/main.dart.
// Uses public landmarks, no phone location, and at most five serial SDK calls.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/data/baidu_client.dart';
import 'package:seniornav/data/route_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('公共地标通道测试'))),
    ),
  );
  if (!kDebugMode || !const bool.fromEnvironment('RUN_LIVE_BAIDU_SMOKE')) {
    return;
  }
  var calls = 0;
  final client = BaiduClient(
    privacyAccepted: () => true,
    invoke: (method, args) async {
      if (method != 'initialize' && ++calls > 5) {
        throw const AppFailure('检索预算已用完，停止测试。');
      }
      return BaiduClient.channel.invokeMethod<Object?>(method, args);
    },
  );
  try {
    final poi = SdkPoiService(client);
    final candidates = await poi.search(query: '合肥火车站', city: '合肥');
    if (candidates.isEmpty) throw const AppFailure('公共地点搜索为空');
    debugPrint('SENIORNAV_SMOKE poi_search=ok count=${candidates.length}');
    final detail = await poi.detail(candidates.first);
    debugPrint(
      'SENIORNAV_SMOKE poi_detail=ok navigationPoint=${detail.navigationPoint != null}',
    );
    final destination = SavedPlace(
      id: 'public-smoke',
      slot: 0,
      label: '公共地标测试',
      icon: 'station',
      name: detail.name,
      address: detail.address,
      city: detail.city,
      latitude: detail.preferredPoint.latitude,
      longitude: detail.preferredPoint.longitude,
      poiUid: detail.uid,
      updatedAt: DateTime.now(),
      verifiedAt: DateTime.now(),
    );
    final result = await SdkRouteService(
      client,
      location: () async => const GeoPoint(31.805, 117.297),
    ).load(destination);
    if (result.metro == null || result.transit == null || result.walking == null) {
      throw const AppFailure('公共路线未完整返回');
    }
    final complete = [...result.metro!.legs, ...result.transit!.legs].every(
      (leg) =>
          leg.direction != null &&
          leg.boardStop != null &&
          leg.alightStop != null &&
          leg.stopCount != null,
    );
    debugPrint(
      'SENIORNAV_SMOKE routes=ok metroLegs=${result.metro!.legs.length} busLegs=${result.transit!.legs.length} fields=$complete',
    );
    debugPrint('SENIORNAV_SMOKE DONE calls=$calls blocked=${client.blocked}');
  } catch (_) {
    // No stack, raw native message, UID or location data in logs.
    debugPrint(
      'SENIORNAV_SMOKE FAILED calls=$calls blocked=${client.blocked} no_retry=true',
    );
  }
}
