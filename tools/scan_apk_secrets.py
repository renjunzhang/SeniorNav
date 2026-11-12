#!/usr/bin/env python3
"""扫描 APK/AAB，确认服务端密钥与私人地点数据没有进入安装包。

用法：
    python3 tools/scan_apk_secrets.py <apk路径> [<apk路径> ...]

检查两类东西：
  1. 服务端 AK/SK —— 来自 .env.local，任何情况下都不该出现在客户端。
  2. 真实地点数据 —— 来自 tools/.env.places（PROBE_PLACES_JSON）。这类数据
     是探针 APK 有意注入的，命中不算失败，但要报出来，避免把探针包当发布包。

本脚本只输出「命中/未命中 + 所在条目 + 次数」，永不回显密钥或坐标本身，
因此可以安全地把输出贴进文档或聊天记录。

退出码：0 = 没有密钥泄露；1 = 发现服务端密钥；2 = 参数/文件问题。
"""

from __future__ import annotations

import json
import os
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHUNK = 8 * 1024 * 1024


def read_env(path: Path) -> dict[str, str]:
    """读 KEY=VALUE，容忍 export 前缀与引号。不打印任何值。"""
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        key, _, value = line.partition("=")
        value = value.strip().strip("'\"")
        if value:
            out[key.strip()] = value
    return out


def collect_needles() -> tuple[list[tuple[str, bytes]], list[str]]:
    """返回 (待查字节串, 说明)。标签用于输出，不含真实值。"""
    needles: list[tuple[str, bytes]] = []
    notes: list[str] = []

    env = read_env(ROOT / ".env.local")
    for key in ("BAIDU_MAP_AK", "BAIDU_MAP_SK"):
        if key in env:
            needles.append((f"密钥 {key}", env[key].encode()))
        else:
            notes.append(f".env.local 中没有 {key}，该项跳过")
    for key in ("BAIDU_AK", "BAIDU_SK", "BAIDU_MAP_SECRET_KEY"):
        if key in env:
            needles.append((f"密钥 {key}", env[key].encode()))

    places_path = ROOT / "tools" / ".env.places"
    places = read_env(places_path)
    raw = places.get("PROBE_PLACES_JSON")
    if not raw:
        notes.append("tools/.env.places 中没有 PROBE_PLACES_JSON，私人地点项跳过")
        return needles, notes

    needles.append(("私人数据 PROBE_PLACES_JSON 整串", raw.encode()))
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        notes.append("PROBE_PLACES_JSON 不是合法 JSON，只查整串")
        return needles, notes

    if isinstance(data.get("region"), str):
        needles.append(("私人数据 region", data["region"].encode()))
    for point, value in data.items():
        if not isinstance(value, dict):
            continue
        for field in ("uid", "name", "lat", "lng"):
            if field not in value or value[field] in (None, ""):
                continue
            needles.append(
                (f"私人数据 {point}.{field}", str(value[field]).encode())
            )
    return needles, notes


def scan_entry(zf: zipfile.ZipFile, name: str, needles: list[tuple[str, bytes]]) -> dict[str, int]:
    """分块扫描单个条目，块间重叠 max_len-1 以免漏掉跨块的命中。"""
    hits: dict[str, int] = {}
    if not needles:
        return hits
    overlap = max(len(n) for _, n in needles) - 1
    tail = b""
    with zf.open(name) as fh:
        while True:
            chunk = fh.read(CHUNK)
            if not chunk:
                break
            buf = tail + chunk
            for label, needle in needles:
                count = buf.count(needle)
                if count:
                    hits[label] = hits.get(label, 0) + count
            tail = buf[-overlap:] if overlap else b""
    # 重叠区会把同一处命中重复计数一次，这里只关心「有没有」，
    # 计数按上界呈现即可，不追求精确。
    return hits


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    needles, notes = collect_needles()
    if not needles:
        print("没有可检查的目标：.env.local 与 tools/.env.places 都读不到内容。")
        for note in notes:
            print(f"  提示：{note}")
        return 2

    secret_labels = {label for label, _ in needles if label.startswith("密钥")}
    leaked = False

    for arg in argv:
        path = Path(arg)
        if not path.is_file():
            print(f"[跳过] 不是文件：{path}")
            continue
        print(f"\n=== {path} ({path.stat().st_size:,} 字节) ===")
        try:
            zf = zipfile.ZipFile(path)
        except zipfile.BadZipFile:
            print("  [错误] 不是合法的 zip/APK")
            leaked = True
            continue

        per_needle: dict[str, list[str]] = {}
        with zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                hits = scan_entry(zf, info.filename, needles)
                for label in hits:
                    per_needle.setdefault(label, []).append(info.filename)

        for label, _ in needles:
            entries = per_needle.get(label)
            if not entries:
                print(f"  [干净] {label}：未出现")
                continue
            kind = "泄露" if label in secret_labels else "注入"
            if label in secret_labels:
                leaked = True
            shown = ", ".join(entries[:4])
            more = f" 等 {len(entries)} 个条目" if len(entries) > 4 else ""
            print(f"  [{kind}] {label}：命中 {shown}{more}")

    for note in notes:
        print(f"\n提示：{note}")
    print()
    if leaked:
        print("结论：发现服务端密钥进入安装包，必须处理后才能分发。")
        return 1
    print("结论：未发现服务端 AK/SK 进入安装包。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))