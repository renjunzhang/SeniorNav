/// M0 探针的地点数据。
///
/// 真实住址、精确坐标与 POI UID 属于私人信息，按 docs/GIT_COMMIT_RULES.md
/// §3.1–3.4 不得写入仓库，因此只能在构建期注入：
///
///   tools/build_probe.sh      # 读取 tools/.env.places（已 gitignore）
///
/// 未注入时使用本文件的虚构示例点。App 照样能编译、能跑、能调起百度地图，
/// 但目的地是示例位置，不能用来判断「入口是否正确」这类精度结论。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'baidu_uri.dart';

const String _rawPlaces = String.fromEnvironment('PROBE_PLACES_JSON');

/// 注入成功才为 true。UI 据此显示提示，避免把示例点的结果当成真机结论。
bool get placesInjected => _rawPlaces.isNotEmpty;

final ProbePlaces places = _load();

ProbePlaces _load() {
  if (_rawPlaces.isEmpty) return const ProbePlaces.demo();
  try {
    final json = jsonDecode(_rawPlaces) as Map<String, dynamic>;
    return ProbePlaces(
      home: _point(json, 'home'),
      homeCentroid: _point(json, 'homeCentroid'),
      homeGate: _point(json, 'homeGate'),
      walkOrigin: _point(json, 'walkOrigin'),
      homeNameOnly: Destination(
        name: _string(json, 'home', 'name') ?? '示例小区',
        region: _string(json, null, 'region') ?? '合肥',
      ),
    );
  } catch (e) {
    // 格式错误时退回示例点并留痕，不让探针静默用错坐标得出假结论。
    debugPrint('PROBE_PLACES_JSON 解析失败，已回退到示例点：$e');
    return const ProbePlaces.demo();
  }
}

Destination _point(Map<String, dynamic> json, String key) {
  final m = (json[key] as Map?)?.cast<String, dynamic>() ?? const {};
  final region = json['region'] as String?;
  return Destination(
    name: m['name'] as String? ?? '示例地点',
    uid: m['uid'] as String?,
    latitude: (m['lat'] as num?)?.toDouble(),
    longitude: (m['lng'] as num?)?.toDouble(),
    region: region,
  );
}

String? _string(Map<String, dynamic> json, String? key, String field) {
  if (key == null) return json[field] as String?;
  final m = (json[key] as Map?)?.cast<String, dynamic>();
  return m?[field] as String?;
}

class ProbePlaces {
  const ProbePlaces({
    required this.home,
    required this.homeCentroid,
    required this.homeGate,
    required this.walkOrigin,
    required this.homeNameOnly,
  });

  /// 父 POI：uid + 百度指定的导航终点 navi_location。
  final Destination home;

  /// POI 几何中心。与 [homeGate] 的距离用于验证「存 location 还是 navi_location」。
  final Destination homeCentroid;

  /// 主要人行出入口（pv_rate 最高的那个门）。步行导航应落到这里。
  final Destination homeGate;

  /// 步行导航起点。真机上本应是老人当前位置；M0 未接定位，用邻近真实点代替。
  final Destination walkOrigin;

  /// 只有名称、没有 uid 与坐标，用于对比纯名称检索会落到哪里。
  final Destination homeNameOnly;

  /// 未注入时的虚构示例点。坐标一律只给 2 位小数（约 1km 精度）：
  /// 真实百度坐标有 14 位小数，测试会以此判断有没有人把真实数据写回本文件
  /// （docs/GIT_COMMIT_RULES.md §3.1–3.4）。
  const ProbePlaces.demo()
      : home = const Destination(
          name: '示例小区',
          latitude: 31.86,
          longitude: 117.28,
          region: '合肥',
        ),
        homeCentroid = const Destination(
          name: '示例小区',
          latitude: 31.87,
          longitude: 117.29,
          region: '合肥',
        ),
        homeGate = const Destination(
          name: '示例小区-西门',
          latitude: 31.85,
          longitude: 117.27,
          region: '合肥',
        ),
        walkOrigin = const Destination(
          name: '示例起点',
          latitude: 31.88,
          longitude: 117.3,
          region: '合肥',
        ),
        homeNameOnly = const Destination(name: '示例小区', region: '合肥');
}
