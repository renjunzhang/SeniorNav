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
延迟数字、字段完整性结论都只能来自真机运行**。开发机上没有可替代真机的模拟器
（检索结果依赖百度服务端鉴权）。

**当前进度（2026-11-13）**：修正版已在鉴权状态 0 后完成一轮六项严格串行检索，
五项 `NO_ERROR`、短途公交 `RESULT_NOT_FOUND`。两份公交各 5 条方案，共 15 个乘车段的
关键字段无缺失；详见 [ADR 0003 §8](../../docs/adr/0003-AndroidSDK检索组件静态探针.md)。
初版暂用 SDK 薄通道（[ADR 0006](../../docs/adr/0006-初版采用AndroidSDK薄通道.md)），
但 p95、同段备选和站数关系仍待补证，不代表 D1 最终验收全部通过。
此前 Context 崩溃与六项 `PERMISSION_UNFINISHED` 的记录保留，不能作为有效性能样本。

| OD | 公交耗时/结果 | 步行耗时/结果 |
|---|---|---|
| metro_direct | 903 ms / NO_ERROR | 538 ms / NO_ERROR |
| bus_transfer | 1121 ms / NO_ERROR | 480 ms / NO_ERROR |
| walk_short | 410 ms / RESULT_NOT_FOUND | 234 ms / NO_ERROR |

原始公共地标 dump 和日志在本机 ignored 目录 `probe/build/results/2026-11-13-ready/`；
前次失败归档为 `probe/build/results/2026-11-13-init-failure/`。
以上只是发起至回调的单次耗时，不含初始化/定位/UI，不计算或宣称 p95。

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

探针原始输出保留 SDK 错误：本轮短途公交的 dump 是
`status=-1 / SDK error: RESULT_NOT_FOUND`，因此直接走现有解析器会显示拒绝，**不是探针未完成**。
主 App 的生产适配层才将该路线枚举归一化为空 `routes`，并另保留 `sdkError`；
不要为让原始 dump 看起来成功而覆盖它。鉴权/网络错误绝不能作同样归一化。

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
export ANDROID_HOME=<Android SDK 路径>   # Windows Git Bash: /c/Users/<你>/AppData/Local/Android/Sdk

# Linux/macOS
~/.gradle/wrapper/dists/gradle-9.3.1-all/*/gradle-9.3.1/bin/gradle :probe:assembleDebug
# Windows Git Bash（注意是 gradle.bat，且缓存目录在 USERPROFILE 下）
"$USERPROFILE"/.gradle/wrapper/dists/gradle-9.3.1-all/*/gradle-9.3.1/bin/gradle.bat :probe:assembleDebug
```

用 Flutter 自带的 Gradle 缓存，不必另装 Gradle；路径里的 hash 目录名各机不同，故用 `*`。

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
| `meta-data com.baidu.lbsapi.API_KEY` | 未注入时 `value=""`（**不是占位假值**）；注入后为真实 AK，已核对与注入值逐字符相等 |
| 签名 SHA-1 | `cd11338463a360589e9ab6468e8d8b8740e6b600`，与主 App 调试证书同一张 |
| 打进包的 ABI | arm64-v8a、armeabi-v7a、x86、x86_64（各含 base / c++_shared / tiny_magic 三个 `.so`） |
| `tools/scan_apk_secrets.py` | 服务端 AK/SK 与私人地点数据全部未命中 |

探针没设 `abiFilters`，所以四种 ABI 全打进去了；ADR 0003 里 3.11 MiB 的增量是
**只算 arm64-v8a** 的口径，真机按 arm64 装机时以此为准。

## 真机运行（需要 AK + 设备）

**联网检索统一调度**：主 App、SDK 探针与其他百度脚本不得同时运行请求。
一次只跑一轮六项，严格等待回调；不使用并行 shell、后台批量启动或自动重试。
探针与主 App 同包名；先确认没有尚未结束的请求，再替换安装包并开始已授权的新一轮。


```bash
adb install -r probe/build/outputs/apk/debug/probe-debug.apk
# 每次执行都应是明确批准的一轮，禁止用重启循环自动重试。
adb shell am force-stop com.seniornav.seniornav
adb shell am start -n com.seniornav.seniornav/com.seniornav.sdkprobe.ProbeActivity
adb logcat -s SDKPROBE
```

启动后先等待 SDK 初始化与鉴权状态 0，两个条件均满足才发第一条请求；
非零鉴权状态停止，不打印可能含凭据的鉴权 message。同一进程内 Activity 重建不会自动重跑。

logcat 每条请求给出 `<id> transit 延迟=…ms error=…`、`<id> walking 延迟=…ms`，
以及 `<id> 完整性：方案=N 乘车段=N 缺direction=… 缺stopNum=… 缺首末班=…`。
六条都跑完会印 `DONE`。若某条印 `发起=false`，队列立即停止，迟到回调只落盘、不推进。
修复原因并获得新一轮授权后才能手动重启；先归档旧 dump，避免覆盖失败证据。

```bash
for id in metro_direct bus_transfer walk_short; do
  for mode in transit walking; do
    adb pull /sdcard/Android/data/com.seniornav.seniornav/files/sdk_probe_${id}_${mode}.json /tmp/
  done
done
```

再跑上面的 `parse_sdk_dump.dart`。字段结果、原始错误、延迟与日志一起交回。
本轮虽有有效样本，但每个 `steps` 内组长度都是 1，不能据此签同段备选语义；
也没有经过站列表可验证站间数关系。新增测试必须明确要补哪项证据，不能盲目重复六次。

## 两个已知约束

- **同包名不能共存**：探针默认 `applicationId` 与主 App 相同，同一台手机只能装一个。
  同签名时用 `adb install -r` 替换安装包，本轮已验证可切换；不要为切换探针清除主 App 的地点库。
  若版本/签名不兼容，先处理配置保留与安装条件，不直接卸载。若要共存，用 `-PprobeAppId=com.seniornav.sdkprobe`
  并为该包名**另申请一个 AK**。
- **起终点是公共地标**（见开头的三条 OD 表，坐标取自 `app/test/fixtures/`），
  不含私人位置。要测真实住址的效果，只能在手机本地改坐标，不入仓库。

## 与正式 App 的集成验证区别

独立 Java 探针只验证 SDK 本身。2026-11-13，正式 Flutter 薄通道又完成
`searchPoi → poiDetail → transit → walking` 四项公共地标串行 smoke：10 个候选、详情成功
（无 `navigationPoint`）、公交方向/站数/上下车站齐全、步行成功，`blocked=false`。
这是 `app/tool/live_sdk_smoke.dart` 的 debug 专用入口，必须显式启用 `RUN_LIVE_BAIDU_SMOKE`，
正式 main 不引用，也不获取手机实际位置；不是让普通单元测试联网的入口。

主 App 已完成 debug / release 构建，无 `.so` 合并冲突；全量 Flutter analyze 零问题、
108 项测试通过。初版数据源选择及未完成的验收见 ADR 0006，不能把 smoke 当成入口精度或老人使用验收。
