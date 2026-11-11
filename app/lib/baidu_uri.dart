/// 百度地图 Android URI API 调起构造。
///
/// 官方文档: https://lbsyun.baidu.com/docs/webapi?title=mapadjustment/uri/andriod
library;

/// 调起来源。文档规则写作 webapp.companyName.appName，但 Android 端全部官方示例
/// 使用 andr. 前缀，两者不一致，需在真机上确认哪个被接受。
const String srcAndroid = 'andr.seniornav.mobile';
const String srcWebapp = 'webapp.seniornav.mobile';

/// 没有定位权限时，用字面量「我的位置」作为起点。
/// 实测 https://api.map.baidu.com/direction?origin=我的位置&mode=transit
/// 会 302 到 s=bt 的公交路线页，可用；而省略 origin 会 302 到首页，拿不到路线。
const String originMyLocation = '我的位置';

/// 一个已确认的目的地。
class Destination {
  const Destination({
    required this.name,
    this.uid,
    this.latitude,
    this.longitude,
    this.region,
  });

  final String name;

  /// POI ID。文档: 有 uid 参数终点会以出入口作为结束导航位置，体验更优。
  final String? uid;

  /// BD-09 纬度。
  final double? latitude;

  /// BD-09 经度。
  final double? longitude;

  final String? region;

  bool get hasLatLng => latitude != null && longitude != null;
}

/// 百度地图坐标顺序是「先纬度，后经度」，与常见的 lng,lat 相反。
/// 写反会把目的地定位到完全不同的地方，因此集中在此处构造。
String baiduLatLng(double latitude, double longitude) =>
    '$latitude,$longitude';

/// 终点参数：有坐标时名称与经纬度一起给，经纬度优先、名称只用于展示。
String destinationParam(Destination d) => d.hasLatLng
    ? 'name:${d.name}|latlng:${baiduLatLng(d.latitude!, d.longitude!)}'
    : d.name;

/// 未安装百度地图时的回退。bdapp:// 同样依赖客户端，因此一律走 https。
///
/// 有 mode 与 origin 时回退到官方 web 路线接口，能直接给出公交/步行方案；
/// 否则只能退回搜索页——web 路线接口的 origin 是必选，实测省略后 302 到
/// map.baidu.com 首页，老人什么路线都看不到。
Uri webFallback(
  Destination d, {
  String? mode,
  String? origin,
  String coordType = 'bd09ll',
  String src = srcWebapp,
}) {
  if (mode == null || origin == null) return webSearch(d);
  return Uri.https('api.map.baidu.com', '/direction', {
    'origin': origin,
    'destination': destinationParam(d),
    'mode': mode,
    'region': ?d.region,
    'coord_type': coordType,
    'output': 'html',
    'src': src,
  });
}

/// 搜索页回退。只是最后兜底：它不给路线，老人还得自己再点。
/// path 交给 Uri.https 编码，手动再 encodeComponent 会导致双重编码而 404。
Uri webSearch(Destination d) => Uri.https(
      'map.baidu.com',
      '/search/${d.name}/',
      {'querytype': 's', 'wd': d.name, 'from': 'webmap'},
    );

/// 公交/步行路线规划。mode 默认是 driving，必须显式传，否则老人点「步行」
/// 会得到驾车路线。
Uri direction({
  required Destination destination,
  required String mode,
  String coordType = 'bd09ll',
  String? origin,
  int? sy,
  bool enterLineDetail = false,
  String src = srcAndroid,
}) {
  return Uri.parse('baidumap://map/direction').replace(queryParameters: {
    'origin': ?origin,
    'destination': destinationParam(destination),
    'destination_uid': ?destination.uid,
    'coord_type': coordType,
    'mode': mode,
    'region': ?destination.region,
    if (sy != null) 'sy': '$sy',
    if (enterLineDetail) 'index': '0',
    if (enterLineDetail) 'target': '1',
    'src': src,
  });
}

/// 步行语音导航。终点必须是经纬度，不支持名称或 uid，因此这条路径依赖精确坐标。
///
/// origin 在文档中标为必选，但省略后百度是否自动采用手机当前位置尚未验证。
/// 这一点决定 V1 是否需要申请定位权限，因此保留省略起点的能力用于真机探针。
Uri walkNavi({
  Destination? origin,
  required Destination destination,
  String coordType = 'bd09ll',
  bool includeMode = false,
  String src = srcAndroid,
}) {
  if (!destination.hasLatLng) {
    throw ArgumentError('walknavi 终点必须提供经纬度');
  }
  String? originLatLng;
  if (origin != null) {
    if (!origin.hasLatLng) {
      throw ArgumentError('walknavi 起点若提供则必须含经纬度');
    }
    originLatLng = baiduLatLng(origin.latitude!, origin.longitude!);
  }
  return Uri.parse('baidumap://map/walknavi').replace(queryParameters: {
    'origin': ?originLatLng,
    'destination': baiduLatLng(destination.latitude!, destination.longitude!),
    'coord_type': coordType,
    if (includeMode) 'mode': 'walking',
    'src': src,
  });
}
