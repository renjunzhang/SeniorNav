# ADR 0003：Android SDK 检索组件静态探针

**状态**：静态验证完成（2026-11-12）。**运行时取值全部未验证**——没有 Android-端 AK，未做任何实调。D1 不因此关闭。

**背景**：[ADR 0002](0002-路线数据源WebAPI实测.md) 的 D1 要在 A（Web API + 代理）与 B（Android SDK 本地检索）之间选一条。
本 ADR 完成 B 路中**不需要真机、不需要 AK** 的那一半：制品形态、体积、API 表面、字段覆盖。
方法全部是静态检查：Maven Central 下载制品、解压、`javap` 看签名、反编译解析器看 JSON 键到 setter 的映射。

---

## 1. 制品：检索组件可脱离地图组件

官方产品是 **Android 地图 SDK**，公交/步行路线规划在其**检索组件**里。导航是独立组件（`-Navi`/`-BWNavi`/`-AllNavi`），**不引入**。

正确 Maven 坐标（group 是 `com.baidu.lbsyun`，不是 `lbsapi`——ADR 0002 旧结论的 404 是坐标写错）：

```gradle
repositories { mavenCentral() }
implementation 'com.baidu.lbsyun:BaiduMapSDK_Search:9.0.0'   // 传递依赖 base → common
```

| 制品 | 字节 | sha256 |
|---|---|---|
| `BaiduMapSDK_Search-9.0.0.aar` | 399,956 | `731ce63472bd9e28c073e81af12d12311132bc7e0e8dd2968f0f6166ec645db9` |
| `base-9.0.0.aar` | 3,538,463 | `83f2ee1547e789ccc835458fe8569da1c99ce48489925ca9133241217b6a6ff9` |
| `common-1.0.43.aar` | 107,692 | 见 Central 公布值 |
| `BaiduMapSDK_Util-9.0.0.aar`（可选） | 57,329 | `20978bf6f1b2b04fd36e6e06ca4785d698aca1ed05ac981c64b0c60f21f1764b` |
| `BaiduMapSDK_Map-9.0.0.aar`（仅对比，不引入） | 57,615,570 | `162250e775f35642b49317a7391badfb3edadad71397af6ec49183232aedbf12` |

四个 AAR 的 sha1 与 Central 公布的 `.aar.sha1` 逐字节吻合。

**Search 不依赖 Map**，三重证据：① Gradle module 依赖链只有 `Search → base → common`；
② Search 的 394 个 class 常量池里 `com/baidu/mapapi/map/*` 引用数为 0；③ base 同样为 0。

### 体积与 .so

`.so` 全在 base，Search/Util/Map 的 aar 里只有 `classes.jar`。base 带 4 个 ABI × 3 个库
（`libBaiduMapSDK_base_v9_0_0.so`、`libc++_shared.so`、`libtiny_magic.so`）。

| 组合 | 全 ABI 解包 | 仅 arm64-v8a |
|---|---|---|
| Search + base + common | 8,532,591 B（8.14 MiB） | **3,263,311 B（3.11 MiB）** |
| 再加 Util | 8,595,790 B | 3,326,510 B |
| 若改用 Map | Map 单组件 .so 全 ABI 71,895,992 B | arm64 18,442,752 B |

对照：当前 release APK 48.0 MB。只保留 arm64 时 B 路增量约 3.1 MiB，可接受；
但老人机型未必都是 arm64，**abiFilters 取舍要等真机机型确定后再定**。

## 2. 两套并行 API，选新的

- 旧：`transitSearch()` → `TransitRouteResult` / `TransitRouteLine$TransitStep` / `VehicleInfo`
- 新：`masstransitSearch()` → `MassTransitRouteResult` / `MassTransitRouteLine$TransitStep` / `BusInfo`

官方文档原文：「官方建议优先使用跨城综合公交路线规划，**市内公交路线规划（transit）功能不再新增特性**」。
且新 API 解析器读的 JSON 键与 [app/lib/baidu_route_parser.dart](../../app/lib/baidu_route_parser.dart) 现用的
`detail.first_time/last_time/on_station/off_station` 完全一致；旧 API 用 `start_time/end_time`。
**选 `masstransitSearch`**，适配层可复用现有解析语义。

注意类名：`TransitRouteStep`、`TransitRouteVehicleInfo` 这两个名字**不存在**，真实是嵌套类
`TransitRouteLine$TransitStep` 与 `core.VehicleInfo` / `core.BusInfo`。

## 3. 字段覆盖：13/13 有 getter

`javap` 实录（JDK 21，完整 dump 存于探针工作目录，未入库）：

| 模型字段 | 判定 | 新 API getter | 旧 API getter |
|---|---|---|---|
| `lineName` | 有 | `BusInfo.getName()` | `VehicleInfo.getTitle()` |
| `lineType` | 有（语义未验证） | `BusInfo.getType()` | `TransitStep.getStepType()` |
| **`direction`** | **有** | **`BusInfo.getDirectText()`** | `VehicleInfo.getDirectText()` |
| `boardStop` | 有 | `BusInfo.getDepartureStation()` | `TransitStep.getEntrance().getTitle()` |
| `alightStop` | 有 | `BusInfo.getArriveStation()` | `TransitStep.getExit().getTitle()` |
| `stopCount` | 有 | `BusInfo.getStopNum()` | `VehicleInfo.getPassStationNum()` |
| `firstTime` | 有 | `BusInfo.getDepartureTime()` | `VehicleInfo.getStartTime()` |
| `lastTime` | 有 | `BusInfo.getArriveTime()` | `VehicleInfo.getEndTime()` |
| `boardWalkM` | 有 | 前置步行 step 的 `getDistance()` | 同 |
| `durationSec` | 有 | `RouteLine.getDuration()` | 同 |
| `distanceM` | 有 | `RouteLine.getDistance()` | 同 |
| `walkM` | 有 | 步行 step `getDistance()` 求和 | 同 |
| `crossingCount` | 有 | `WalkingStep.getInstructions()` | 同 |
| `arriveTime`（附带） | 新有 / 旧无 | `MassTransitRouteLine.getArriveTime()` | 无 |

### direction 的红线在 SDK 侧守得住

反编译 masstransit 解析器 `com.baidu.platform.core.route.i` 的字节码，JSON 键 → setter 序列为：

```
vehicle_info → type → detail → setVehileType
name → setName ／ type → setType ／ stop_num → setStopNum
on_station → setDepartureStation ／ off_station → setArriveStation
first_time → setDepartureTime ／ last_time → setArriveTime
direct_text → setDirectText        ★
```

即 SDK 内部解析的就是 Web API 同一个 `direct_text` 键，**不是线路 title、也不是下车站**。
ADR 0002 A2 那条红线（方向 ≠ 下车站）在 B 路同样成立。

### 命名陷阱（已验证，极易写错）

- `TransitBaseInfo.getDepartureTime()` 装的是 **`first_time` 首班**，`getArriveTime()` 装的是 **`last_time` 末班**；
  而 `MassTransitRouteLine.getArriveTime()` 才是「预计到达时间」。同名不同义，适配层必须按上表映射，不能望文生义。
- `getVehileType()` 是官方原文拼写（少一个 c），枚举 `ESTEP_BUS/ESTEP_WALK/ESTEP_TRAIN`。
- `WalkingStep.getDirection()` 返回 **int 方位角**，不是「开往 X」，别误用。

## 4. 接入成本

- **不需要 MapView**：`RoutePlanSearch.newInstance()` 无 Context 参数，字节码只 `BMapManager.init()` 后 new 自身。
- **AK 两条路**：Manifest `meta-data com.baidu.lbsapi.API_KEY`（`PermissionCheck` 字节码 `ldc` 该字符串），
  或 `SDKInitializer.setApiKey(String)` / `initialize(String ak, Context)`。
- **隐私合规硬门槛**：`SDKInitializer.setAgreePrivacy(context, true)` 必须在 `initialize` **之前**，
  否则官方明确「不支持发起检索、路线规划等数据请求」。V1 的隐私说明要与此一致。
- **AAR 自带 manifest 极简**：五个 AAR 都只有 `<uses-sdk minSdkVersion="21"/>`，
  **零 uses-permission、零 Service/Receiver/Provider 声明**，不强制位置权限。
  代码里出现的权限字符串无 `ACCESS_FINE_LOCATION`。但 base 内含未声明的
  `com.baidu.mshield.MyProvider`(ContentProvider) 与 `rp.Receiver`(BroadcastReceiver)，属安全加固模块，需知情。
- **版本约束**：minSdk 21（工程现 24，满足）；class 字节码 Java 7/8，无 Kotlin、无 androidx 依赖；
  五个 AAR 的 `proguard.txt` 均 0 字节，无 consumer rules。HTTPS 自 5.3.2 默认开启。

## 5. 未验证与风险（D1 不关闭的原因）

1. **无 AK，所有 getter 的运行时取值未验证。** 上表全部是签名与字节码证据，没有一条来自真实响应。
   - `BusInfo.getType()` 的 0=公交/1=地铁 语义未验证（只证明直取 `detail.type`，是否重映射未知）。
   - `getDirectText()` 实际字符串内容未验证（是否形如「合肥火车站方向」、是否可能为空）。
     ADR 0002 A2 的样本必须拿到 AK 后重跑才能签 D1。
   - `getStopNum()` 是否仍等于 `getPassStopInfoList().size()+1` 未验证。
2. **`libc++_shared.so` 打包冲突未测**：base 每个 ABI 带一份（arm64 1,292,440 B），
   与 Flutter engine 共存时是否需要 `pickFirst` 未验证。
3. **延迟未测**：B 路本地检索的耗时无从静态得知，§6.2 的 p95 3 秒要求只能真机验。
4. POM 的 `<url>`/`<scm>` 指向 `github.com/lbs-mapsdk/lbs-trace`（API 404），是占位值；
   制品可信度靠 sha1 与官方文档引用同坐标支撑，不靠 POM 链接。
5. 官网勾选式一体化包（`BaiduLBS_Android.jar` 形态）未获取，本 ADR 全程走 Maven Central。
6. 官方文档「支持 Android v4.0 以上」与 AAR `minSdkVersion=21` 矛盾，**以 AAR 为准**。

## 6. 对 D1 的影响

B 路在静态层面**没有可见阻塞项**：字段 13/13 覆盖、direction 同源、检索可脱离地图、arm64 增量约 3.1 MiB、
不强制位置权限。A 路的优势仍是「不依赖百度客户端 SDK 的合规与加固组件、字段语义已实测」。

**D1 保持开放**，关闭条件不变：拿到 Android-端 AK 后重跑 A2 样本与 `getType()` 语义，再上真机测延迟与调起。
在那之前，现有 Web API 实现与 65 个测试不动。