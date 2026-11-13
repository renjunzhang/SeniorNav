import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/contracts.dart';

const _slotLabels = ['更多地点', '回家', '去家人家', '医院', '超市'];
const _slotIcons = ['place', 'home', 'family', 'hospital', 'shop'];
const _icons = <String, (IconData, String)>{
  'home': (Icons.home_rounded, '家'),
  'family': (Icons.favorite_rounded, '家人'),
  'hospital': (Icons.local_hospital_rounded, '医院'),
  'shop': (Icons.shopping_cart_rounded, '商店'),
  'park': (Icons.park_rounded, '公园'),
  'place': (Icons.place_rounded, '地点'),
};

/// 标题隐藏入口进入此页后，仍须先通过家属 PIN。
class FamilySettingsPage extends StatefulWidget {
  const FamilySettingsPage({super.key, required this.services});
  final AppServices services;

  @override
  State<FamilySettingsPage> createState() => _FamilySettingsPageState();
}

class _FamilySettingsPageState extends State<FamilySettingsPage> {
  final _pin = TextEditingController();
  final _confirmPin = TextEditingController();
  bool _unlocked = false;
  bool _busy = false;
  String? _error;

  PlaceRepository get _places => widget.services.places;

  @override
  void dispose() {
    _pin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(
      () => _error = error is AppFailure ? error.message : '操作未完成，请稍后再试',
    );
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_places.hasPin) {
        if (!await _places.verifyPin(_pin.text)) {
          throw const AppFailure('家属密码不正确，请重新输入');
        }
      } else {
        if (_pin.text != _confirmPin.text) {
          throw const AppFailure('两次输入不一致，请重新输入');
        }
        await _places.setPin(_pin.text);
      }
      _pin.clear();
      _confirmPin.clear();
      if (mounted) setState(() => _unlocked = true);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _acceptPrivacy() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _places.acceptPrivacy();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit({SavedPlace? place, int slot = 0}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _PlaceEditor(
          services: widget.services,
          place: place,
          initialSlot: slot,
        ),
      ),
    );
  }

  Future<void> _delete(SavedPlace place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个地点？'),
        content: Text('“${place.label}”将不再出现在地点列表中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _places.deletePlace(place.id);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _move(List<SavedPlace> more, int from, int to) async {
    final ids = more.map((p) => p.id).toList();
    final id = ids.removeAt(from);
    ids.insert(to, id);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _places.reorderMore(ids);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => _ChangePinPage(repository: _places)),
    );
  }

  Widget _gate() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        _places.hasPin ? '请输入家属密码' : '先设置家属密码',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      const Text('使用 4 至 6 位数字，防止老人误改地点。这个密码不用于加密手机里的资料。'),
      const SizedBox(height: 24),
      _PinField(
        controller: _pin,
        label: _places.hasPin ? '家属密码' : '新密码',
        enabled: !_busy,
      ),
      if (!_places.hasPin) ...[
        const SizedBox(height: 16),
        _PinField(controller: _confirmPin, label: '再次输入新密码', enabled: !_busy),
      ],
      if (_error != null) _ErrorText(_error!),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _unlock,
        child: Text(_busy ? '请稍候…' : (_places.hasPin ? '进入家属设置' : '保存密码并继续')),
      ),
    ],
  );

  Widget _privacy() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('使用前请家属确认', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
      const Text(
        '常用地点只保存在这部手机。点击出行地点时，会申请一次当前位置，用于向百度查询路线；不会在后台持续定位。\n\n搜索地点和查询路线需要连接百度服务，地点或起终点会发送给百度处理。打开百度地图后，导航由百度地图提供。\n\n请确认老人知情并同意，再启用这些功能。',
      ),
      if (_error != null) _ErrorText(_error!),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _acceptPrivacy,
        child: const Text('已了解，同意使用'),
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('暂不使用'),
      ),
    ],
  );

  Widget _management() {
    final more = _places.places.where((p) => p.slot == 0).toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('首页常用地点', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('首页位置固定。家的地址可以修改，回家按钮不能删除。'),
        const SizedBox(height: 16),
        for (var slot = 1; slot <= 4; slot++) _homeSlot(slot),
        const SizedBox(height: 24),
        Text('更多地点', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        if (more.isEmpty) const Text('还没有添加更多地点。'),
        for (var i = 0; i < more.length; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    more[i].label,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(more[i].name),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _busy ? null : () => _edit(place: more[i]),
                        child: const Text('修改'),
                      ),
                      OutlinedButton(
                        onPressed: _busy || i == 0
                            ? null
                            : () => _move(more, i, i - 1),
                        child: const Text('上移'),
                      ),
                      OutlinedButton(
                        onPressed: _busy || i == more.length - 1
                            ? null
                            : () => _move(more, i, i + 1),
                        child: const Text('下移'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _delete(more[i]),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : () => _edit(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加更多地点'),
        ),
        if (_error != null) _ErrorText(_error!),
        const Divider(height: 48),
        OutlinedButton(
          onPressed: _busy ? null : _changePin,
          child: const Text('修改家属密码'),
        ),
        const SizedBox(height: 16),
        const Text('SeniorNav · 初版\n换手机或清除应用数据后，需要重新设置地点。'),
      ],
    );
  }

  Widget _homeSlot(int slot) {
    SavedPlace? place;
    for (final candidate in _places.places) {
      if (candidate.slot == slot) {
        place = candidate;
        break;
      }
    }
    final item = place;
    final icon =
        _icons[item?.icon ?? _slotIcons[slot]]?.$1 ?? Icons.place_rounded;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item?.label ?? _slotLabels[slot],
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(item?.name ?? '尚未设置地点'),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _edit(place: item, slot: slot),
              child: Text(item == null ? '设置地点' : '修改地点'),
            ),
            if (item != null && slot != 1)
              TextButton(
                onPressed: _busy ? null : () => _delete(item),
                child: const Text('清除此位置的地点'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('家属设置')),
    body: AnimatedBuilder(
      animation: _places,
      builder: (context, _) => !_unlocked
          ? _gate()
          : !_places.privacyAccepted
          ? _privacy()
          : _management(),
    ),
  );
}

class _PlaceEditor extends StatefulWidget {
  const _PlaceEditor({
    required this.services,
    this.place,
    required this.initialSlot,
  });
  final AppServices services;
  final SavedPlace? place;
  final int initialSlot;

  @override
  State<_PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<_PlaceEditor> {
  late final TextEditingController _label;
  late final TextEditingController _city;
  final _query = TextEditingController();
  late int _slot;
  late String _icon;
  PoiCandidate? _selected;
  List<PoiCandidate> _results = const [];
  bool _busy = false;
  bool _searched = false;
  bool _mapOpened = false;
  DateTime? _verifiedAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.place;
    _slot = p?.slot ?? widget.initialSlot;
    _label = TextEditingController(
      text: p?.label ?? (_slot == 0 ? '' : _slotLabels[_slot]),
    );
    _city = TextEditingController(text: p?.city ?? '');
    _icon = p?.icon ?? _slotIcons[_slot];
    if (p != null) {
      _selected = PoiCandidate(
        uid: p.poiUid ?? '',
        name: p.name,
        address: p.address,
        city: p.city,
        point: p.point,
      );
      _verifiedAt = p.verifiedAt;
      _mapOpened = _verifiedAt != null;
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _city.dispose();
    _query.dispose();
    super.dispose();
  }

  void _fail(Object error) {
    if (mounted) {
      setState(
        () => _error = error is AppFailure ? error.message : '操作未完成，请稍后再试',
      );
    }
  }

  Future<void> _search() async {
    if (_busy) return;
    if (_city.text.trim().isEmpty || _query.text.trim().isEmpty) {
      setState(() => _error = '请填写城市和要查找的地点');
      return;
    }
    if (!widget.services.places.privacyAccepted) {
      setState(() => _error = '请先返回家属设置，阅读并同意使用说明');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _results = const [];
      _searched = false;
    });
    try {
      final results = await widget.services.poi.search(
        query: _query.text.trim(),
        city: _city.text.trim(),
      );
      if (mounted) {
        setState(() {
          _results = results;
          _searched = true;
        });
      }
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(PoiCandidate candidate) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final detail = await widget.services.poi.detail(candidate);
      if (mounted) {
        setState(() {
          _selected = detail;
          _verifiedAt = null;
          _mapOpened = false;
          _results = const [];
          _searched = false;
          if (_label.text.trim().isEmpty) _label.text = detail.name;
        });
      }
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMap() async {
    final candidate = _selected;
    if (_busy || candidate == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await widget.services.navigation.verifyPlace(candidate);
      if (outcome == NavigationOutcome.unavailable) {
        throw const AppFailure('暂时打不开地图，入口核对后才能保存');
      }
      if (mounted) setState(() => _mapOpened = true);
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final candidate = _selected;
    if (candidate == null || _verifiedAt == null) {
      setState(() => _error = '请先选择地点，并打开地图核对入口');
      return;
    }
    if (_label.text.trim().isEmpty) {
      setState(() => _error = '请填写老人看到的按钮名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final existing = widget.place;
    final point = candidate.preferredPoint;
    final now = DateTime.now();
    final place = SavedPlace(
      id: existing?.id ?? _newId(),
      slot: _slot,
      label: _slot == 1 ? '回家' : _label.text.trim(),
      icon: _slot == 1 ? 'home' : _icon,
      name: candidate.name,
      address: candidate.address,
      city: candidate.city.isEmpty ? _city.text.trim() : candidate.city,
      latitude: point.latitude,
      longitude: point.longitude,
      poiUid: candidate.uid,
      updatedAt: now,
      verifiedAt: _verifiedAt,
      sortOrder:
          existing?.sortOrder ??
          widget.services.places.places.where((p) => p.slot == 0).length,
      rev: existing?.rev ?? 1,
    );
    try {
      await widget.services.places.savePlace(place);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(title: Text(widget.place == null ? '设置地点' : '修改地点')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            _slot == 0 ? '放在“更多地点”里' : '首页第 $_slot 个按钮',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 20),
          if (widget.place?.slot != 1) ...[
            DropdownButtonFormField<int>(
              isExpanded: true,
              itemHeight: null,
              initialValue: _slot,
              decoration: const InputDecoration(labelText: '放在哪个位置'),
              items: [
                for (var slot = 0; slot <= 4; slot++)
                  DropdownMenuItem(
                    value: slot,
                    enabled:
                        slot == 0 ||
                        !widget.services.places.places.any(
                          (p) => p.slot == slot && p.id != widget.place?.id,
                        ),
                    child: Text(
                      slot == 0 ? '更多地点' : '首页第 $slot 个：${_slotLabels[slot]}',
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (slot) {
                      if (slot == null) return;
                      setState(() {
                        _slot = slot;
                        if (slot == 1) {
                          _label.text = '回家';
                          _icon = 'home';
                        }
                      });
                    },
            ),
            const SizedBox(height: 20),
          ],
          TextField(
            controller: _label,
            enabled: !_busy && _slot != 1,
            maxLength: 16,
            decoration: const InputDecoration(labelText: '老人看到的按钮名称'),
          ),
          if (_slot != 1) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: _icons.containsKey(_icon) ? _icon : 'place',
              decoration: const InputDecoration(labelText: '按钮图标'),
              items: [
                for (final entry in _icons.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Row(
                      children: [
                        Icon(entry.value.$1),
                        const SizedBox(width: 12),
                        Text(entry.value.$2),
                      ],
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _icon = value ?? 'place'),
            ),
          ],
          const Divider(height: 40),
          Text('1. 搜索并选择地点', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _city,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '城市',
              hintText: '例如：合肥',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _query,
            enabled: !_busy,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: const InputDecoration(
              labelText: '地点名称',
              hintText: '输入小区、医院或商店名称',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _search,
            icon: const Icon(Icons.search_rounded),
            label: Text(_busy ? '请稍候…' : '搜索地点'),
          ),
          if (_searched && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('没有找到地点，请检查城市或换一个名称。'),
            ),
          for (final candidate in _results)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                title: Text(candidate.name),
                subtitle: Text(candidate.address),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _busy ? null : () => _select(candidate),
              ),
            ),
          if (selected != null) ...[
            const SizedBox(height: 24),
            Text(
              '已选择：${selected.name}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(selected.address),
            const Divider(height: 40),
            Text('2. 在地图上核对入口', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text('请查看地点和出入口是否正确。看完地图后返回这里，再勾选确认。'),
            if (selected.navigationPoint == null) ...[
              const SizedBox(height: 12),
              const Text('这个地点没有单独标出的出入口。请核对地图上的位置；位置不对时，返回搜索具体的大门。'),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _openMap,
              icon: const Icon(Icons.map_outlined),
              label: const Text('打开地图核对入口'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('我已核对地图，确认这是要去的入口'),
              value: _verifiedAt != null,
              onChanged: !_mapOpened || _busy
                  ? null
                  : (checked) => setState(() {
                      _verifiedAt = checked == true ? DateTime.now() : null;
                    }),
            ),
          ],
          if (_error != null) _ErrorText(_error!),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || selected == null || _verifiedAt == null
                ? null
                : _save,
            child: const Text('保存地点'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ChangePinPage extends StatefulWidget {
  const _ChangePinPage({required this.repository});
  final PlaceRepository repository;
  @override
  State<_ChangePinPage> createState() => _ChangePinPageState();
}

class _ChangePinPageState extends State<_ChangePinPage> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await widget.repository.verifyPin(_old.text)) {
        throw const AppFailure('原家属密码不正确');
      }
      if (_new.text != _confirm.text) throw const AppFailure('两次新密码输入不一致');
      await widget.repository.setPin(_new.text);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AppFailure ? error.message : '密码未保存，请稍后再试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('修改家属密码')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _PinField(controller: _old, label: '原家属密码', enabled: !_busy),
        const SizedBox(height: 20),
        _PinField(controller: _new, label: '新密码', enabled: !_busy),
        const SizedBox(height: 20),
        _PinField(controller: _confirm, label: '再次输入新密码', enabled: !_busy),
        if (_error != null) _ErrorText(_error!),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('保存新密码'),
        ),
      ],
    ),
  );
}

class _PinField extends StatelessWidget {
  const _PinField({
    required this.controller,
    required this.label,
    required this.enabled,
  });
  final TextEditingController controller;
  final String label;
  final bool enabled;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    keyboardType: TextInputType.number,
    maxLength: 6,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label, counterText: ''),
  );
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}
