/// 读入待测点，输出 coordtransform_dart 的转换结果，供 crosscheck.py 与官方接口比对。
///
/// 用法：dart run bin/convert.dart <points.json> <out.json>
/// points.json 形如 [{"id":"…","wgs84":[lng,lat],"gcj02":[lng,lat]}, …]，
/// 两个坐标数组都可缺省，缺省的那一项不算。
library;

import 'dart:convert';
import 'dart:io';

import 'package:coordtransform_dart/coordtransform_dart.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('用法: dart run bin/convert.dart <points.json> <out.json>');
    exit(64);
  }
  final points = jsonDecode(File(args[0]).readAsStringSync()) as List<dynamic>;
  final out = <Map<String, dynamic>>[];
  for (final raw in points) {
    final p = raw as Map<String, dynamic>;
    final row = <String, dynamic>{'id': p['id']};
    final wgs = p['wgs84'];
    if (wgs is List) {
      final lng = (wgs[0] as num).toDouble();
      final lat = (wgs[1] as num).toDouble();
      final bd = CoordinateTransformUtil.wgs84ToBd09(lng, lat);
      row['wgs84ToBd09'] = bd;
      row['wgs84ToGcj02'] = CoordinateTransformUtil.wgs84ToGcj02(lng, lat);
      // 境外点包会原样返回（不转换）。只用公开 API 判断，不碰 @internal 的 isInChina。
      row['passthrough'] = bd[0] == lng && bd[1] == lat;
    }
    final gcj = p['gcj02'];
    if (gcj is List) {
      row['gcj02ToBd09'] = CoordinateTransformUtil.gcj02ToBd09(
        (gcj[0] as num).toDouble(),
        (gcj[1] as num).toDouble(),
      );
    }
    out.add(row);
  }
  File(args[1]).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  stdout.writeln('已写出 ${out.length} 个点的转换结果 -> ${args[1]}');
}