#!/usr/bin/env python3
"""开发期工具：用百度服务端 AK 查询 POI 的精确坐标。

不属于 Flutter 客户端代码，不得移入 app/。服务端 AK/SK 只能用于本机开发期取数，
打包进 App 的必须是移动端 AK 或走自建后端转发。

签名算法照抄百度官方 Python 示例：
https://lbsyun.baidu.com/faq/api?title=webapi/appendix
"""

import hashlib
import json
import os
import sys
import urllib.parse
import urllib.request

# 官方示例指定的 safe 字符集，保留 URL 结构字符不转义。
SAFE = "/:=&?#+!$,;'@()*[]"
HOST = "https://api.map.baidu.com"


def _secrets():
    ak = os.environ.get("BAIDU_MAP_AK")
    sk = os.environ.get("BAIDU_MAP_SK")
    if not ak or not sk:
        sys.exit("缺少 BAIDU_MAP_AK / BAIDU_MAP_SK，请先 source .env.local")
    return ak, sk


def _mask(text, ak, sk):
    return text.replace(ak, "***AK***").replace(sk, "***SK***")


def signed_get(path, params, timeout=25):
    """params 必须是「最终 URL 中的出现顺序」，GET 请求不按字典序排序。

    timeout 到点只断开本地连接，服务端仍可能继续处理并占着并发额度。
    路线规划服务个人认证只有 3 并发，因此超时后不要立刻重发同一请求。
    """
    ak, sk = _secrets()
    query = "&".join(f"{k}={v}" for k, v in params)
    query_str = f"{path}?{query}"
    encoded = urllib.parse.quote(query_str, safe=SAFE)
    sn = hashlib.md5(urllib.parse.quote_plus(encoded + sk).encode("utf8")).hexdigest()
    url = f"{HOST}{encoded}&sn={sn}"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return _mask(resp.read().decode("utf-8", "replace"), ak, sk)
    except Exception as exc:
        return _mask(f"EXC {exc}", ak, sk)


def place_detail(uid, scope=2, ret_coordtype="bd09ll"):
    """地点详情检索。先试 v3，失败再退回 v2。"""
    ak, _ = _secrets()
    for path in ("/place/v3/detail", "/place/v2/detail"):
        params = [
            ("uid", uid),
            ("scope", str(scope)),
            ("ret_coordtype", ret_coordtype),
            ("output", "json"),
            ("ak", ak),
        ]
        raw = signed_get(path, params)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            print(f"{path}: 非 JSON 响应 -> {raw[:200]}")
            continue
        status = data.get("status")
        print(f"{path}: status={status} message={data.get('message')}")
        if status == 0:
            return path, data
    return None, None


if __name__ == "__main__":
    # 不在源码里写默认 UID：POI UID 可反查地点，按 GIT_COMMIT_RULES §3.4 属私人信息。
    target = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("HOME_POI_UID")
    if not target:
        sys.exit("用法: baidu_place.py <POI_UID>，或先 source tools/.env.places")
    used_path, payload = place_detail(target)
    if payload is None:
        sys.exit(1)
    print("\n=== 命中接口 ===", used_path)
    print(json.dumps(payload, ensure_ascii=False, indent=2)[:2500])
