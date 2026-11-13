import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'baidu_uri.dart';
import 'probe_places.dart';

/// M0 技术探针。目的是在真机上测出三个问题的答案，不是交付界面：
/// 1) 公交能否一次点击直达合适的线路详情
/// 2) 步行能否直接启动语音导航
/// 3) 回家最少需要几次点击
///
/// 地点数据见 probe_places.dart：真实坐标由 tools/build_probe.sh 构建期注入，
/// 仓库里只有虚构示例点。

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SeniorNav M0',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF1565C0)),
      home: const ProbePage(),
    );
  }
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  String _lastUri = '';
  String _lastResult = '';
  bool _simulateNotInstalled = false;
  bool _baiduInstalled = true;

  /// 调起失败时可点的网页兜底，避免停在「什么都不发生」的界面上。
  Uri? _rescueUri;

  @override
  void initState() {
    super.initState();
    _detectBaiduMap();
  }

  Future<void> _detectBaiduMap() async {
    final ok = await canLaunchUrl(Uri.parse('baidumap://map/direction'));
    if (mounted) setState(() => _baiduInstalled = ok);
  }

  /// [to] 是本次探针的真实目标，网页回退必须用它而不是固定的「家」，
  /// 否则测其他地点时会回退到错误对象。
  Future<void> _launch(String label, Destination to, Uri uri, {String? mode}) async {
    final useWeb = _simulateNotInstalled || !_baiduInstalled;
    // direction 的 mode 已在 query 里，直接取；walknavi 没有该参数，由调用方显式给。
    final rescue = webFallback(
      to,
      mode: mode ?? uri.queryParameters['mode'],
      origin: originMyLocation,
    );
    final target = useWeb ? rescue : uri;
    setState(() {
      _lastUri = target.toString();
      _lastResult = '正在调起…';
      _rescueUri = null;
    });

    try {
      final ok = await launchUrl(target, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      setState(() {
        _lastResult = ok
            ? '[$label] 调起成功${useWeb ? "（走网页回退）" : ""} —— 请记录到看见目标界面点了几次'
            : '[$label] 调起返回 false，未离开 App';
        if (!ok && !useWeb) _rescueUri = rescue;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastResult = '[$label] 调起抛异常：$e';
        if (!useWeb) _rescueUri = rescue;
      });
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what 已复制')));
  }

  /// 录屏之外的可追溯记录：系统版本、时间、注入状态。
  /// 刻意不含坐标与 UID，复制出来的内容可以直接写进 docs/m0/。
  /// 机型取不到（那需要 device_info_plus 插件），记录时手动补一行。
  String get _envInfo => [
        'model=<手动填写机型>',
        'time=${DateTime.now().toIso8601String()}',
        'os=${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        'baiduDetected=$_baiduInstalled',
        'placesInjected=$placesInjected',
        'lastUri=${_lastUri.isEmpty ? "(none)" : "<含坐标，另行脱敏>"}',
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SeniorNav M0 探针'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(32),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _baiduInstalled ? '百度地图：已检测到' : '百度地图：未检测到（canLaunchUrl=false）',
                  style: TextStyle(
                    fontSize: 16,
                    color: _baiduInstalled ? Colors.green.shade700 : Colors.red.shade700,
                  ),
                ),
                const SizedBox(width: 12),
                const Text('模拟未安装', style: TextStyle(fontSize: 16)),
                Switch(
                  value: _simulateNotInstalled,
                  onChanged: (v) => setState(() => _simulateNotInstalled = v),
                ),
              ],
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!placesInjected)
            const _Note(
              '当前使用虚构示例点：真实坐标未注入。'
              '请用 tools/build_probe.sh 构建后再做精度相关的结论；'
              '仅验证「能否调起百度地图」时示例点也够用。',
            ),
          _section('M0-4 一键回家（最少点击路径）'),
          _bigButton('回家 · 公交', () => _launch(
                '回家公交',
                places.home,
                direction(
                  destination: places.home,
                  mode: 'transit',
                  origin: originMyLocation,
                  sy: 3,
                  enterLineDetail: true,
                ),
              )),
          _bigButton('回家 · 步行语音导航', () => _launch(
                '回家步行',
                places.homeGate,
                walkNavi(origin: places.walkOrigin, destination: places.homeGate),
                mode: 'walking',
              )),
          const _Note(
            '两个大按钮都是「一次点击」路径。公交走 direction 并带 index/target 尝试直达线路详情；'
            '步行走 walknavi，预期直接进入步行导航界面，但是否自动开始语音播报待真机确认。',
          ),
          const Divider(height: 40),
          _section('origin 三种写法（决定 V1 要不要定位权限）'),
          _probe('O1 省略 origin', places.home, direction(
            destination: places.home,
            mode: 'transit',
            enterLineDetail: true,
          )),
          _probe('O2 origin=我的位置', places.home, direction(
            destination: places.home,
            mode: 'transit',
            origin: originMyLocation,
            enterLineDetail: true,
          )),
          _probe('O3 origin=显式经纬度', places.home, direction(
            destination: places.home,
            mode: 'transit',
            origin: baiduLatLng(
              places.walkOrigin.latitude!,
              places.walkOrigin.longitude!,
            ),
            enterLineDetail: true,
          )),
          const _Note(
            '官方文档把 origin 标为必选。三者哪个能让百度自己取到手机当前位置，'
            '直接决定 V1 是否必须申请定位权限。O3 借用小区另一个门的坐标冒充当前位置，'
            '只为验证参数被接受，不代表真实起点。',
          ),
          const Divider(height: 40),
          _section('M0-2 公交：哪种参数组合点击次数最少'),
          _probe('A 仅名称（无 uid 无坐标）', places.homeNameOnly,
              direction(destination: places.homeNameOnly, mode: 'transit')),
          _probe('B 父 POI uid + navi_location', places.home,
              direction(destination: places.home, mode: 'transit')),
          _probe('C B+直达线路详情(index=0&target=1)', places.home, direction(
            destination: places.home,
            mode: 'transit',
            enterLineDetail: true,
          )),
          _probe('D C+少步行(sy=3)', places.home, direction(
            destination: places.home,
            mode: 'transit',
            sy: 3,
            enterLineDetail: true,
          )),
          _probe("D' C+推荐(sy=0)", places.home, direction(
            destination: places.home,
            mode: 'transit',
            sy: 0,
            enterLineDetail: true,
          )),
          _probe('E src 前缀用 webapp.（验证文档规则与示例不一致）', places.home, direction(
            destination: places.home,
            mode: 'transit',
            enterLineDetail: true,
            src: srcWebapp,
          )),
          _probe('F 终点用门的子 POI（对比父 uid 是否已足够）', places.homeGate, direction(
            destination: places.homeGate,
            mode: 'transit',
            enterLineDetail: true,
          )),
          _probe('G 名称含竖线冒号（验证 name:|latlng: 会不会被解析错）', places.homeNameOnly, direction(
            destination: const Destination(name: '测试|名称:含/特殊字符', region: '合肥'),
            mode: 'transit',
          )),
          const Divider(height: 40),
          _section('M0-3 步行：能否直接开始语音导航'),
          _probe('H walknavi 不带 mode（照官方示例）', places.homeGate, walkNavi(
            origin: places.walkOrigin,
            destination: places.homeGate,
          ), mode: 'walking'),
          _probe('I walknavi 带 mode=walking（文档标为必选但示例未给）', places.homeGate, walkNavi(
            origin: places.walkOrigin,
            destination: places.homeGate,
            includeMode: true,
          ), mode: 'walking'),
          _probe('J walknavi 省略 origin（若百度自动取当前位置，V1 就无需定位权限）',
              places.homeGate, walkNavi(destination: places.homeGate), mode: 'walking'),
          _probe('K walknavi 终点用 POI 几何中心（对照：是否偏离主要出入口）',
              places.homeCentroid, walkNavi(
            origin: places.walkOrigin,
            destination: places.homeCentroid,
          ), mode: 'walking'),
          _probe('L walknavi 同一坐标但 coord_type=wgs84（故意错配，量出坐标系混用的偏移）',
              places.homeGate, walkNavi(
            origin: places.walkOrigin,
            destination: places.homeGate,
            coordType: 'wgs84',
          ), mode: 'walking'),
          _probe('M direction+mode=walking（对照组，预期仅到路线规划页）', places.homeGate, direction(
            destination: places.homeGate,
            mode: 'walking',
          )),
          const _Note(
            '起点与终点取自同一小区的两个真实出入口，坐标由百度返回，非手写换算。'
            'K 是关键对照：几何中心一般落在小区内部，若导航终点跟着偏，'
            '说明数据模型必须存 navi_location 而不是 location。'
            'L 用错误坐标系是故意的，量出的偏移就是 P0-3「坐标混用」的代价。',
          ),
          const Divider(height: 40),
          _section('最近一次调起'),
          if (placesInjected)
            const _Note('下面的 URI 含真实坐标，记录到文档或截图前必须先脱敏。'),
          SelectableText(_lastUri.isEmpty ? '（尚无）' : _lastUri, style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 8),
          Text(_lastResult.isEmpty ? '（尚无）' : _lastResult,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.tonal(
              onPressed: _lastUri.isEmpty ? null : () => _copy(_lastUri, 'URI'),
              child: const Text('复制 URI'),
            ),
            FilledButton.tonal(
              onPressed: () => _copy(_envInfo, '环境信息'),
              child: const Text('复制环境信息'),
            ),
            FilledButton.tonal(
              onPressed: _detectBaiduMap,
              child: const Text('重新检测百度地图'),
            ),
            if (_rescueUri != null)
              FilledButton(
                onPressed: () => launchUrl(_rescueUri!, mode: LaunchMode.externalApplication),
                child: const Text('改用网页打开'),
              ),
          ]),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(t, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      );

  Widget _bigButton(String label, VoidCallback onPressed) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          height: 88,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 32)),
            child: Text(label),
          ),
        ),
      );

  Widget _probe(String label, Destination to, Uri uri, {String? mode}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: OutlinedButton(
          onPressed: () => _launch(label, to, uri, mode: mode),
          style: OutlinedButton.styleFrom(
            textStyle: const TextStyle(fontSize: 18),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          child: Text(label),
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: TextStyle(fontSize: 15, color: Colors.grey.shade700)),
      );
}
