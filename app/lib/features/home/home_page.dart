import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../places/family_settings_page.dart';
import '../route/route_page.dart';

const _defaultLabels = ['回家', '去家人家', '医院', '超市'];
const _tileLabelStyle = TextStyle(
  fontSize: 30,
  height: 1.2,
  fontWeight: FontWeight.w700,
  color: Color(0xFF172A43),
);
const _headerStyle = TextStyle(
  fontSize: 26,
  height: 1.2,
  fontWeight: FontWeight.w600,
  color: Color(0xFF53657D),
);
const _tripTitleStyle = TextStyle(
  fontSize: 26,
  height: 1.2,
  fontWeight: FontWeight.w700,
  color: Color(0xFF12623E),
);
const _tripSubStyle = TextStyle(
  fontSize: 20,
  height: 1.4,
  color: Color(0xFF53657D),
);
const _slotIcons = [
  Icons.home_rounded,
  Icons.favorite_rounded,
  Icons.local_hospital_rounded,
  Icons.shopping_cart_rounded,
];
const _tileColors = [
  Color(0xFFE0F3E9),
  Color(0xFFFFE7EB),
  Color(0xFFE0EDFF),
  Color(0xFFFFF0D5),
  Color(0xFFEBE5FA),
];
const _inkColors = [
  Color(0xFF12623E),
  Color(0xFFA32046),
  Color(0xFF1453A1),
  Color(0xFF805000),
  Color(0xFF584197),
];

IconData placeIcon(String name, int slot) => switch (name) {
  'home' => Icons.home_rounded,
  'family' || 'favorite' => Icons.favorite_rounded,
  'hospital' => Icons.local_hospital_rounded,
  'shop' || 'shopping' || 'supermarket' => Icons.shopping_cart_rounded,
  'park' => Icons.park_rounded,
  'restaurant' => Icons.restaurant_rounded,
  'station' => Icons.train_rounded,
  'place' => Icons.place_rounded,
  _ => slot >= 1 && slot <= 4 ? _slotIcons[slot - 1] : Icons.place_rounded,
};

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.services});
  final AppServices services;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DateTime? _lastTitleTap;
  int _titleTaps = 0;
  bool _opening = false;
  bool _tripBusy = false;
  ActiveTrip? _trip;

  @override
  void initState() {
    super.initState();
    _refreshTrip();
  }

  Future<void> _refreshTrip() async {
    final trip = await widget.services.trip.readTrip();
    if (!mounted) return;
    setState(() => _trip = trip);
  }

  void _titleTapped() {
    final now = DateTime.now();
    if (_lastTitleTap == null ||
        now.difference(_lastTitleTap!) > const Duration(milliseconds: 1200)) {
      _titleTaps = 0;
    }
    _lastTitleTap = now;
    if (++_titleTaps == 3) {
      _titleTaps = 0;
      _openSettings();
    }
  }

  Future<void> _openSettings() async {
    if (_opening) return;
    _opening = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FamilySettingsPage(services: widget.services),
      ),
    );
    _opening = false;
    // 家属可能改了地点位置或删除了地点，行程已在仓库里清除，横幅必须跟着刷新。
    if (mounted) await _refreshTrip();
  }

  Future<void> _select(SavedPlace? place) async {
    if (_opening) return;
    _opening = true;
    try {
      if (place == null) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('这个地点还没设置'),
            content: const Text('请让家人连续点按首页顶部“回家”标题三次，设置好地点后再出发。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
        return;
      }
      if (!widget.services.places.privacyAccepted) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('查询路线前，请先确认'),
            scrollable: true,
            content: const Text(
              '只在你查询路线时获取一次当前位置，并将起点和目的地交给百度地图查询。\n\n常用地点和上次查到的路线仅保存在这台手机，不持续定位、不记录行踪。请家人协助阅读并确认。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('暂不查询'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('同意并查询'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        try {
          await widget.services.places.acceptPrivacy();
        } catch (_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('未能保存，请稍后再试')));
          return;
        }
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RoutePage(place: place, services: widget.services),
        ),
      );
      if (mounted) await _refreshTrip();
    } finally {
      _opening = false;
    }
  }

  Future<void> _endTripFromHome(SavedPlace place) async {
    if (_tripBusy) return;
    _tripBusy = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('结束行程？'),
          content: Text('确定已结束去「${place.label}」的行程？结束后首页不再显示这条行程。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('结束行程'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await widget.services.trip.endTrip();
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('行程没有结束成功，请稍后再试。')),
        );
      }
      if (mounted) await _refreshTrip();
    } finally {
      _tripBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListenableBuilder(
            listenable: widget.services.places,
            builder: (context, _) => LayoutBuilder(
              builder: (context, constraints) {
                final textScale = MediaQuery.textScalerOf(context).scale(1);
                final header = _header();
                final trip = _trip;
                SavedPlace? tripPlace;
                if (trip != null) {
                  for (final item in widget.services.places.places) {
                    if (item.id == trip.placeId && item.deletedAt == null) {
                      tripPlace = item;
                      break;
                    }
                  }
                }
                final banner = trip != null && tripPlace != null
                    ? _tripBanner(trip, tripPlace)
                    : null;
                final tiles = List<_HomeTile>.generate(5, (index) {
                  SavedPlace? place;
                  if (index < 4) {
                    for (final item in widget.services.places.places) {
                      if (item.slot == index + 1 && item.deletedAt == null) {
                        place = item;
                        break;
                      }
                    }
                  }
                  final selected = place;
                  return _HomeTile(
                    key: ValueKey('home-slot-${index + 1}'),
                    label: index == 4
                        ? '更多地点'
                        : selected?.label ?? _defaultLabels[index],
                    icon: index == 4
                        ? Icons.grid_view_rounded
                        : placeIcon(selected?.icon ?? '', index + 1),
                    color: _tileColors[index],
                    inkColor: _inkColors[index],
                    onTap: index == 4
                        ? () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => MorePlacesPage(
                                  services: widget.services,
                                  onSelect: _select,
                                ),
                              ),
                            );
                            if (mounted) await _refreshTrip();
                          }
                        : () => _select(selected),
                  );
                });
                // Share remaining space at ordinary text sizes. Measure the
                // actual labels so narrow screens and long names can scroll
                // rather than squeezing text into an undersized fixed slot.
                final labelWidth = math.max(1.0, constraints.maxWidth - 138);
                final minTileHeight = tiles.fold<double>(80, (height, tile) {
                  return math.max(
                    height,
                    _textHeight(
                          context,
                          tile.label,
                          _tileLabelStyle,
                          labelWidth,
                        ) +
                        24,
                  );
                });
                final headerHeight = math.max(
                  56.0,
                  _textHeight(
                        context,
                        '回家',
                        _headerStyle,
                        math.max(1.0, constraints.maxWidth - 40),
                      ) +
                      16,
                );
                // 行程横幅占用的高度从按钮空间里扣除；宁可高估让页面滚动，
                // 也不把五个入口挤扁。无行程时高度为 0，布局与之前完全一致。
                final bannerHeight = banner == null
                    ? 0.0
                    : 32 +
                          4 +
                          12 +
                          12 +
                          math.max(
                            32.0,
                            _textHeight(
                              context,
                              '正在去 ${tripPlace!.label}',
                              _tripTitleStyle,
                              labelWidth,
                            ),
                          ) +
                          _textHeight(
                            context,
                            _tripSubtitle(trip!),
                            _tripSubStyle,
                            labelWidth,
                          ) +
                          math.max(72.0, 28.8 * textScale + 36);
                final availableTileHeight =
                    (constraints.maxHeight -
                        28 -
                        headerHeight -
                        12 -
                        48 -
                        bannerHeight) /
                    5;
                final scroll =
                    textScale > 1.35 || availableTileHeight < minTileHeight;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: scroll
                      ? SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              header,
                              const SizedBox(height: 12),
                              if (banner != null) ...[
                                banner,
                                const SizedBox(height: 12),
                              ],
                              for (var i = 0; i < tiles.length; i++) ...[
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 88,
                                  ),
                                  child: tiles[i],
                                ),
                                if (i < tiles.length - 1)
                                  const SizedBox(height: 12),
                              ],
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            header,
                            const SizedBox(height: 12),
                            if (banner != null) ...[
                              banner,
                              const SizedBox(height: 12),
                            ],
                            for (var i = 0; i < tiles.length; i++) ...[
                              Expanded(child: tiles[i]),
                              if (i < tiles.length - 1)
                                const SizedBox(height: 12),
                            ],
                          ],
                        ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  double _textHeight(
    BuildContext context,
    String text,
    TextStyle style,
    double width,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  Widget _header() => GestureDetector(
    key: const ValueKey('family-entry'),
    behavior: HitTestBehavior.opaque,
    onTap: _titleTapped,
    child: Container(
      constraints: const BoxConstraints(minHeight: 56),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: const Text('回家', style: _headerStyle),
    ),
  );

  String _tripSubtitle(ActiveTrip trip) {
    final now = DateTime.now();
    final time = trip.startedAt;
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return '$clock 出发';
    }
    final date = time.year == now.year
        ? '${time.month}月${time.day}日'
        : '${time.year}年${time.month}月${time.day}日';
    return '$date $clock 出发';
  }

  Widget _tripBanner(ActiveTrip trip, SavedPlace place) => Material(
    color: const Color(0xFFE0F3E9),
    borderRadius: BorderRadius.circular(22),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.trip_origin_rounded,
                size: 32,
                color: Color(0xFF12623E),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('正在去 ${place.label}', style: _tripTitleStyle),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_tripSubtitle(trip), style: _tripSubStyle),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const ValueKey('trip-continue'),
                  onPressed: () => _select(place),
                  child: const Text('继续行程'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('trip-end'),
                  onPressed: () => _endTripFromHome(place),
                  child: const Text('结束行程'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _HomeTile extends StatelessWidget {
  const _HomeTile({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.inkColor,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final Color color;
  final Color inkColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: Material(
      color: color,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 40, color: inkColor),
                const SizedBox(width: 18),
                Expanded(child: Text(label, style: _tileLabelStyle)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class MorePlacesPage extends StatelessWidget {
  const MorePlacesPage({
    super.key,
    required this.services,
    required this.onSelect,
  });
  final AppServices services;
  final Future<void> Function(SavedPlace?) onSelect;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leadingWidth: 80,
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: const Text('更多地点'),
    ),
    body: ListenableBuilder(
      listenable: services.places,
      builder: (context, _) {
        final places =
            services.places.places
                .where((p) => p.slot == 0 && p.deletedAt == null)
                .toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        if (places.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(28),
            child: Text('还没有更多地点。\n请让家人在首页连续点按标题三次，添加常去的地方。'),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: places.length,
          separatorBuilder: (_, _) => const SizedBox(height: 14),
          itemBuilder: (context, index) => _HomeTile(
            label: places[index].label,
            icon: placeIcon(places[index].icon, 0),
            color: const Color(0xFFE0EDFF),
            inkColor: const Color(0xFF1453A1),
            onTap: () => onSelect(places[index]),
          ),
        );
      },
    ),
  );
}
