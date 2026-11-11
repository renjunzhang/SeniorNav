#!/usr/bin/env python3
"""生成 M0 探针所需的真实地点数据，写入 tools/.env.places（已 gitignore）。

按 docs/GIT_COMMIT_RULES.md §3.1–3.4，真实住址、精确坐标与 POI UID 不得进入仓库，
所以本脚本只把数据落到被忽略的本地文件，构建时由 tools/build_probe.sh 以
--dart-define 注入。脚本自身不含任何私人信息，POI UID 从参数或已生成文件读取。

用法：
    set -a && . ./.env.local && set +a
    python3 tools/write_places_env.py <父POI_UID>     # 首次
    python3 tools/write_places_env.py                 # 复用上次写入的 UID
"""

import json
import math
import os
import re
import stat
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from baidu_place import place_detail  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env.places")


def _meters(a, b):
    """两点近似距离。只用于在候选出入口之间排序，不需要精确测地公式。"""
    dlat = (a["lat"] - b["lat"]) * 111320.0
    dlng = (a["lng"] - b["lng"]) * 111320.0 * math.cos(math.radians(a["lat"]))
    return math.hypot(dlat, dlng)


def _pv(child):
    """把 pv_rate「93%选择」解析成整数；缺失记为 -1，排在有数据的后面。"""
    m = re.search(r"(\d+)", str(child.get("pv_rate") or ""))
    return int(m.group(1)) if m else -1


def _gates(children):
    """只保留「出入口;门」类子点。

    必须按分号切段后整段比较：停车场标签是「交通设施;停车场;门前停车场」，
    用子串匹配 ';门' 会把它误当成门，导致步行起点落在停车场。
    """
    out = []
    for c in children:
        segments = set()
        for field in ("std_tag", "classified_poi_tag"):
            segments.update(s for s in str(c.get(field) or "").split(";") if s)
        if "门" in segments or "出入口" in segments:
            out.append(c)
    return out


def main():
    uid = sys.argv[1] if len(sys.argv) > 1 else _saved_uid()
    if not uid:
        sys.exit("缺少父 POI UID：python3 tools/write_places_env.py <UID>")

    path, data = place_detail(uid)
    if data is None:
        sys.exit("地点详情检索失败，见上面的 status")
    result = data["results"][0]
    detail = result["detail_info"]

    centroid = result["location"]
    navi = detail.get("navi_location") or centroid
    gates = sorted(_gates(detail.get("children") or []), key=_pv, reverse=True)
    if not gates:
        sys.exit("该 POI 没有「出入口」子点，无法确定步行终点；请换一个有门的地点")

    gate = gates[0]
    # 起点选离主要出入口最远的另一个门，这样 walknavi 有一段真实可走的距离。
    origin = max(gates[1:], key=lambda g: _meters(g["location"], gate["location"])) if len(gates) > 1 else None
    if origin is None:
        sys.exit("只有一个出入口，无法构造步行起点；请手动指定另一个真实邻近点")

    places = {
        "region": result.get("city", "").replace("市", "") or None,
        "home": {
            "name": result["name"],
            "uid": result["uid"],
            "lat": navi["lat"],
            "lng": navi["lng"],
        },
        "homeCentroid": {
            "name": result["name"],
            "uid": result["uid"],
            "lat": centroid["lat"],
            "lng": centroid["lng"],
        },
        "homeGate": {
            "name": gate["name"],
            "uid": gate["uid"],
            "lat": gate["location"]["lat"],
            "lng": gate["location"]["lng"],
        },
        "walkOrigin": {
            "name": origin["name"],
            "uid": origin["uid"],
            "lat": origin["location"]["lat"],
            "lng": origin["location"]["lng"],
        },
    }
    places = {k: v for k, v in places.items() if v is not None}

    payload = json.dumps(places, ensure_ascii=False, separators=(",", ":"))
    # 单引号包裹，JSON 内部不含单引号；地点名若含单引号需要另行处理。
    assert "'" not in payload, "JSON 含单引号，shell 包裹方式需要调整"
    content = (
        "# 由 tools/write_places_env.py 生成，含真实住址与精确坐标。\n"
        "# 已被 .gitignore 排除，禁止提交、禁止粘贴到文档或截图。\n"
        f"HOME_POI_UID='{uid}'\n"
        f"PROBE_PLACES_JSON='{payload}'\n"
    )
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(OUT, stat.S_IRUSR | stat.S_IWUSR)

    print(f"接口          : {path} status={data.get('status')}")
    print(f"已写入        : {OUT} (600)")
    print(f"父 POI        : {result['name']} / {result.get('address')}")
    print(f"navi_location : {navi['lat']:.6f}, {navi['lng']:.6f}")
    print(f"location 中心 : {centroid['lat']:.6f}, {centroid['lng']:.6f}")
    print(f"主要出入口    : {gate['name']} pv_rate={gate.get('pv_rate')}")
    print(f"步行起点      : {origin['name']}")
    print(f"中心→出入口   : {_meters(centroid, gate['location']):.0f} 米"
          f"（children.distance={gate.get('distance')}）")
    print(f"navi→出入口   : {_meters(navi, gate['location']):.0f} 米")
    print(f"起点→出入口   : {_meters(origin['location'], gate['location']):.0f} 米")


def _saved_uid():
    try:
        with open(OUT, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("HOME_POI_UID="):
                    return line.split("=", 1)[1].strip().strip("'\"")
    except FileNotFoundError:
        pass
    return os.environ.get("HOME_POI_UID")


if __name__ == "__main__":
    main()
