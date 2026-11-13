# ADR 0003：Android SDK 检索组件静态探针

**状态**：静态验证与首轮有效真机检索已完成（2026-11-13）。修正版在鉴权状态 0 后
串行完成六项：五项 `NO_ERROR`，短途公交 `RESULT_NOT_FOUND`；两份公交共 15 个乘车段的
关键字段齐全。Flutter + SDK 的完整 debug / release APK 已构建，无 `libc++_shared.so` 冲突；
正式 Flutter 薄通道也通过一次公共地标的四项串行 smoke。
初版暂采用 B 路，见 [ADR 0006](0006-初版采用AndroidSDK薄通道.md)；
**p95、同段备选和站间数关系仍未完成最终验收，D1 不能记成全部通过**。
此前 Context 崩溃与 `PERMISSION_UNFINISHED` 失败记录保留在 §7，有效结果见 §8。

**背景**：[ADR 0002](0002-路线数据源WebAPI实测.md) 的 D1 要在 A（Web API + 代理）与 B（Android SDK 本地检索）之间选一条。
本 ADR 的 §1–4 最初记录 B 路中**不需要真机、不需要 AK** 的静态部分：制品形态、体积、API 表面、字段覆盖。
方法为 Maven Central 制品核验、`javap` 与解析器字节码检查；§7–9 追加真机结果和主 App 集成证据。

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

历史对照：2026-11-12 的 release APK 约 48.0 MB。上表仅 arm64 的 3.11 MiB 是解包制品体积，
**不是同配置 APK 的实测增量**；主 App 集成结果见 §9。
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
- **回调 setter 名字易写错**：真实签名是 `setOnGetRoutePlanResultListener(OnGetRoutePlanResultListener)`，
  **不存在** `setRoutePlanListener`。检索入口为 `masstransitSearch(MassTransitRoutePlanOption)` /
  `walkingSearch(WalkingRoutePlanOption)`，起终点用 `PlanNode.withLocation(LatLng)`
  （在 `com.baidu.mapapi.search.route` 包），坐标类型 `.coordType("bd09ll")`。
  以上均由 `javap` 核对，并已在探针工程里编译通过。
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

### 运行时探针工程（以下为 2026-11-12 静态基线，后续运行见 §7–8）

`tools/sdk-probe/` 是纯 Java 的最小 Android 工程，只做一件事：对**与 fixtures 相同的三条 OD**
串行调 `masstransitSearch` 与 `walkingSearch`（共 6 次请求），把结果与耗时落盘。
开发机实测（2026-11-12）：

| 项 | 值 |
|---|---|
| 构建 | `BUILD SUCCESSFUL`；Gradle 9.3.1 + AGP 9.1.0（与主 App 同版本）。首次需联网：AGP 传递依赖 `kotlin-gradle-plugin:2.2.10` 本机无缓存，`--offline` 会失败 |
| 产物 | `probe-debug.apk` 8,664,157 B（8.26 MiB），sha256 前 16 位 `d14c6b6e02aea6ac` |
| OD 覆盖 | `metro_direct`（地铁直达+换乘）、`bus_transfer`（0 换乘地铁 vs 1 换乘公交）、`walk_short`（95 米，Web API 侧返回空 routes）——第三条专门测 SDK 如何表达「没有公交方案」 |
| 包名 / 签名 | `com.seniornav.seniornav`；SHA-1 与主 App 调试证书**同一张** → 一个 Android-端 AK 两处通用，代价是两包不能共存 |
| 权限 | 只有 `INTERNET`、`ACCESS_NETWORK_STATE` |
| AK | 构建期注入（`-PbaiduAk` 或 `BAIDU_ANDROID_AK`）；未注入时 manifest 的 value 是**空串**，不是假占位值 |
| ABI | 四种全打进包（未设 `abiFilters`）；§1 的 3.11 MiB 是**仅 arm64** 口径 |
| 密钥扫描 | `tools/scan_apk_secrets.py`：服务端 AK/SK 与全部私人地点字段未命中 |

**复用而非另写映射**：探针把 SDK getter 序列化成 Web API 的 JSON 形状
（`direct_text`/`on_station`/`off_station`/`stop_num`/`first_time`/`last_time`…），落盘后由
`app/tool/parse_sdk_dump.dart` 交给现有的 `parseTransit`/`parseWalking`/`selectRoute`/`renderSummary`。
**字段够不够，用 V1 真正会走的那条代码路径判定**，缺失字段逐条列出，不另写一套适配逻辑。

起终点是公共地标（合肥南站 → 合肥火车站，坐标取自 `app/test/fixtures/`），不含私人位置。
运行与 AK 申请步骤见 `tools/sdk-probe/README.md`；URI 调起侧的真机测试见
`docs/m0/真机导航测试清单.md`。

## 5. 未验证与风险（D1 不关闭的原因）

1. **字段运行时取值已取得首轮证据，覆盖仍有限。** §8 的 15 个乘车段关键字段无缺失，
   `getType()` 的 0=普通公交、1=轨交在本轮对应，并出现 type=10 专线；未知类型不能强归普通公交。
   `getDirectText()` 已观察到与下车站不同的真实方向文本。
   `getStopNum()` 全部为正，但 dump 没有经过站数组，**是否等于 `getPassStopInfoList().size()+1` 仍未直接核验**。
2. **Flutter 共存构建已通过；同配置 APK 增量仍待量测。** 主 App + SDK 的完整 debug / release APK
   未出现 `libc++_shared.so` 冲突，无需添加无证据的 `pickFirst`。debug 体积不能与旧 release 直接相减。
3. **首轮请求延迟已测，p95 未验收。** §8 记录的是一次发起至回调的六个耗时，
   不含初始化、定位、Flutter 渲染；三个 OD 也不足以判断 §6.2「点击后摘要 p95 ≤ 3 秒」。
   §7 的 `PERMISSION_UNFINISHED` 毫秒数仍只是拒绝耗时，不并入性能样本。
4. **同段备选线路的语义未验证。** 本轮两份公交各有 5 条方案，但所有 `getNewSteps()` 内组长度
   都是 1，没有「同一组多条可选车辆」样本；不能据此声明同段备选语义已通过。
   适配继续保留 `List<List<TransitStep>>`，不拍平；已有解析器沿用每组选择一条车辆段的规则。
5. POM 的 `<url>`/`<scm>` 指向 `github.com/lbs-mapsdk/lbs-trace`（API 404），是占位值；
   制品可信度靠 sha1 与官方文档引用同坐标支撑，不靠 POM 链接。
6. 官网勾选式一体化包（`BaiduLBS_Android.jar` 形态）未获取，本 ADR 全程走 Maven Central。
7. 官方文档「支持 Android v4.0 以上」与 AAR `minSdkVersion=21` 矛盾，**以 AAR 为准**。

## 6. 对 D1 的影响

B 路现已取得首轮有效路线响应，且不需要 MapView；初版决定采用 SDK 薄通道，
完整理由和可替换边界见 [ADR 0006](0006-初版采用AndroidSDK薄通道.md)。
这是一项**初版实现选择**，不是把原有四项最终验收全部勾绿：

- [x] Android-端 AK 真机跑通 `masstransitSearch`；`getDirectText()` 已观察到方向 ≠ 下车站。
- [ ] `getType()` 0/1 已有实例，type=10 保留未知；`getStopNum()` 与中途站数关系待补证。
- [ ] 点击至摘要的 p95 3 秒、同段备选分组语义仍待验证。
- [ ] Flutter + SDK 共存构建已通过；同配置 APK 增量尚未取得。

用户明确要求总调度与子代理加速并行开发后，UI、存储与数据源按可替换接口推进。
因此「零项完成、M1 不开工」的旧状态已失效，但不能把尚未知的验收项当成通过。
若后续有效响应或性能不能满足使用需要，可把 `RouteService`/`PoiService` 切换到 A 路无状态代理，
不重写界面、地点库和摘要规则。

既有 Web API fixture 与解析/摘要逻辑继续复用；它们对 A/B 两路均有效。

## 7. 真机启动问题与修复（2026-11-13）

设备：MEIZU Note 16 Pro / Android 15，仍只使用公共地标 OD，不申请定位权限。

### 已观察到的失败

1. 初次启动在 `setAgreePrivacy` 抛出 `BDMapSDKException: context must be an ApplicationContext`，
   **尚未调用路线检索**。改为 `getApplicationContext()`，初始化也使用相同 Context。
2. 修正 Context 后，探针在 SDK 鉴权尚未完成时立即发请求。六项均 `发起=false`，
   随后仍收到 `PERMISSION_UNFINISHED` 回调；旧代码虽然记录「队列停止」，回调却继续推进下一项。
   六个 dump 经现有 `parse_sdk_dump.dart` 均判为 `RouteRejected`，不是空路线。

| OD | 公交拒绝耗时 | 步行拒绝耗时 | 结果 |
|---|---:|---:|---|
| metro_direct | 82 ms | 87 ms | PERMISSION_UNFINISHED |
| bus_transfer | 17 ms | 5 ms | PERMISSION_UNFINISHED |
| walk_short | 1 ms | 4 ms | PERMISSION_UNFINISHED |

这些数字**不能用于路线延迟或 p95 结论**，也不证明 AK 无效或 B 路不可用。
本轮没有并行发起或自动重发同一 OD；但 `false` 后仍推进队列的缺陷必须修掉。
原始六个 JSON 与仅含 SDKPROBE 标签的日志保存在本机 ignored 目录
`tools/sdk-probe/probe/build/results/2026-11-13-init-failure/`。

### 已完成的代码修复

- 成功枚举应为 `SearchResult.ERRORNO.NO_ERROR`，不是 `error == null`；
  已由 SDK 9.0.0 的 `SearchResult` 构造器字节码核验。原代码会把正常响应写成拒绝。
- `setAgreePrivacy` 与 `initialize` 使用 Application Context。
- 先注册 `RequestAuthResultListener`，等待鉴权状态 0 与初始化完成回调后，只启动一次队列。
  不打印鉴权 message，避免带出凭据或设备标识。
- 回调投递到主线程消息队列，确保发起结果先被处理；`false` 后锁住队列，迟到回调仅记录。
  Activity 销毁时解绑监听，同一进程内重建不自动重跑。

修正版 `assembleDebug` 已通过；上述失败后曾暂停继续发请求，保留失败证据。
后续在用户授权加速开发后执行了一轮严格串行验证，见 §8；不能把启动修复本身当成路线验收结果。


## 8. 修正版有效真机检索（2026-11-13）

设备同 §7。先收到 SDK 鉴权状态 0，再按「公交 → 步行 → 下一 OD」串行发起，
六项均 `发起=true`，完成后输出 `DONE`；本轮无并行、无自动重试。
原始公共地标 JSON 与 SDKPROBE 日志保存在本机 ignored 目录
`tools/sdk-probe/probe/build/results/2026-11-13-ready/`，不含家庭地点。

| OD | 模式 | 发起至回调 | SDK 结果 | 返回方案 |
|---|---|---:|---|---:|
| metro_direct | 公交 | 903 ms | NO_ERROR | 5 |
| metro_direct | 步行 | 538 ms | NO_ERROR | 1 |
| bus_transfer | 公交 | 1121 ms | NO_ERROR | 5 |
| bus_transfer | 步行 | 480 ms | NO_ERROR | 1 |
| walk_short | 公交 | 410 ms | RESULT_NOT_FOUND | 无 |
| walk_short | 步行 | 234 ms | NO_ERROR | 1 |

两份公交分别有 8 / 7 个乘车段。离线逐字段检查：线路名、方向、上下车站、站数、首末班
在共 15 段中均无缺失；站数均为正。类型为普通公交 0（12 段）、轨交 1（2 段）、
专线 10（1 段，名称「质子公交专线」）。领域层对 10 保留 `unknown`，不能误称已覆盖所有类型。

方向例证（全部公共线路）：

| 线路 | `direct_text` | `off_station` | 判断 |
|---|---|---|---|
| 轨道交通 1 号线 | 张洼方向 | 合肥火车站 | 方向不是下车站 |
| 85 路 | 合肥火车站方向 | 长丰路桥站 | 不能用下车站替代行驶方向 |

短途公交的 `RESULT_NOT_FOUND` 与 Web API 的 `status=0, routes=[]` 表达不同。
**原始探针 dump 保留 `status=-1 / SDK error: RESULT_NOT_FOUND`，不覆写历史证据**；
主 App 适配层将路线 `RESULT_NOT_FOUND` 和 `ST_EN_TOO_NEAR` 映射为空路线，保留 `sdkError`。
其中 `RESULT_NOT_FOUND` 已在本次 95 米公共 OD 观察到，`ST_EN_TOO_NEAR` 的映射仍是语义处理，
本轮并未实际返回该枚举。鉴权、网络、配额等其他错误不能归为空路线。

本轮单次请求均低于 3 秒，但**不等于端到端 p95 验收通过**；同段备选和经过站关系仍见 §5。

## 9. 主 App 集成与并发防线（2026-11-13）

- Flutter + Search SDK 9.0.0 完整 debug APK 为 **191,122,871 B**；本轮 release 首构建为
  **57,384,095 B**（约 57.4 MB，十进制）。两种构建的 `libc++_shared.so` 合并均未冲突，
  没有添加 `pickFirst`。debug 不能与旧 release 相减；历史 release 约 48.0 MB 也只作不同轮次参考，
  因 ABI/配置与新增定位、存储等依赖未做严格匹配，**不能将差额全归因于 SDK**。
- `MethodChannel('seniornav/baidu')` 提供路线与 POI 薄通道；只有用户同意说明后才初始化 SDK。
  关键响应继续交给已有 Dart 解析器、选路与摘要规则。
- Dart 的一个操作锁覆盖初始化、定位、公交、步行、按需少换乘补查以及 POI。
  原生再用进程级单请求 gate 兜底；不并发、不自动重试，离开页面不释放未结束请求。
- 30 秒等待超时返回 `SESSION_BLOCKED`，Dart 锁住本次会话，原生仍等真实回调；
  SDK 网络超时/网络错误或发起 false 采用保守阻断，不假设服务器并发槽已释放。
  每请求独立 search 实例与 token，迟到/重复回调不能释放新请求。
- 原生 gate 的 **8 项纯 JVM 断言已通过**：包括并发拒绝、UI 超时不释放、真实回调释放、
  旧 token 不影响新请求、SDK 不确定结果阻断、false 后迟到回调不重跑。
  `app/test/services_test.dart` 另覆盖跨路线/POI 串行、未同意时零调用、阻断后不继续检索、
  后续查询失败保留已有路线、原生公交使用当前位置等 Dart 防线；全量 `flutter analyze` 零问题、Flutter 测试 **108 项通过**；其中新增的部分结果保留和当前位置保护用例也已通过。
- 主 manifest 保持 `allowBackup=false`；定位仅为前台一次位置，声明 COARSE/FINE，
  未声明 `ACCESS_BACKGROUND_LOCATION`，不引入百度定位/导航/地图视图组件。
  AK 仅构建期注入；异常不输出 SDK 鉴权 message、坐标或凭据。

### 正式 Flutter 薄通道的公共地标 smoke

`app/tool/live_sdk_smoke.dart` 通过正式 Dart/原生服务执行
`searchPoi → poiDetail → transit → walking`，**四项严格串行**。结果：POI 候选 10 个，
详情成功但 `navigationPoint` 缺省，公交返回 1 个乘车段且方向/站数/上下车站齐全，步行成功，
完成后 `blocked=false`。这补上了独立 Java 探针之外的 Flutter 通道运行证据。

该入口只允许 debug 且显式启用 `RUN_LIVE_BAIDU_SMOKE`；正式 `main.dart` 不引用它，
普通单元/widget 测试不触发联网。使用公共地标坐标，不获取手机实际位置。
详情没有导航点时只能保留几何坐标并交由家属核对，不能凭检索成功声称入口正确。

当前证据不替代实际前台定位、家属地点保存与地图核对、完整 UI 真机流程、老人朗读和长期稳定性验收。
