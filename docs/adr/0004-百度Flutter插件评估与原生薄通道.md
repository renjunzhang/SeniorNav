# ADR 0004：百度官方 Flutter 插件评估——路线检索走原生薄通道，POI 检索有条件复用

**状态**：已接受（2026-11-12）。**本 ADR 不关闭 D1**：它只决定「若 D1 选 B（Android SDK），怎么接」，不决定 A/B 本身。
**关联**：[ADR 0002](0002-路线数据源WebAPI实测.md) A2/A4/A7、[ADR 0003](0003-AndroidSDK检索组件静态探针.md)、[ADR 0001](0001-坐标系统一为BD09.md) D2/D3、方案 §3.3/§3.7/§4.2/§6.2、`docs/research/开源项目复用调研.md` §3/§5/§7
**范围**：**全部是源码层与字节码层结论**。没有 Android 端 AK、没有真机，插件的任何运行时行为、检索延迟、字段实际取值一律未验证。

---

## 背景

方案 §4.2 的 D1 要在 A 路（Web API + 无状态代理）与 B 路（Android SDK）之间选一条。B 路原先的设想是自己写平台通道（ADR 0003）。调研发现百度有官方 Flutter 插件 `flutter_baidu_mapapi_search`，包着同一个 Maven 制品，表面上能省掉全部通道代码。本 ADR 回答：能不能直接用。

取证方式：百度系插件没有公开 GitHub 仓库，直接下载 pub.dev 发布包 tarball（含完整 Dart / Android Java / iOS Objective-C / 鸿蒙 ETS 源码），版本 **4.0.2+1（2026-11-06）**；关键 getter 用插件所 pin 的 `BaiduMapSDK_Search:8.2.0` AAR 做 `javap` 复核。

## 核验到的事实

### 1. `direct_text`（行车方向）在 Java 桥接层被完全丢弃

四步证据，全部可复核：

- **原生 AAR 有这个 getter**：`javap` 确认 `com.baidu.mapapi.search.core.BusInfo.getDirectText()` 存在。
- **插件的 Java bean 从不调用它**：`BMFBusVehicleInfo.java` 的构造函数全部赋值逻辑只有 `this.type = busInfo.getType();` 与 `this.passStationNum = busInfo.getStopNum();`；父类 `BMFMassBaseVehicleInfo` 只取 `getName()` / `getDepartureStation()` / `getArriveStation()` / `getDepartureTime()` / `getArriveTime()`。
- **Dart 侧没有这个字段**：`bmf_routevehicleInfo.dart` 的 `BMFBusVehicleInfo` 字段全集是 name / departureStation / arriveStation / departureTime / arriveTime / passStationNum / firstTime / lastTime / type。
- **四个包全部源码 grep `directtext|direct_text` = 0 命中**（search / base / utils / map，Dart + Java + Objective-C + ETS）。2026-11-12 复核仍为 0。
- **没有原始 map 逃生口**：回调是强类型 `void Function(BMFMassTransitRouteResult, BMFSearchErrorCode)`，拿不到未经 bean 裁剪的 JSON。

**后果**：用官方插件做公交摘要，「开往方向」必然缺失。而 `arriveStation` 是**下车站**，不是线路终点站——ADR 0002 §2.4 已实测过这个陷阱（`direct_text="张洼方向"` 而 `end_name="合肥火车站"`）。退化用 `arriveStation` 冒充方向，就精确复现 ADR 0002 A2 与方案 §8 要防的失效模式：**老人按摘要坐反方向的车**。方案 §3.3 把「线路名 + 方向」列为必备内容，§6.4 的 V2 门槛是「未出现指错方向/错站的阻断问题」。**这不是可以降级绕过的字段。**

**fork 补救可行但不划算**：结果 bean 是整体 gson 序列化的（`RouteLineSearchHandler.java:419`），给 Java bean 加一个 public 字段就会自动传到 Dart，修复约 6 行。但那意味着长期维护一个偏离上游的分支，而上游每几周发一版，且**没有 issue tracker 可上报**（homepage 是文档站）。对单人开发是真实负担。

**替代绕法已被否决**：`BMFBusLineResult.busLineDirection` 确实存在，但 `BMFBusLineSearchOption.busLineUid` 是 required，而插件同样丢掉了原生 `getLineUid()`（grep 0 命中）。按线路名反查会命中双向线路中的一条，方向不可靠，不能用来补安全关键字段。

### 2. 首末班的 Dart 注释与 Android 实现相反

- Java bean 的 `firstTime` / `lastTime` 注释写「iOS独有」，且 **Android 构造函数从不给它们赋值 → Android 上恒为 null**。
- 首末班数据并没有丢，它藏在父类的 `departureTime` / `arriveTime` 里（ADR 0003 §3 的字节码证据：`first_time → setDepartureTime`、`last_time → setArriveTime`）。
- 而 Dart 侧注释写的是 `/// 出发时间(BMFBusVehicleInfo时departureTime为空)`——**恰好与 Android 实现相反**。照 Dart 注释实现会认为公交段没有首末班，从而跳过 ADR 0002 A7 要求的运营时段校验：凌晨 2 点给老人推荐 4 小时后才发车的地铁。

### 3. POI / Suggestion 这一半是合格的

`BMFPoiDetailInfo` 暴露了 **`naviLocation`**（Android 侧确实调用 `poiDetailInfo.getNaviLocation()`）与 **`children`**（出入口子点，含 `uid` 与 `distance`），直接满足 ADR 0001 D2「导航终点存 navi_location，并额外记录 pv_rate 最高的那个门（含 uid）」。另有 `BMFSuggestionSearch`（输入提示）与 `BMFPoiSearch`（地点检索），对应方案 §3.6「搜索 → 选择 → 地图确认入口」的前两步。base 组件已暴露 `setApiKey` / `setAgreePrivacy`，ADR 0003 §4 的合规硬门槛在 Dart 侧有对应 API。

### 4. `utils` 调起不能替代 `app/lib/baidu_uri.dart`

它走百度 SDK 的 `BaiduMapRoutePlan` / `BaiduMapNavigation` 工具类，不是自己拼 URI，因此：无 `coord_type` 参数（由 SDK 内部决定，与 ADR 0001 D1 的 BD-09 全链路冲突）、**无 `index`/`target`**（M0 探针 C 的关键）、步行导航**无网页回退**（Dart 注释明写「步行、骑行导航设置该参数无效」）、`startCoord` 是 required（挡住 M0 探针 O1/J 的「省略 origin 试探自动定位」）、依赖原生 SDK 与 AK、无法在无真机环境单元测试。现有 `baidu_uri.dart` 每一项都更强，且已被 `app/test/baidu_uri_test.dart` 锁住。

### 5. 策略枚举实际有四套编号

`tactics_incity`（Web API，0–5）、`sy`（URI，0/2/3/4/5/6，没有 1）、`BMFMassTransitIncityPolicy`（插件检索，顺序与 `tactics_incity` 逐项一致）、`BMFOpenTransitPolicy` + SDK 内部重映射（插件调起：Dart `toMap()` 发 `index + 3`，Android `correctBusStrategy` 再 `-= 3` 并交换 0↔4，两边抵消但最终落到 SDK 哪一项在插件源码里看不出来）。**不能假设任何两套共用常量。** ADR 0002 A4 的「两套枚举」要升级为四套。

### 6. 步行导航有客户端版本门槛

插件 `bmf_open_navi_options.dart:9-22` 的版本注释：`WalkNavi` 需**百度地图客户端 v8.8 以后**；`ARWalkNavi` 需 v9.7.5 以后；**低于 8.6.9 不支持步行导航**。方案 §3.7 的失败表只有「百度地图未安装」，**没有「版本过旧」**。老人手机上的百度地图很可能长期未更新，`walknavi` 会静默失败。已回写进 §3.7 与 M0 任务 4 的记录项（记客户端版本号）。

### 7. 其他制品层事实

- 插件 pin 的原生 SDK 是 **8.2.0**，ADR 0003 静态探针用的是 **9.0.0**。`BusInfo` 的 getter 表面一致（8.2.0 已 `javap` 复核），但**不是同一制品**，ADR 0003 的 sha256 与体积数字不能直接套到插件上。
- `map` 组件依赖 **`android.arch.lifecycle:extensions:1.1.1`**（AndroidX 之前的遗留支持库），且 arm64 `.so` 增量 **18.4 MB**——为「每个地点确认一次入口」这种低频操作付这个体积不划算。
- search/utils 的 `build.gradle` 用 `rootProject.allprojects { repositories { maven { url 阿里云镜像 } } }`，会把镜像注入**整个工程的所有模块**，属供应链层面应当知情的改动。
- **`flutter_bmflocation` 的 AndroidManifest 声明了 `ACCESS_BACKGROUND_LOCATION` 与 `READ_PHONE_STATE`**，会合并进 APK，直接违反方案 §6.2 验收第 9 条「无后台定位权限」。
- 一个正面发现：`BMFMassTransitStep.isSubStep` 显式区分「子路段」与「多个方案」，与 `app/lib/baidu_route_parser.dart` 里 `_transitGroups` + `rideTaken` 发现的「同组多条车辆段是备选线路」语义完全对应。现有解析器的核心洞察在 SDK 路径上同样成立。

## 决策

- **D1　路线检索：若 D1（数据源）最终选 B，自建薄平台通道，不引入官方 search 插件的路线部分，也不 fork。** 只映射 ADR 0003 列出的 13 个字段（约 150 行 Kotlin + Dart 通道）。理由：唯一真正需要的字段恰好是插件丢掉的那个；自建通道表面更小、无跟版负担、可继续用现有 fixture 测试。ADR 0003 已经把最难的活（制品坐标、字段 getter、命名陷阱、合规门槛、体积）做完了。

- **D2　POI / Suggestion：有条件复用官方插件。** 仅当「D1 选 B」且「要做地点录入」时引入 `flutter_baidu_mapapi_search`，**只用它的 POI/Suggestion 部分**，路线仍走 D1 的薄通道；两者共用同一个 base 与同一个 Android AK，不额外增加原生成本。若 D1 选 A，POI 也走代理，不引入插件。

- **D3　现有三层资产不动**：`app/lib/route_summary.dart`（模型 + 文案 + 推荐 + 选路）、`app/lib/baidu_route_parser.dart`（四态解析 + 分组）、`app/lib/baidu_uri.dart`（URI 构造）。任何要求替换这三层的「复用」都是负收益——三个候选成熟方案都在数据源层有硬缺陷，没有一个能替代已写好的摘要模型与文案规则。

- **D4　不引入**：`map_launcher`（`baidu.dart:89,110` 硬编码 `coord_type: 'gcj02'`，extras 冲突抛异常且无法覆盖，无 walknavi、无网页回退、origin required）、Trufi Core（GPL-3.0 + 强绑 OTP/GTFS + 无已发布 pub 包，**只读思路不抄码**）、`flutter_baidu_mapapi_map`、`flutter_baidu_mapapi_utils`、`flutter_bmflocation`。

- **D5　定位用 `geolocator`（WGS84）+ `coordtransform_dart` 本地转 BD-09**，不用 bmflocation。转换精度已交叉验证，见 ADR 0001 事实 7 与 D3。

- **D6　「在地图上确认一次入口」不引入地图 SDK**：改用百度静态图 API（一次 HTTP 取图）或直接调起百度地图客户端让家属看一眼。与现有 `baidu_uri.dart` 风格一致且可测试。

## 后果

- **D2 会造成混合架构**：POI 走 SDK（需 Android 端 AK，绑定包名 + SHA1），路线走 Web API（需服务端 AK + 代理）时是**两个 AK、两条数据通路**，比纯 A 或纯 B 都复杂。只有 D1 选 B 时这个代价才不存在（共用一个 Android AK）。这是 D1 决策要一并权衡的。
- 薄通道自己维护，但表面只有 13 个字段；官方插件表面是 60 个 Dart 文件、13 类检索（天气/行政区/建筑/AOI/全景等），SeniorNav 只用 3 类。
- **A 路的相对优势变大**：A 路不需要 Android 端 AK，也不需要 `setAgreePrivacy` 合规门槛。本 ADR 不因此关闭 D1，见 ADR 0003 §6 的四条关闭条件。
- 客户端版本门槛（事实 6）是本次调研对现有方案最直接的一条补充，已进 §3.7 失败表与 M0 任务 4 记录项。

## 仍待验证（不要当结论用）

| 项 | 现状 |
|---|---|
| 插件与薄通道的运行时行为、检索延迟、字段实际取值 | **全部未验证**，无 Android AK、无真机 |
| `BusInfo.getType()` 的 0=公交/1=地铁 语义 | 沿用 ADR 0003 静态推断，需拿到 AK 后复跑 |
| 8.2.0 与 9.0.0 的字段一致性 | 只在字节码层核对 getter 表面，未运行时比对 |
| 依赖冲突（`libc++_shared.so`、`android.arch` 遗留库） | **静态判断**，未编译任何插件、未 `flutter pub add` 试装 |
| 百度地图客户端旧版本上 `walknavi` 的实际失败形态 | 未实测，需真机 + 旧版本客户端 |