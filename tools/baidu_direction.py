#!/usr/bin/env python3
"""M0 任务 1：用百度 Web API 查真实线路，核对 v0.2 §4.4 RouteSummary 需要的字段。

方案 §4.2 要在「Web API + 无服务器代理」与「百度 Android SDK」之间做选择，
判断依据是字段够不够、延迟能不能接受。本脚本负责产出前者的证据。

服务端 AK/SK 从环境变量读取（source .env.local），签名复用 baidu_place.signed_get。
默认查询的起终点都是公共地标，因此录制的 fixture 可以提交；
若改用真实住址，输出必须落到被 gitignore 的路径。

用法：
    set -a && . ./.env.local && set +a
    python3 tools/baidu_direction.py                 # 跑内置的三条线路
    python3 tools/baidu_direction.py --save-fixtures # 另存原始 JSON

配额警告：路线规划服务个人开发者认证的并发上限是 3，超限平台会发告警短信。
本脚本一律串行发请求（--gap 默认 1.5 秒）；调大 --repeat 前先确认当日额度。
"""

import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from baidu_place import signed_get  # noqa: E402

AK = os.environ.get("BAIDU_MAP_AK")

# 三条线路各自要产出一种「响应形状」，供 §4.4 的解析单元测试使用。
# 起终点全部是公共地标（火车站、地铁站、公园、公立医院），按 GIT_COMMIT_RULES §3.1
# 属于允许入库的测试地点；这里的 15 位小数直接取自 /place/v3/suggestion 的返回，
# 保留原精度本身就是证据——同一坐标 v2/search 只给 6 位，见 ADR 0002。
# 真实住址一律不得写进本文件，只能经 tools/build_probe.sh 构建期注入。
# tactics 是逐条指定的：换乘那条必须用 2（少步行）才会给出 1 次换乘的公交方案，
# 用 0（推荐）会变成地铁直达，就录不到换乘形状了——这不是推荐策略，只是为了取样本。
ROUTES = [
    {
        "id": "metro_direct",
        "label": "地铁直达（0 换乘）",
        "tactics": 0,
        "origin": {"name": "合肥南站-地铁站", "lat": 31.804839304830615, "lng": 117.29710395951885},
        "destination": {"name": "合肥火车站", "lat": None, "lng": None},
    },
    {
        "id": "bus_transfer",
        "label": "公交 1 次换乘",
        "tactics": 2,
        "origin": {"name": "大蜀山森林公园", "lat": None, "lng": None},
        "destination": {"name": "安徽省立医院", "lat": None, "lng": None},
    },
    {
        "id": "walk_short",
        "label": "短距离步行（公交 routes 为空的边界）",
        "tactics": 0,
        "origin": {"name": "合肥南站", "lat": 31.803748341602503, "lng": 117.2974015681343},
        "destination": {"name": "合肥南站-地铁站", "lat": 31.804839304830615, "lng": 117.29710395951885},
    },
]


def resolve(name, region="合肥"):
    """名称→坐标。用 v3/suggestion，它返回 15 位小数，v2/search 只有 6 位。"""
    params = [
        ("query", name),
        ("region", region),
        ("city_limit", "true"),
        ("output", "json"),
        ("ak", AK),
    ]
    data = json.loads(signed_get("/place/v3/suggestion", params))
    if data.get("status") != 0 or not data.get("results"):
        raise SystemExit(f"检索 {name} 失败: status={data.get('status')} {data.get('message')}")
    top = data["results"][0]
    loc = top["location"]
    return {"name": top["name"], "uid": top.get("uid"), "lat": loc["lat"], "lng": loc["lng"]}


def timed(path, params):
    start = time.perf_counter()
    raw = signed_get(path, params)
    elapsed = (time.perf_counter() - start) * 1000
    try:
        return json.loads(raw), elapsed
    except json.JSONDecodeError:
        return {"_parse_error": raw[:200]}, elapsed


def query_transit(o, d, tactics=2, departure_time=None, dest_uid=None):
    """departure_time 必须是 HH:mm，最长 11 字符。

    传 Unix 时间戳会返回 status=2「departure_time 参数有误」，整条查询失败；
    传 YYYY-MM-DD HH:mm:ss 会返回「最大长度是11」。方案 §4.3 的参数表没列这个字段，
    按「出发时间」的字面意思传时间戳是必踩的坑，因此默认干脆不传。
    """
    params = [
        ("origin", f"{o['lat']},{o['lng']}"),
        ("destination", f"{d['lat']},{d['lng']}"),
        ("coord_type", "bd09ll"),
        ("tactics_incity", str(tactics)),
    ]
    if departure_time:
        params.append(("departure_time", departure_time))
    if dest_uid:
        params.append(("destination_uid", dest_uid))
    params += [("output", "json"), ("ak", AK)]
    return timed("/direction/v2/transit", params)


def query_walking(o, d):
    params = [
        ("origin", f"{o['lat']},{o['lng']}"),
        ("destination", f"{d['lat']},{d['lng']}"),
        ("coord_type", "bd09ll"),
        ("output", "json"),
        ("ak", AK),
    ]
    return timed("/direction/v2/walking", params)


def _segments(route):
    """routes[].steps 是「列表的列表」：外层是步骤，内层才是分段对象。

    方案 §4.3 把它当成对象数组，直接 step.get(...) 会抛 AttributeError。
    """
    for group in route.get("steps") or []:
        if isinstance(group, dict):
            yield group
        else:
            yield from group


def transit_summary(payload):
    """按 v0.2 §4.4 的 RouteSummary 字段逐项核对，缺哪个直接标出来。"""
    if "_parse_error" in payload:
        return {"错误": f"非 JSON 响应：{payload['_parse_error']}"}
    if payload.get("status") != 0:
        return {"错误": f"status={payload.get('status')} message={payload.get('message')}"}
    routes = (payload.get("result") or {}).get("routes") or []
    if not routes:
        return {"错误": "routes 为空", "origin": payload.get("message")}
    r = routes[0]
    legs = []
    walk_m = 0
    transfers = 0
    for seg in _segments(r):
        # vehicle_info 是 {type, detail}，线路字段全在 detail 里；
        # detail 为 null 的段是步行或「同站换乘」标记，不是乘车段。
        detail = (seg.get("vehicle_info") or {}).get("detail")
        if not detail:
            if seg.get("trans_type") == 0:
                walk_m += seg.get("distance", 0)
            elif seg.get("trans_type") == 3:
                transfers += 1
            continue
        legs.append({
            "lineName": detail.get("name"),
            "lineType": detail.get("type"),
            "bus_type": detail.get("bus_type"),
            "direction": detail.get("direct_text"),
            "boardStop": detail.get("on_station"),
            "alightStop": detail.get("off_station"),
            "stop_num": detail.get("stop_num"),
            "中间站数": len(detail.get("stop_info") or []),
            "stop_num==中间站数+1": detail.get("stop_num") == len(detail.get("stop_info") or []) + 1,
            "firstTime": detail.get("first_time"),
            "lastTime": detail.get("last_time"),
            # 刻意并列出来：end_info.end_name 是下车站，不是线路终点站，
            # 方案 §4.3 说的「终点站名」指向它会把方向写错。
            "end_info.end_name": (detail.get("end_info") or {}).get("end_name"),
        })
    return {
        "durationSec": r.get("duration"),
        "distanceM": r.get("distance"),
        "price": r.get("price"),
        "arrive_time": r.get("arrive_time"),
        "walkM(各步行段求和)": walk_m,
        "transfers(换乘标记段数)": transfers,
        "车辆段数": len(legs),
        "分段总数": sum(1 for _ in _segments(r)),
        "方案总数": len(routes),
        "车辆段": legs,
    }


def _unquote(value):
    """剥掉 shell 赋值的外层引号。.env.places 用的是单引号，只 strip 双引号会漏。"""
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def _private_markers():
    """取出真实住址的 UID 与坐标，用来拦住误存的 fixture。

    GIT_COMMIT_RULES §3.2 规定家的真实坐标只存手机本地，但 fixture 目录
    app/test/fixtures/ 并不在 .gitignore 里。一旦有人把 ROUTES 改成真实住址再
    --save-fixtures，私人数据就直接进了可提交路径，因此这里做机械拦截而不是靠注释。
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env.places")
    if not os.path.exists(path):
        return []
    markers = set()
    uid = os.environ.get("HOME_POI_UID")
    for line in open(path, encoding="utf-8"):
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), _unquote(value)
        if key == "HOME_POI_UID" and value:
            uid = value
        if key == "PROBE_PLACES_JSON" and value:
            try:
                blob = json.loads(value)
            except json.JSONDecodeError:
                blob = None
            for point in (blob or {}).values():
                if not isinstance(point, dict):
                    continue
                if point.get("uid"):
                    markers.add(str(point["uid"]))
                for coord in ("lat", "lng"):
                    v = point.get(coord)
                    if isinstance(v, (int, float)):
                        # 只拦 6 位小数以上：3–4 位在整个合肥市都会和公共地标撞车，
                        # 会把正常的 fixture 全判成隐私泄露，闸一旦天天误报就没人看了。
                        # 6 位约 0.1 米，与 2 公里外的地标不可能重合。
                        for n in (6, 8):
                            markers.add(f"{v:.{n}f}")
                        markers.add(repr(v))
    if uid:
        markers.add(_unquote(uid))
    return [m for m in markers if len(m) >= 6]


_HIGH_PRECISION = re.compile(r"\d+\.\d{7,}")


def _round_floats(obj, ndigits=6):
    """把 fixture 里所有高精度数字收到 6 位小数（约 0.1 米）。

    不是为了省空间，是为了消除一类误报：百度返回的坐标有 14 位小数，
    合肥的经度小数部分正好是 11 位数字，会被 pre-commit 钩子的手机号正则
    命中，一份 transit fixture 里就有近两百处，全是坐标而不是号码。
    fixture 只用于验证 §4.4 的字段映射，几何精度无关紧要，
    因此就地降精度而不是放宽钩子。

    折线 `path` 是「lng,lat;lng,lat」形式的**字符串**，不是数值，
    所以字符串也要扫一遍，否则 transit 的 fixture 降不到。
    """
    if isinstance(obj, dict):
        return {k: _round_floats(v, ndigits) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_round_floats(v, ndigits) for v in obj]
    if isinstance(obj, float):
        return round(obj, ndigits)
    if isinstance(obj, str):
        return _HIGH_PRECISION.sub(lambda m: f"{float(m.group()):.{ndigits}f}", obj)
    return obj


def save_fixture(path, payload):
    """写 fixture 前先降精度、再扫一遍真实住址的坐标与 UID，命中就拒绝落盘。"""
    payload = _round_floats(payload)
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    hits = sorted({m for m in _private_markers() if m in text})
    if hits:
        raise SystemExit(
            f"拒绝写入 {path}：内容含真实住址标识（{len(hits)} 处）。"
            "fixture 只能录公共地标，见 docs/GIT_COMMIT_RULES.md §3.1–3.2。"
        )
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def field_audit(payload, kind):
    """列出真实返回的字段名，用来核对方案 §4.3 的接口契约是不是写全了。"""
    if payload.get("status") != 0:
        return f"status={payload.get('status')} {payload.get('message')}"
    routes = (payload.get("result") or {}).get("routes") or []
    if not routes:
        return "routes 为空"
    r = routes[0]
    first = r["steps"][0]
    # transit 的 steps 是列表的列表，walking 是扁平的字典列表，两者结构不同。
    shape = (f"list of list（外层 {len(r['steps'])} 步，内层 {[len(s) for s in r['steps']]}）"
             if isinstance(first, list)
             else f"list of dict（{len(r['steps'])} 段，每段 {len(first)} 个字段）")
    lines = [f"result keys     : {sorted((payload.get('result') or {}).keys())}",
             f"route keys      : {sorted(r.keys())}",
             f"steps 结构      : {shape}"]
    segs = list(_segments(r))
    if segs:
        lines.append(f"segment keys    : {sorted(segs[0].keys())}")
        vi = segs[0].get("vehicle_info")
        if isinstance(vi, dict):
            lines.append(f"vehicle_info    : {sorted(vi.keys())}  ← 线路字段在 detail 里，不在这一层")
        for seg in segs:
            detail = (seg.get("vehicle_info") or {}).get("detail")
            if detail:
                lines.append(f"detail keys     : {sorted(detail.keys())}")
                for sub in ("start_info", "end_info"):
                    if isinstance(detail.get(sub), dict):
                        lines.append(f"{sub:16s}: {sorted(detail[sub].keys())}")
                break
    if kind == "walking":
        lines.append("（步行无 vehicle_info.detail）")
    return "\n".join(lines)


def walking_summary(payload):
    if "_parse_error" in payload:
        return {"错误": f"非 JSON 响应：{payload['_parse_error']}"}
    if payload.get("status") != 0:
        return {"错误": f"status={payload.get('status')} message={payload.get('message')}"}
    routes = (payload.get("result") or {}).get("routes") or []
    if not routes:
        return {"错误": "routes 为空"}
    r = routes[0]
    steps = list(_segments(r))
    # 方案 §3.3 的步行摘要要写「是否需要过街提示」，且注明来自百度 steps。
    # instructions 是给人看的文案，先统计里面出现了哪些过街相关词，再决定能不能用。
    crossing = {"天桥": 0, "地下通道": 0, "斑马线": 0, "红绿灯": 0, "过街": 0, "横穿": 0, "马路": 0}
    for s in steps:
        text = s.get("instructions") or ""
        for word in crossing:
            if word in text:
                crossing[word] += 1
    return {
        "distanceM": r.get("distance"),
        "durationSec": r.get("duration"),
        "steps段数": len(steps),
        "首段instructions": (steps[0].get("instructions") or "")[:60] if steps else None,
        "过街词命中(段数)": {k: v for k, v in crossing.items() if v},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--save-fixtures", action="store_true")
    ap.add_argument("--tactics", type=int, default=2, help="0推荐 1少换乘 2少步行（方案 §4.3 默认）")
    ap.add_argument("--departure-time", help="HH:mm；留空则不传该参数")
    ap.add_argument("--repeat", type=int, default=1,
                    help="每条线路重复查询次数。默认 1：路线规划服务个人认证只有 3 并发，"
                         "跑采样前先确认额度，否则会触发平台的并发告警短信")
    ap.add_argument("--gap", type=float, default=1.5,
                    help="两次请求之间的间隔秒数，串行发请求，不占用并发额度")
    ap.add_argument("--dest-uid", action="store_true",
                    help="带上 destination_uid（方案 §4.3 列了这个参数，但没说 transit 是否接受）")
    args = ap.parse_args()

    if not AK:
        sys.exit("缺少 BAIDU_MAP_AK，请先 source .env.local")

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "test", "fixtures")
    for route in ROUTES:
        o, d = route["origin"], route["destination"]
        for pt in (o, d):
            if pt["lat"] is None:
                resolved = resolve(pt["name"])
                pt.update(resolved)
                print(f"[解析] {pt['name']} -> {pt['lat']:.6f},{pt['lng']:.6f} uid={pt.get('uid')}")

        tactics = route.get("tactics", args.tactics)
        print(f"\n{'='*66}\n{route['label']}  {o['name']} -> {d['name']}  tactics_incity={tactics}\n{'='*66}")

        lat = []
        for i in range(args.repeat):
            if i:
                time.sleep(args.gap)
            tp, tms = query_transit(o, d, tactics, args.departure_time,
                                    d.get("uid") if args.dest_uid else None)
            time.sleep(args.gap)
            wp, wms = query_walking(o, d)
            lat.append((tms, wms))
        t_all = sorted(t for t, _ in lat)
        w_all = sorted(w for _, w in lat)
        print(f"延迟({args.repeat} 次): transit {t_all[0]:.0f}/{t_all[len(t_all)//2]:.0f}/{t_all[-1]:.0f} ms"
              f" | walking {w_all[0]:.0f}/{w_all[len(w_all)//2]:.0f}/{w_all[-1]:.0f} ms  (最小/中位/最大)")
        print(f"并行合计中位 {sorted(t+w for t, w in lat)[len(lat)//2]:.0f} ms；"
              f"串行合计中位 {t_all[len(t_all)//2] + w_all[len(w_all)//2]:.0f} ms")

        print("\n-- 字段核对（transit）--")
        print(field_audit(tp, "transit"))
        print("\n-- 字段核对（walking）--")
        print(field_audit(wp, "walking"))
        print("\n-- 公交 RouteSummary 映射 --")
        print(json.dumps(transit_summary(tp), ensure_ascii=False, indent=2))
        print("\n-- 步行 RouteSummary 映射 --")
        print(json.dumps(walking_summary(wp), ensure_ascii=False, indent=2))

        if args.save_fixtures:
            os.makedirs(out_dir, exist_ok=True)
            for kind, payload in (("transit", tp), ("walking", wp)):
                path = os.path.join(out_dir, f"{route['id']}_{kind}.json")
                save_fixture(path, payload)
                print(f"[fixture] {os.path.relpath(path, os.path.join(out_dir, '..'))}")


if __name__ == "__main__":
    main()
