# Search SDK 最小运行时探针（M0）

只验证三件事：**公交/步行检索能否返回、字段是否够填满 RouteSummary、延迟多少**。
不做导航、不引入 Map / Navi 组件（ADR 0003）。

跑的是**与 `app/test/fixtures/` 完全相同的三条 OD**，串行 6 次请求（每条 OD 先公交后步行）：

| id | 起点 → 终点 | 对照的 Web API 结果 |
|---|---|---|
| `metro_direct` | 合肥南站-地铁站 → 合肥火车站 | 5 条方案，含地铁直达与换乘 |
| `bus_transfer` | 大蜀山森林公园 → 安徽省立医院 | 5 条方案，含 0 换乘地铁与 1 换乘公交 |
| `walk_short` | 合肥南站 → 合肥南站-地铁站（95 米） | **`status==0` 且 `routes` 为空**，测 SDK 怎么表达「没有公交方案」 |

全是公共地标，不含私人位置。

**静态与真机的边界**：本工程可以在开发机上编译（不需要 AK），但**任何检索调用、
延迟数字、字段完整性结论都只能来自真机运行**。开发机上没有 Android-端 AK，
也没有可替代真机的模拟器（检索结果依赖百度服务端鉴权）。

## 它怎么复用现有代码

探针把 SDK getter 序列化成 **Web API 的 JSON 形状**（`vehicle_info.detail.direct_text`、
`on_station`、`first_time`…），并且**保留 `steps` 的分组结构**（不拍平），
落盘成 `sdk_probe_<id>_<transit|walking>.json` 六个 dump。然后：

```bash
cd app
for id in metro_direct bus_transfer walk_short; do
  for mode in transit walking; do
    dart run tool/parse_sdk_dump.dart /tmp/sdk_probe_${id}_${mode}.json $mode
  done
done
```

`parse_sdk_dump.dart` 直接调现有的 `parseTransit` / `parseWalking` / `selectRoute` /
`renderSummary`。**SDK 字段够不够，用 V1 真正会走的那条代码路径判定**，不另写映射。
缺失字段会逐条列出来（`缺失: direction,stopNum` 这种）。

## 你需要提供的：Android-端 AK

服务端 AK **不能**用于 SDK。步骤：

1. 登录 <https://lbs.baidu.com> 控制台 → 应用管理 → 我的应用 → 创建应用。
2. 应用类型选 **Android SDK**。
3. 包名填 `com.seniornav.seniornav`（探针默认与主 App 同包名，一个 AK 两处通用）。
4. SHA1 填调试签名：
   `CD:11:33:84:63:A3:60:58:9E:9A:B6:46:8E:8D:8B:87:40:E6:B6:00`
   （当前 release 也用调试签名，故同一个 SHA1；换正式 keystore 后需回控制台更新。）
5. 创建后把得到的 AK 通过下面任一方式交给构建，**不要写进任何会入库的文件**：
   ```bash
   export BAIDU_ANDROID_AK='…'        # 本机环境变量
   # 或构建时 -PbaiduAk='…'
   ```

注意：Android-端 AK 会明文进入探针 APK 的 manifest——这是它的设计（靠包名+SHA1 防盗用），
与服务端 AK/SK 的威胁模型不同。但**探针包仍不要外发**。

## 编译（开发机即可，不需要 AK）

```bash
cd tools/sdk-probe
~/.gradle/wrapper/dists/gradle-9.3.1-all/*/gradle-9.3.1/bin/gradle :probe:assembleDebug
```

复用本机已缓存的 Gradle 9.3.1 / AGP 9.1.0（与主 App 同版本）；纯 Java，无 Kotlin 插件。
依赖 `com.baidu.lbsyun:BaiduMapSDK_Search:9.0.0`（传递 base → common）。
**首次编译要联网**：AGP 9.1.0 传递依赖 `kotlin-gradle-plugin:2.2.10`，本机没缓存，
加 `--offline` 会在解析 classpath 时失败。

### 编译产物已核对（2026-11-12，开发机静态验证）

`BUILD SUCCESSFUL`，`probe-debug.apk` = 8,664,157 B（8.26 MiB）。用 build-tools 36.0.0 核对：

| 项 | 实测值 |
|---|---|
| 包名 | `com.seniornav.seniornav`（与主 App 一致） |
| minSdk / targetSdk | 24 / 36 |
| 权限 | 只有 `INTERNET`、`ACCESS_NETWORK_STATE` |
| `meta-data com.baidu.lbsapi.API_KEY` | `value=""` —— **未注入 AK 时是空串，不是占位假值** |
| 签名 SHA-1 | `cd11338463a360589e9ab6468e8d8b8740e6b600`，与主 App 调试证书同一张 |
| 打进包的 ABI | arm64-v8a、armeabi-v7a、x86、x86_64（各含 base / c++_shared / tiny_magic 三个 `.so`） |
| `tools/scan_apk_secrets.py` | 服务端 AK/SK 与私人地点数据全部未命中 |

探针没设 `abiFilters`，所以四种 ABI 全打进去了；ADR 0003 里 3.11 MiB 的增量是
**只算 arm64-v8a** 的口径，真机按 arm64 装机时以此为准。

## 真机运行（需要 AK + 设备）

```bash
adb install -r probe/build/outputs/apk/debug/probe-debug.apk
adb shell am start -n com.seniornav.seniornav/com.seniornav.sdkprobe.ProbeActivity
adb logcat -s SDKPROBE
```

logcat 每条请求给出 `<id> transit 延迟=…ms error=…`、`<id> walking 延迟=…ms`，
以及 `<id> 完整性：方案=N 乘车段=N 缺direction=… 缺stopNum=… 缺首末班=…`。
六条都跑完会印 `DONE`。若某条印 `发起=false`，队列会停在那里（不自动跳过，
避免与迟到的回调重复推进），检查 AK/网络后重启探针即可，已落盘的结果仍有效。

```bash
for id in metro_direct bus_transfer walk_short; do
  for mode in transit walking; do
    adb pull /sdcard/Android/data/com.seniornav.seniornav/files/sdk_probe_${id}_${mode}.json /tmp/
  done
done
```

再跑上面的 `parse_sdk_dump.dart`。把六个 dump 与 logcat 片段交回即可签 D1 的字段部分。

## 两个已知约束

- **同包名不能共存**：探针默认 `applicationId` 与主 App 相同，同一台手机只能装一个。
  测完探针卸载再装主 App；若要共存，用 `-PprobeAppId=com.seniornav.sdkprobe`
  并为该包名**另申请一个 AK**。
- **起终点是公共地标**（见开头的三条 OD 表，坐标取自 `app/test/fixtures/`），
  不含私人位置。要测真实住址的效果，只能在手机本地改坐标，不入仓库。