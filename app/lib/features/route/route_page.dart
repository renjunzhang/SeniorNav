import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../route_summary.dart';

class RoutePage extends StatefulWidget {
  const RoutePage({super.key, required this.place, required this.services});
  final SavedPlace place;
  final AppServices services;

  @override
  State<RoutePage> createState() => _RoutePageState();
}

class _RoutePageState extends State<RoutePage> {
  RouteBundle? _bundle;
  RouteMode _mode = RouteMode.transit;
  bool _loading = false;
  bool _slow = false;
  bool _openingMap = false;
  String? _error;
  Timer? _slowTimer;
  Timer? _clockTimer;
  late bool _lastBusy;
  bool _lastStale = false;
  bool _waitingForPrevious = false;

  @override
  void initState() {
    super.initState();
    _lastBusy = widget.services.routes.busy;
    // Poll local state only: the shared service may finish an older page's
    // request after this page was opened. Never turn this into an auto-query.
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final busy = widget.services.routes.busy;
      final stale = _bundle != null && _isStale(_bundle!, DateTime.now());
      if (busy == _lastBusy && stale == _lastStale) return;
      setState(() {
        _lastBusy = busy;
        _lastStale = stale;
        if (!busy && _waitingForPrevious) {
          _waitingForPrevious = false;
          _error = '可以重新查询路线，或直接打开百度地图。';
        }
      });
    });
    _load();
  }

  Future<void> _load() async {
    if (_loading || widget.services.routes.busy) {
      if (mounted) {
        setState(() {
          _waitingForPrevious = !_loading;
          _lastBusy = widget.services.routes.busy;
          _error = '上一条查询仍在处理，请稍候。也可以直接打开百度地图。';
        });
      }
      return;
    }
    if (!widget.services.places.privacyAccepted) {
      setState(() => _error = '请先让家人确认位置与路线查询说明。');
      return;
    }
    setState(() {
      _loading = true;
      _slow = false;
      _error = null;
      _bundle = null;
      _waitingForPrevious = false;
      _lastStale = false;
    });
    _slowTimer?.cancel();
    _slowTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _loading) setState(() => _slow = true);
    });
    try {
      final result = await widget.services.routes.load(widget.place);
      if (!mounted) return;
      setState(() {
        _bundle = result;
        _mode = result.recommendedMode;
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is AppFailure ? error.message : '暂时查不到路线，请打开百度地图。',
      );
    } finally {
      _slowTimer?.cancel();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openMap() async {
    if (_openingMap) return;
    setState(() => _openingMap = true);
    try {
      final bundle = _bundle;
      final freshOrigin = bundle != null && !_isStale(bundle, DateTime.now())
          ? bundle.origin
          : null;
      final outcome = await widget.services.navigation.open(
        widget.place,
        _mode,
        origin: freshOrigin,
      );
      if (!mounted) return;
      final message = switch (outcome) {
        NavigationOutcome.nativeApp => null,
        NavigationOutcome.web => '已打开网页版。如需选择起点，请让家人协助；也可在手机应用商店安装或更新百度地图。',
        NavigationOutcome.unavailable => '暂时无法打开地图。请让家人在手机应用商店安装或更新百度地图后再试。',
      };
      if (message != null) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              outcome == NavigationOutcome.web ? '已打开网页版' : '请检查百度地图',
            ),
            scrollable: true,
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('暂时无法打开地图，请让家人检查百度地图是否安装。'),
          duration: Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingMap = false);
    }
  }

  bool _isStale(RouteBundle bundle, DateTime now) =>
      now.difference(bundle.fetchedAt) > const Duration(minutes: 5);

  @override
  void dispose() {
    _slowTimer?.cancel();
    _clockTimer?.cancel();
    // Leaving this page does not release the shared request lock or retry.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    final route = _mode == RouteMode.transit
        ? bundle?.transit
        : bundle?.walking;
    final modeMessage = _mode == RouteMode.transit
        ? bundle?.transitMessage
        : bundle?.walkingMessage;
    final now = DateTime.now();
    final summary = route == null ? null : renderSummary(route, now: now);
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 80,
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text('出行路线'),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          widget.place.label,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF16335B),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _ModeButton(
                                mode: RouteMode.transit,
                                selected: _mode == RouteMode.transit,
                                recommended:
                                    bundle?.recommendedMode ==
                                    RouteMode.transit,
                                onTap: () =>
                                    setState(() => _mode = RouteMode.transit),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _ModeButton(
                                mode: RouteMode.walking,
                                selected: _mode == RouteMode.walking,
                                recommended:
                                    bundle?.recommendedMode ==
                                    RouteMode.walking,
                                onTap: () =>
                                    setState(() => _mode = RouteMode.walking),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        if (_loading)
                          _NoticeCard(
                            icon: Icons.hourglass_top_rounded,
                            title: _slow ? '仍在查询…' : '正在查找路线…',
                            message: _slow
                                ? '查询需要一点时间。你可以继续等待，也可以直接打开百度地图。'
                                : '正在获取当前位置和出行方案，请稍候。',
                          )
                        else if (_error != null)
                          _NoticeCard(
                            icon: Icons.info_outline_rounded,
                            title: '暂时无法显示路线',
                            message: _error!,
                          )
                        else if (summary != null) ...[
                          _SummaryCard(route: route!, summary: summary),
                          for (final warning in summary.warnings) ...[
                            const SizedBox(height: 14),
                            _NoticeCard(
                              icon: Icons.info_outline_rounded,
                              title: '出发前请注意',
                              message: warning,
                              warning: true,
                            ),
                          ],
                          if (modeMessage != null) ...[
                            const SizedBox(height: 14),
                            _NoticeCard(
                              icon: Icons.info_outline_rounded,
                              title: '路线提示',
                              message: modeMessage,
                            ),
                          ],
                        ] else
                          _NoticeCard(
                            icon: _mode == RouteMode.transit
                                ? Icons.directions_bus_rounded
                                : Icons.directions_walk_rounded,
                            title:
                                '暂时没有${_mode == RouteMode.transit ? '公交' : '步行'}方案',
                            message: modeMessage ?? '可以切换出行方式，或打开百度地图查看。',
                          ),
                        if (bundle != null) ...[
                          const SizedBox(height: 20),
                          if (now.difference(bundle.fetchedAt) >
                              const Duration(minutes: 5))
                            const Text(
                              '路线已超过 5 分钟，请重新查询。',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF805000),
                              ),
                            ),
                          Text(
                            '查询时间 ${_time(bundle.fetchedAt)}',
                            style: const TextStyle(
                              fontSize: 18,
                              color: Color(0xFF4D5E73),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        const Text(
                          '路线以百度地图为准',
                          style: TextStyle(
                            fontSize: 18,
                            color: Color(0xFF4D5E73),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xFFDFE7F2))),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton(
                          key: const ValueKey('open-map'),
                          onPressed: _openingMap ? null : _openMap,
                          child: Text(
                            _openingMap ? '正在打开…' : '打开地图导航',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('refresh-routes'),
                          onPressed: _loading || widget.services.routes.busy
                              ? null
                              : _load,
                          child: Text(
                            _loading || widget.services.routes.busy
                                ? '查询中，请稍候'
                                : '重新查询',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.selected,
    required this.recommended,
    required this.onTap,
  });
  final RouteMode mode;
  final bool selected;
  final bool recommended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label:
        '${mode == RouteMode.transit ? '坐公交' : '走路'}${recommended ? '，推荐' : ''}',
    excludeSemantics: true,
    onTap: onTap,
    child: Material(
      color: selected ? const Color(0xFF1465D8) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? const Color(0xFF1465D8) : const Color(0xFF52749D),
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 88),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mode == RouteMode.transit ? '坐公交' : '走路',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : const Color(0xFF16335B),
                  ),
                ),
                if (recommended)
                  Text(
                    '推荐',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : const Color(0xFF16335B),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.route, required this.summary});
  final RouteSummary route;
  final SummaryText summary;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFD4E1F2)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          summary.headline,
          style: const TextStyle(
            fontSize: 28,
            height: 1.35,
            fontWeight: FontWeight.w800,
            color: Color(0xFF16335B),
          ),
        ),
        if (summary.emphasis != null) ...[
          const SizedBox(height: 14),
          Text(
            summary.emphasis!,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1453A1),
            ),
          ),
        ],
        if (route.isTransit) ...[
          const SizedBox(height: 12),
          Text(
            '全程${formatDistance(route.distanceM)}',
            style: const TextStyle(fontSize: 20, color: Color(0xFF4D5E73)),
          ),
        ],
        for (final step in summary.steps) ...[
          const SizedBox(height: 22),
          Text(
            step,
            style: const TextStyle(
              fontSize: 23,
              height: 1.55,
              color: Color(0xFF20334D),
            ),
          ),
        ],
      ],
    ),
  );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.message,
    this.warning = false,
  });
  final IconData icon;
  final String title;
  final String message;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: warning ? const Color(0xFFFFF0D5) : const Color(0xFFE7EFFB),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 34,
          color: warning ? const Color(0xFF805000) : const Color(0xFF1453A1),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(message, style: const TextStyle(fontSize: 21, height: 1.5)),
      ],
    ),
  );
}
