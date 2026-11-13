import 'package:flutter/services.dart';

import '../core/contracts.dart';

typedef NativeInvoke = Future<Object?> Function(
  String method,
  Map<String, Object?>? arguments,
);

/// All POI and route work shares one operation lock, including initialization.
/// A slow route remains in flight when the page is closed; no Dart timeout or retry.
class BaiduClient {
  BaiduClient({required this.privacyAccepted, NativeInvoke? invoke})
    : _invoke = invoke ?? _platformInvoke;

  static const channel = MethodChannel('seniornav/baidu');
  static Future<Object?> _platformInvoke(
    String method,
    Map<String, Object?>? args,
  ) => channel.invokeMethod<Object?>(method, args);

  final bool Function() privacyAccepted;
  final NativeInvoke _invoke;
  bool _active = false;
  bool _initialized = false;
  bool _blocked = false;
  bool get busy => _active || _blocked;
  bool get blocked => _blocked;

  Future<T> run<T>(Future<T> Function(BaiduSession session) action) async {
    if (!privacyAccepted()) throw const AppFailure('请先让家人确认位置与路线查询说明。');
    if (_blocked) throw const AppFailure('上一条查询尚未确认结束，请先打开百度地图。');
    if (_active) throw const AppFailure('上一条查询仍在处理，请稍候。');
    _active = true;
    try {
      if (!_initialized) {
        await _safeCall('initialize', {'privacyAccepted': true});
        _initialized = true;
      }
      return await action(BaiduSession._(_safeCall));
    } finally {
      _active = false;
    }
  }

  Future<Object?> _safeCall(String method, Map<String, Object?>? args) async {
    if (_blocked) throw const AppFailure('查询尚未确认结束，请先打开百度地图。');
    try {
      return await _invoke(method, args);
    } on PlatformException catch (error) {
      // Do not include native message/details: they may contain coordinates or AK.
      if (error.code == 'SESSION_BLOCKED' ||
          error.code == 'SDK_TIMEOUT' ||
          error.code == 'BUSY') {
        _blocked = true;
      }
      throw AppFailure(switch (error.code) {
        'PRIVACY_REQUIRED' => '请先让家人确认位置与路线查询说明。',
        'BUSY' => '上一条查询仍在处理，请稍候。',
        'SESSION_BLOCKED' || 'SDK_TIMEOUT' => '查询尚未确认结束，请先打开百度地图。',
        'AUTH_FAILED' || 'SDK_UNAVAILABLE' => '路线服务暂时不可用，请打开百度地图。',
        'POI_NOT_FOUND' => '没有找到这个地点，请换一个名称搜索。',
        _ => '暂时查不到结果，请稍后再试或打开百度地图。',
      });
    } on MissingPluginException {
      throw const AppFailure('当前设备暂不支持路线查询，请打开百度地图。');
    }
  }
}

class BaiduSession {
  BaiduSession._(this._invoke);
  final NativeInvoke _invoke;
  Future<Object?> call(String method, Map<String, Object?> args) =>
      _invoke(method, args);
}
