#!/usr/bin/env python3
"""coordtransform_dart 与百度官方 geoconv v2 的逐点交叉验证。

引入 coordtransform_dart 前的安全关键步骤（docs/research/开源项目复用调研.md §7.1）：
它把 ADR 0001 D3 的起点转换从「需要 AK 的网络接口」降级为纯本地计算，算错就会
让老人从错误的起点开始导航，因此必须与官方接口逐点比对，不能只信包自己的测试。

为什么需要「数值反解」这一步：
    geoconv v2 只支持 model 1–6，**没有 bd09ll → wgs84**（model 7+ 返回
    status=29 param error）。而仓库里的公共地标锚点全是 bd09ll（fixture 用
    coord_type=bd09ll 录制）。为了拿到这些地标真正的 WGS84 输入，用官方
    model=2 做不动点迭代反解：W ← W + (A − model2(W))。反解收敛后，
    model2(W) 与锚点 A 的偏差就是官方接口自身的往返精度。
    model=1（gcj02→bd09）与 model=5（bd09→gcj02）已实测互逆，偏差 0.09 米。

服务端 AK/SK 从环境变量读取（先 source .env.local），签名复用 baidu_place.signed_get。
输出只有坐标与偏差，不打印 AK/SK。

用法：
    set -a && . ./.env.local && set +a
    python3 tools/coord-check/crosscheck.py
"""

import glob
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from baidu_place import signed_get, _secrets  # noqa: E402

# 公共地标锚点（bd09ll），与 app/test/fixtures/*_walking.json 里的起终点一致。
# 全是火车站/地铁站/公园/公立医院，符合 GIT_COMMIT_RULES §3.1。
ANCHORS = [
    ("合肥南站-地铁站", 117.297095, 31.804835),
    ("合肥火车站", 117.323703, 31.891171),
    ("大蜀山森林公园", 117.177405, 31.847342),
    ("安徽省立医院", 117.297176, 31.863345),
    ("合肥南站", 117.297401, 31.803746),
]

# 算法扫描点：只用于把比对范围从合肥扩到全国，输入是同一批数字喂给两个实现，
# 因此不要求这些坐标本身有多权威。含 isInChina 矩形的东西南北边界附近。
SWEEP = [
    ("北京", 116.4074, 39.9042),
    ("上海", 121.4737, 31.2304),
    ("广州", 113.2644, 23.1291),
    ("成都", 104.0665, 30.5723),
    ("哈尔滨", 126.5340, 45.8020),
    ("乌鲁木齐", 87.6168, 43.8256),
    ("拉萨", 91.1322, 29.6600),
    ("三亚", 109.5119, 18.2528),
    ("喀什", 75.9897, 39.4704),
    ("漠河", 122.5386, 52.9723),
]

MODEL_GCJ_TO_BD = 1
MODEL_WGS_TO_BD = 2
MODEL_BD_TO_GCJ = 5
CHUNK = 10
PASS_METERS = 1.0

# 境外点：验证包在国境外的行为（原样返回还是硬转）。不参与 1 米判定，
# 因为官方接口对境外点的处理未知，这里只记录两边各自给了什么。
OVERSEAS = [
    ("东京", 139.6917, 35.6895),
    ("伦敦", -0.1276, 51.5072),
]
OVERSEAS_PREFIX = "境外·"


def conv(coords, model):
    """批量转换。coords 是 [(lng, lat), …]，返回同序的 [(lng, lat), …]。"""
    out = []
    for i in range(0, len(coords), CHUNK):
        part = coords[i:i + CHUNK]
        ak, _ = _secrets()
        params = [
            ("coords", ";".join(f"{lng:.9f},{lat:.9f}" for lng, lat in part)),
            ("model", str(model)),
            ("output", "json"),
            ("ak", ak),
        ]
        raw = signed_get("/geoconv/v2/", params)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            sys.exit(f"geoconv model={model} 返回非 JSON：{raw[:200]}")
        if data.get("status") != 0:
            sys.exit(f"geoconv model={model} 失败：status={data.get('status')} "
                     f"message={data.get('message')}")
        got = [(r["x"], r["y"]) for r in data["result"]]
        if len(got) != len(part):
            sys.exit(f"geoconv model={model} 返回 {len(got)} 点，期望 {len(part)} 点")
        out.extend(got)
    return out


def meters(p, q):
    """等距圆柱近似，米。比对的是同一地点的两个坐标，这个精度足够。"""
    dx = (p[0] - q[0]) * 111320 * math.cos(math.radians(q[1]))
    dy = (p[1] - q[1]) * 110540
    return math.hypot(dx, dy)


def check_anchors_in_fixtures():
    """锚点必须真的来自仓库里的 fixture，避免手抄坐标抄错。"""
    seen = set()
    for path in glob.glob(os.path.join(ROOT, "app/test/fixtures/*_walking.json")):
        with open(path, encoding="utf-8") as fh:
            result = json.load(fh)["result"]
        for side, key in (("origin", "originPt"), ("destination", "destinationPt")):
            pt = result[side][key]
            seen.add((round(pt["lng"], 6), round(pt["lat"], 6)))
    missing = [n for n, lng, lat in ANCHORS if (lng, lat) not in seen]
    if missing:
        sys.exit(f"锚点不在 fixture 里，请核对：{missing}")


def invert_to_wgs84(anchors):
    """用官方 model=2 反解出锚点的 WGS84。返回 (wgs84 列表, 收敛偏差列表)。"""
    bd = [(lng, lat) for _, lng, lat in anchors]
    # 初值：减掉合肥一带实测的 wgs84→bd09 偏移量级。
    wgs = [(lng - 0.0121, lat - 0.0037) for lng, lat in bd]
    for _ in range(4):
        fwd = conv(wgs, MODEL_WGS_TO_BD)
        wgs = [(w[0] + (b[0] - f[0]), w[1] + (b[1] - f[1]))
               for w, b, f in zip(wgs, bd, fwd)]
    residual = [meters(f, b) for f, b in zip(conv(wgs, MODEL_WGS_TO_BD), bd)]
    return wgs, residual


def main():
    check_anchors_in_fixtures()
    print(f"锚点 {len(ANCHORS)} 个（公共地标，bd09ll），扫描点 {len(SWEEP)} 个")

    anchor_wgs, residual = invert_to_wgs84(ANCHORS)
    print("\n== 官方 model=2 反解锚点的 WGS84（不动点迭代 4 次）==")
    for (name, _, _), w, r in zip(ANCHORS, anchor_wgs, residual):
        print(f"  {name:<16} wgs84={w[0]:.9f},{w[1]:.9f}  官方往返偏差={r:.3f}m")
    if max(residual) > 0.5:
        sys.exit(f"反解未收敛（最大 {max(residual):.3f}m），比对结果不可信")

    points = [{"id": name, "wgs84": list(w)}
              for (name, _, _), w in zip(ANCHORS, anchor_wgs)]
    points += [{"id": f"扫描·{name}", "wgs84": [lng, lat]} for name, lng, lat in SWEEP]
    points += [{"id": f"{OVERSEAS_PREFIX}{name}", "wgs84": [lng, lat]}
               for name, lng, lat in OVERSEAS]

    # gcj02 支线：单独验证 wgs84ToBd09 的后半段，便于定位偏差出在哪一半。
    anchor_bd = [(lng, lat) for _, lng, lat in ANCHORS]
    anchor_gcj = conv(anchor_bd, MODEL_BD_TO_GCJ)
    for p, g in zip(points[:len(ANCHORS)], anchor_gcj):
        p["gcj02"] = list(g)

    official_wgs = conv([tuple(p["wgs84"]) for p in points], MODEL_WGS_TO_BD)
    official_gcj = conv(anchor_gcj, MODEL_GCJ_TO_BD)

    pts_path = os.path.join(HERE, "points.json")
    out_path = os.path.join(HERE, "dart_out.json")
    with open(pts_path, "w", encoding="utf-8") as fh:
        json.dump(points, fh, ensure_ascii=False, indent=2)
    subprocess.run(["dart", "run", "bin/convert.dart", pts_path, out_path],
                   cwd=HERE, check=True)
    with open(out_path, encoding="utf-8") as fh:
        dart = {row["id"]: row for row in json.load(fh)}

    print("\n== wgs84ToBd09：包 vs 官方 model=2 ==")
    anchor_by_name = {name: (lng, lat) for name, lng, lat in ANCHORS}
    deviations = []
    for p, off in zip(points, official_wgs):
        row = dart[p["id"]]
        mine = tuple(row["wgs84ToBd09"])
        d = meters(mine, off)
        overseas = p["id"].startswith(OVERSEAS_PREFIX)
        if not overseas:
            deviations.append(d)
        extra = ""
        if p["id"] in anchor_by_name:
            extra = f"  距锚点={meters(mine, anchor_by_name[p['id']]):.3f}m"
        if overseas:
            extra = f"  包原样返回={row['passthrough']}  官方={off[0]:.6f},{off[1]:.6f}"
        print(f"  {p['id']:<18} 偏差={d:8.4f}m{extra}")

    print("\n== gcj02ToBd09：包 vs 官方 model=1 ==")
    gcj_dev = []
    for p, off in zip(points[:len(ANCHORS)], official_gcj):
        mine = tuple(dart[p["id"]]["gcj02ToBd09"])
        d = meters(mine, off)
        gcj_dev.append(d)
        print(f"  {p['id']:<18} 偏差={d:8.4f}m")

    # 偏差归因：官方没有 wgs84→gcj02 的 model，用 model=2 再 model=5 绕一圈拿到
    # 官方的 gcj02，与包的 wgs84ToGcj02 比，看亚米级偏差出在哪一半。
    print("\n== 偏差归因：wgs84ToGcj02（包）vs 官方 model=2→model=5 ==")
    half_dev = []
    for p, off in zip(points, conv(official_wgs, MODEL_BD_TO_GCJ)):
        mine = tuple(dart[p["id"]]["wgs84ToGcj02"])
        d = meters(mine, off)
        half_dev.append(d)
        print(f"  {p['id']:<18} 偏差={d:8.4f}m")

    worst = max(deviations)
    print(f"\n汇总：wgs84ToBd09 最大偏差 {worst:.4f}m（{len(deviations)} 点），"
          f"gcj02ToBd09 最大偏差 {max(gcj_dev):.4f}m（{len(gcj_dev)} 点），"
          f"wgs84ToGcj02 最大偏差 {max(half_dev):.4f}m（{len(half_dev)} 点）")
    print(f"判定阈值 {PASS_METERS}m -> {'通过' if worst <= PASS_METERS else '不通过'}")
    return 0 if worst <= PASS_METERS else 1


if __name__ == "__main__":
    sys.exit(main())