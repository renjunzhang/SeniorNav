import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/baidu_uri.dart';
import 'package:seniornav/probe_places.dart';

void main() {
  // 按 docs/GIT_COMMIT_RULES.md §3.1–3.4，测试一律使用虚构坐标，
  // 不得出现真实住址、精确坐标或 POI UID。这里只验证 URI 拼装规则。
  const home = Destination(
    name: '示例小区',
    uid: 'demo_uid_parent',
    latitude: 31.86,
    longitude: 117.28,
    region: '合肥',
  );
  const nameOnly = Destination(name: '示例小区', region: '合肥');
  const westGate = Destination(
    name: '示例小区-西门',
    uid: 'demo_uid_gate',
    latitude: 31.8598,
    longitude: 117.2795,
  );
  const northEastGate = Destination(
    name: '示例小区-东北门',
    uid: 'demo_uid_origin',
    latitude: 31.8612,
    longitude: 117.2812,
  );

  group('坐标顺序', () {
    test('百度要求先纬度后经度', () {
      expect(baiduLatLng(31.8598, 117.2795), '31.8598,117.2795');
    });

    test('walknavi 的起终点都是纬度在前', () {
      final uri = walkNavi(origin: northEastGate, destination: westGate);
      expect(uri.queryParameters['origin'], '31.8612,117.2812');
      expect(uri.queryParameters['destination'], '31.8598,117.2795');
    });

    test('首位数值小于 90，可捕获经纬度写反（中国经度约 117）', () {
      final uri = walkNavi(origin: northEastGate, destination: westGate);
      for (final key in ['origin', 'destination']) {
        final first = double.parse(uri.queryParameters[key]!.split(',')[0]);
        expect(first, lessThan(90), reason: '$key 首位应是纬度');
      }
    });
  });

  group('direction', () {
    test('必须显式携带 coord_type 与 mode，否则百度按 driving 处理', () {
      final uri = direction(destination: home, mode: 'walking');
      expect(uri.queryParameters['coord_type'], 'bd09ll');
      expect(uri.queryParameters['mode'], 'walking');
    });

    test('无坐标时 destination 只用名称，且不带 name: 前缀', () {
      final uri = direction(destination: nameOnly, mode: 'transit');
      expect(uri.queryParameters['destination'], '示例小区');
    });

    test('有坐标时 destination 组合名称与 latlng', () {
      final uri = direction(destination: home, mode: 'transit');
      expect(
        uri.queryParameters['destination'],
        'name:示例小区|latlng:31.86,117.28',
      );
    });

    test('携带 destination_uid', () {
      final uri = direction(destination: home, mode: 'transit');
      expect(uri.queryParameters['destination_uid'], 'demo_uid_parent');
    });

    test('未开启直达线路详情时不带 index/target', () {
      final uri = direction(destination: home, mode: 'transit');
      expect(uri.queryParameters.containsKey('index'), isFalse);
      expect(uri.queryParameters.containsKey('target'), isFalse);
    });

    test('开启直达线路详情时 index=0 且 target=1', () {
      final uri = direction(
        destination: home,
        mode: 'transit',
        enterLineDetail: true,
      );
      expect(uri.queryParameters['index'], '0');
      expect(uri.queryParameters['target'], '1');
    });

    test('中文与 scheme 在最终 URI 中被正确编码', () {
      final s = direction(destination: home, mode: 'transit').toString();
      expect(s, startsWith('baidumap://map/direction?'));
      expect(s, contains('%E7%A4%BA%E4%BE%8B%E5%B0%8F%E5%8C%BA'));
      expect(s, isNot(contains('示例小区')));
    });
  });

  group('walknavi', () {
    test('终点缺坐标时直接抛错，不允许静默降级成错误目的地', () {
      expect(
        () => walkNavi(origin: northEastGate, destination: nameOnly),
        throwsArgumentError,
      );
    });

    test('起点提供但缺坐标时同样抛错', () {
      expect(
        () => walkNavi(origin: nameOnly, destination: westGate),
        throwsArgumentError,
      );
    });

    test('省略起点时不带 origin 参数，用于验证百度是否自动取当前位置', () {
      final uri = walkNavi(destination: westGate);
      expect(uri.queryParameters.containsKey('origin'), isFalse);
      expect(uri.queryParameters['destination'], '31.8598,117.2795');
    });

    test('mode 默认不传，可按需附加', () {
      expect(
        walkNavi(origin: northEastGate, destination: westGate)
            .queryParameters
            .containsKey('mode'),
        isFalse,
      );
      expect(
        walkNavi(origin: northEastGate, destination: westGate, includeMode: true)
            .queryParameters['mode'],
        'walking',
      );
    });
  });

  group('网页回退', () {
    test('没有 mode 或 origin 时退回搜索页，而不是给出无效路线链接', () {
      final uri = webFallback(home);
      expect(uri.scheme, 'https');
      expect(uri.host, 'map.baidu.com');
      expect(uri.pathSegments, ['search', '示例小区', '']);
      expect(uri.toString(), contains('%E7%A4%BA%E4%BE%8B%E5%B0%8F%E5%8C%BA'));
      expect(uri.toString(), isNot(contains('%25')), reason: '双重编码会让回退链接 404');
    });

    test('有 mode 与 origin 时走官方 web 路线接口', () {
      final uri = webFallback(home, mode: 'transit', origin: originMyLocation);
      expect(uri.host, 'api.map.baidu.com');
      expect(uri.path, '/direction');
      expect(uri.queryParameters['origin'], '我的位置');
      expect(uri.queryParameters['mode'], 'transit');
      expect(uri.queryParameters['output'], 'html',
          reason: 'web 端必须 output=html 才会渲染地图产品结果');
      expect(uri.queryParameters['src'], srcWebapp);
      expect(uri.queryParameters['destination'], 'name:示例小区|latlng:31.86,117.28');
    });

    test('只给 mode 不给 origin 时仍退回搜索页', () {
      // 实测省略 origin 的 direction 会 302 到 map.baidu.com 首页，等于没有路线。
      expect(webFallback(home, mode: 'transit').host, 'map.baidu.com');
    });
  });

  group('origin', () {
    test('省略 origin 时不带该参数', () {
      expect(
        direction(destination: home, mode: 'transit').queryParameters.containsKey('origin'),
        isFalse,
      );
    });

    test('可以传字面量「我的位置」', () {
      expect(
        direction(destination: home, mode: 'transit', origin: originMyLocation)
            .queryParameters['origin'],
        '我的位置',
      );
    });

    test('可以传显式经纬度，且纬度在前', () {
      final uri = direction(
        destination: home,
        mode: 'transit',
        origin: baiduLatLng(31.8612, 117.2812),
      );
      expect(uri.queryParameters['origin'], '31.8612,117.2812');
    });
  });

  group('特殊字符', () {
    test('名称含竖线冒号斜杠时会被编码，不会破坏 name:|latlng: 结构', () {
      const odd = Destination(name: '测试|名称:含/特殊字符', latitude: 31.86, longitude: 117.28);
      final uri = direction(destination: odd, mode: 'transit');
      final s = uri.toString();
      expect(s, contains('%7C'), reason: '裸竖线会被百度当成 name:/latlng: 的分隔符');
      expect(s, contains('%3A'));
      // 解码后仍应还原成一个完整参数值，说明编码是可逆的
      expect(
        uri.queryParameters['destination'],
        'name:测试|名称:含/特殊字符|latlng:31.86,117.28',
      );
    });
  });

  group('探针地点数据', () {
    test('测试环境未注入真实坐标，示例点精度不超过 2 位小数', () {
      expect(placesInjected, isFalse, reason: '测试不应注入真实家庭坐标');
      final points = [
        places.home,
        places.homeCentroid,
        places.homeGate,
        places.walkOrigin,
      ];
      for (final d in points) {
        for (final v in [d.latitude!, d.longitude!]) {
          final decimals = v.toString().split('.').last.length;
          expect(decimals, lessThanOrEqualTo(2),
              reason: '${d.name} 的坐标过精，疑似把真实数据写回了仓库');
        }
      }
    });
  });
}
