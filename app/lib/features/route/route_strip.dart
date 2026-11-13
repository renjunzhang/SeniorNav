import 'package:flutter/material.dart';

import '../../route_summary.dart';

/// 竖向线路示意图：把一条公交/地铁方案画成「起点 → 步行 → 上车 → 乘车 →
/// 下车 →（换乘）→ 终点」的时间轴，替代文字步骤。
///
/// 只消费 [RouteSummary] 已有字段，不发起任何检索。字段缺失时降级为
/// 「以百度地图为准」或整行省略，不编造站名、方向与站数。
class RouteStrip extends StatelessWidget {
  const RouteStrip({
    super.key,
    required this.route,
    required this.destination,
    this.startLabel = '当前位置',
  });

  final RouteSummary route;
  final String destination;
  final String startLabel;

  static const _ink = Color(0xFF16335B);
  static const _sub = Color(0xFF4D5E73);
  static const _metroColor = Color(0xFF1465D8);
  static const _busColor = Color(0xFF0E7A3D);
  static const _walkColor = Color(0xFF8A97A8);
  static const _startColor = Color(0xFF0E7A3D);
  static const _endColor = Color(0xFFC62828);
  static const _transferColor = Color(0xFFB25E09);

  @override
  Widget build(BuildContext context) {
    final legs = route.legs;
    final trailingWalk =
        route.walkM - legs.fold<int>(0, (sum, l) => sum + l.boardWalkM);
    final dotCenterY = MediaQuery.textScalerOf(context).scale(23);

    final rows = <_StripRow>[
      _StripRow.node(
        dot: _DotKind.start,
        top: _LineKind.none,
        bottom: _LineKind.walk,
        content: _PlaceName(startLabel),
      ),
    ];
    for (var i = 0; i < legs.length; i++) {
      final leg = legs[i];
      final ride = switch (leg.lineType) {
        LineType.metro => _LineKind.metro,
        LineType.bus => _LineKind.bus,
        LineType.unknown => _LineKind.other,
      };
      if (leg.boardWalkM > 0) {
        rows.add(_StripRow.walk('步行${formatDistance(leg.boardWalkM)}'));
      }
      rows.add(
        _StripRow.node(
          dot: _DotKind.station,
          top: _LineKind.walk,
          bottom: ride,
          content: _StationName(tag: '上车站', name: leg.boardStop),
        ),
      );
      rows.add(
        _StripRow(
          top: ride,
          bottom: ride,
          dot: null,
          ticks: leg.stopCount == null ? 0 : (leg.stopCount! - 1).clamp(0, 15).toInt(),
          minHeight: 96,
          content: _RideInfo(leg: leg),
        ),
      );
      final isLast = i == legs.length - 1;
      rows.add(
        _StripRow.node(
          dot: _DotKind.station,
          top: ride,
          bottom: _LineKind.walk,
          content: _StationName(
            tag: isLast ? '下车站' : '下车 · 换乘',
            name: leg.alightStop,
            transfer: !isLast,
          ),
        ),
      );
    }
    if (trailingWalk > 0) {
      rows.add(_StripRow.walk('步行${formatDistance(trailingWalk)}'));
    }
    rows.add(
      _StripRow.node(
        dot: _DotKind.end,
        top: _LineKind.walk,
        bottom: _LineKind.none,
        content: _StationName(tag: '终点', name: destination, end: true),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++)
          _buildRow(rows[i], dotCenterY, isFirst: i == 0, isLast: i == rows.length - 1),
      ],
    );
  }

  Widget _buildRow(
    _StripRow row,
    double dotCenterY, {
    required bool isFirst,
    required bool isLast,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: SizedBox(
              width: 44,
              child: CustomPaint(
                painter: _RailPainter(
                  top: row.top,
                  bottom: row.bottom,
                  dot: row.dot,
                  ticks: row.ticks,
                  dotCenterY: dotCenterY,
                  startAtDot: isFirst,
                  endAtDot: isLast,
                ),
              ),
            ),
          ),
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: row.minHeight),
              child: Padding(
                padding: const EdgeInsets.only(left: 4, top: 6, bottom: 14),
                child: row.content,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DotKind { start, station, end }

enum _LineKind { none, walk, metro, bus, other }

class _StripRow {
  _StripRow({
    required this.top,
    required this.bottom,
    required this.content,
    required this.dot,
    this.ticks = 0,
    this.minHeight = 0,
  });

  _StripRow.node({
    required _DotKind dot,
    required _LineKind top,
    required _LineKind bottom,
    required Widget content,
  }) : this(dot: dot, top: top, bottom: bottom, content: content);

  _StripRow.walk(String text)
      : this(
          top: _LineKind.walk,
          bottom: _LineKind.walk,
          dot: null,
          content: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              text,
              style: const TextStyle(fontSize: 20, color: Color(0xFF52606D)),
            ),
          ),
        );

  final _LineKind top;
  final _LineKind bottom;
  final Widget content;
  final _DotKind? dot;
  final int ticks;
  final double minHeight;
}

class _PlaceName extends StatelessWidget {
  const _PlaceName(this.name);
  final String name;

  @override
  Widget build(BuildContext context) => Text(
    name,
    style: const TextStyle(
      fontSize: 25,
      fontWeight: FontWeight.w800,
      height: 1.35,
      color: RouteStrip._ink,
    ),
  );
}

class _StationName extends StatelessWidget {
  const _StationName({
    required this.tag,
    required this.name,
    this.transfer = false,
    this.end = false,
  });

  final String tag;
  final String? name;
  final bool transfer;
  final bool end;

  @override
  Widget build(BuildContext context) {
    final tagColor = transfer
        ? RouteStrip._transferColor
        : end
            ? RouteStrip._endColor
            : RouteStrip._metroColor;
    final tagBg = transfer
        ? const Color(0xFFFDEBD3)
        : end
            ? const Color(0xFFFDE7E7)
            : const Color(0xFFE7EFFB);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: tagBg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            tag,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: tagColor,
            ),
          ),
        ),
        if (name != null && name!.isNotEmpty)
          _PlaceName(name!)
        else
          const Text(
            '站名以百度地图为准',
            style: TextStyle(fontSize: 20, color: RouteStrip._sub),
          ),
      ],
    );
  }
}

class _RideInfo extends StatelessWidget {
  const _RideInfo({required this.leg});
  final TransitLeg leg;

  @override
  Widget build(BuildContext context) {
    final color = switch (leg.lineType) {
      LineType.metro => RouteStrip._metroColor,
      LineType.bus => RouteStrip._busColor,
      LineType.unknown => RouteStrip._ink,
    };
    final lineName = leg.lineName ??
        (leg.lineType == LineType.metro ? '地铁' : '公交');
    final direction = leg.direction;
    final stopCount = leg.stopCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          lineName,
          style: TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.w800,
            height: 1.35,
            color: color,
          ),
        ),
        if (direction != null && direction.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '开往 $direction',
              style: const TextStyle(fontSize: 20, color: RouteStrip._sub),
            ),
          ),
        if (stopCount != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text.rich(
              TextSpan(
                text: '坐 ',
                style: const TextStyle(fontSize: 21, color: RouteStrip._ink),
                children: [
                  TextSpan(
                    text: '$stopCount',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const TextSpan(text: ' 站'),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.top,
    required this.bottom,
    required this.dot,
    required this.ticks,
    required this.dotCenterY,
    required this.startAtDot,
    required this.endAtDot,
  });

  final _LineKind top;
  final _LineKind bottom;
  final _DotKind? dot;
  final int ticks;
  final double dotCenterY;
  final bool startAtDot;
  final bool endAtDot;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final y0 = startAtDot ? dotCenterY : 0.0;
    final y1 = endAtDot ? dotCenterY : size.height;
    if (dot == null) {
      _paintLine(canvas, x, y0, y1, top);
      if (ticks > 0 && y1 - y0 > 24) {
        final tickPaint = Paint()..color = Colors.white;
        for (var i = 0; i < ticks; i++) {
          final y = y0 + 10 + (y1 - y0 - 20) * (i + 1) / (ticks + 1);
          canvas.drawCircle(Offset(x, y), 3, tickPaint);
        }
      }
    } else {
      _paintLine(canvas, x, y0, dotCenterY, top);
      _paintLine(canvas, x, dotCenterY, y1, bottom);
    }
    switch (dot) {
      case _DotKind.start:
        canvas.drawCircle(
          Offset(x, dotCenterY),
          8,
          Paint()..color = RouteStrip._startColor,
        );
      case _DotKind.station:
        canvas.drawCircle(
          Offset(x, dotCenterY),
          9,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          Offset(x, dotCenterY),
          9,
          Paint()
            ..color = RouteStrip._ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5,
        );
      case _DotKind.end:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(x, dotCenterY),
              width: 16,
              height: 16,
            ),
            const Radius.circular(4),
          ),
          Paint()..color = RouteStrip._endColor,
        );
      case null:
        break;
    }
  }

  void _paintLine(Canvas canvas, double x, double from, double to, _LineKind kind) {
    if (kind == _LineKind.none || to <= from) return;
    switch (kind) {
      case _LineKind.walk:
        final paint = Paint()
          ..color = RouteStrip._walkColor
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        for (var y = from; y < to; y += 11) {
          canvas.drawLine(
            Offset(x, y),
            Offset(x, (y + 6).clamp(from, to).toDouble()),
            paint,
          );
        }
      case _LineKind.metro:
      case _LineKind.bus:
      case _LineKind.other:
        final color = switch (kind) {
          _LineKind.metro => RouteStrip._metroColor,
          _LineKind.bus => RouteStrip._busColor,
          _ => RouteStrip._ink,
        };
        canvas.drawLine(
          Offset(x, from),
          Offset(x, to),
          Paint()
            ..color = color
            ..strokeWidth = 9
            ..strokeCap = StrokeCap.round,
        );
      case _LineKind.none:
        break;
    }
  }

  @override
  bool shouldRepaint(_RailPainter oldDelegate) =>
      top != oldDelegate.top ||
      bottom != oldDelegate.bottom ||
      dot != oldDelegate.dot ||
      ticks != oldDelegate.ticks ||
      dotCenterY != oldDelegate.dotCenterY ||
      startAtDot != oldDelegate.startAtDot ||
      endAtDot != oldDelegate.endAtDot;
}