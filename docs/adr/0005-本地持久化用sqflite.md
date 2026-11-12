# ADR 0005：本地持久化用 sqflite，不用 Drift

**状态**：已接受（2026-11-12）。**只定选型，不开发地点管理功能**——方案 §4.6 的地点模型属 M1，本 ADR 不写任何持久化代码。
**关联**：方案 §2 技术栈表、§4.1 架构图、§4.6 地点模型、§4.8 隐私、`docs/research/开源项目复用调研.md` §6
**范围**：源码层与制品层结论。**未编译、未试装、未跑任何数据库读写**。

---

## 背景

方案 v0.2 在 7 处写了 Drift（§2 技术栈表、§4.1 架构图、§4.6 两处、§4.7 目录树、§4.8 技术选型表与 `allowBackup` 说明）。调研提出改用 `sqflite`。因为 `app/pubspec.yaml` 目前只有 `cupertino_icons` 与 `url_launcher`，**一行持久化代码都还没写**，这次改选型的重构成本为零——这是现在决定的唯一时机，写完再改就要迁数据。

## 核验到的事实

### 1. 需求规模：单表、约 20 行、无 join

方案 §4.6 的地点模型是一张表（id / slot / name / icon / sortOrder / poiUid / latitude / longitude / naviLatitude / naviLongitude / gateUid / coordSystem / verifiedAt / deletedAt / rev / schemaVersion 量级），V1 单家庭自用，行数是「常去地点」的个数（个位数到十几）。没有关联表、没有全文检索、没有跨表事务、没有服务端同步。

### 2. Drift 的三大收益在这个规模上全部为零

| Drift 收益 | 对 SeniorNav V1 |
|---|---|
| 类型安全的查询 DSL（join / 聚合 / 子查询） | 无 join、无聚合，只有 `SELECT * FROM places WHERE deletedAt IS NULL ORDER BY sortOrder` 这一类语句 |
| 迁移 DSL 与 schema 校验 | 单表，`onUpgrade` 里几条 `ALTER TABLE` 就够 |
| 响应式流（watch 查询） | 地点由家属配置、老人只读，Riverpod 手动 invalidate 足够 |

### 3. 代码生成量（实测，不是估算）

drift 官方仓库里最小的完整样例 `test/integration_tests/regress_2166_test.dart`：**单表 2 列**（`id` + 可空 `name`），源文件 108 行，生成的 `regress_2166_test.g.dart` **361 行**。官方 `example/main.dart`（2 表 + 2 视图 + 1 索引，137 行）生成 **1373 行**。

> 16 列单表的生成量按列数线性外推约 **1200–1800 行**——**这是外推，不是实测**，不要当精确数字引用。可实测的锚点是「2 列 → 361 行」。

代价不只是行数：`build_runner` + `drift_dev` 进入工具链，每次改字段要重跑生成，生成文件进不进仓库都要定规矩。

### 4. Drift 的原生依赖要在构建期从 GitHub 下载

`drift_flutter` 走 `sqlite3` 包。**`sqlite3` 3.9.1 的 `hook/build.dart` 在 `PrecompiledBinary` 分支调用 `downloadIntoOutputDirectoryShared(...)`**，下载地址写在 `lib/src/hook/compile/description.dart:353`：

```
https://github.com/simolus3/sqlite3.dart/releases/download/$RELEASE_TAG/$FILENAME
```

本机是 Clash TUN + 校园网 CGNAT 多出口，GitHub release 下载是不稳定环节。**把「构建能不能成功」绑到一次境外下载上，对单人开发是不必要的风险。** 另一条路 `sqlite3_flutter_libs` 已 EOL（调研记录，本地未复核制品）。

### 5. sqflite 用 Android 系统 SQLite，零原生制品、零代码生成

- `sqflite_android` 的 `Database.java` 直接 `import android.database.sqlite.SQLiteDatabase` 等 5 个系统类；整个 android 目录**没有任何 `.so` / `CMakeLists.txt` / `.c` 文件**（实测 `find` 为空）。
- `onCreate` / `onUpgrade` / `onDowngrade` **在事务里执行**：`sqflite_common/lib/src/database_mixin.dart:1168` 起 `await transaction((txn) async { … })`，版本号在同一事务末尾 `setVersion`。迁移失败会回滚，不会留下半升级的库。
- 许可证 **BSD-2-Clause**，版本 **2.4.6**，有公开仓库与 issue tracker（与百度系插件相反）。
- 约束全部满足：`sdk ^3.12.0`（本机 3.13.7）、`flutter >=3.44.0`（本机 3.47.9）、`minSdk 19`（工程 24）。
- 平台覆盖 **android / ios / macos**，方案 §2「保留 iOS 适配接口」不受影响。

## 决策

- **D1　用 `sqflite`，手写 schema 与迁移，不引入 Drift / drift_dev / build_runner。** 预估手写量约 200 行（建表 + CRUD + `onUpgrade`），对比生成 1200+ 行再加手写 DAO。
- **D2　`schemaVersion` 用 SQLite 的 `PRAGMA user_version`**（即 `openDatabase(version: n)`），不额外建 meta 表、不在每条地点上存一份。方案 §4.6「表级字段」的口径不变。
- **D3　迁移只写 `onUpgrade`，不写降级逻辑**；`onDowngrade` 留空即抛错，避免旧版本 App 静默读新库。单家庭 sideload 场景下这是可接受的失败形态。
- **D4　不引入其他持久化方案**：`shared_preferences` 存 JSON 字符串列表（Trufi 的做法）没有事务与迁移，`hive_ce` / `objectbox` 对单表 20 行是过度设计，`isar` 3.1.0+1 最后发布 2023-04-25 且 Dart 3 不兼容。
- **D5　`allowBackup="false"` 保持不变**（`app/android/app/src/main/AndroidManifest.xml` 已设）。换成 sqflite 不改变这条隐私要求：库文件里仍是家庭地址。
- **D6　现在不写代码。** 依赖等到 M1 实现 §4.6 地点模型时才加进 `app/pubspec.yaml`，避免挂一个用不到的依赖。

## 后果

- 方案 7 处 Drift 提法已回写为 sqflite（§2 / §4.1 / §4.6 ×2 / §4.7 / §4.8 ×2）。
- 失去类型安全查询：SQL 字符串写错只能在运行时发现。**缓解**：地点表的 CRUD 语句集中在一个 Repository 文件里，配单元测试覆盖建表、升级、软删除与排序；表结构简单，语句数量是个位数。
- 构建期不再依赖境外下载，`flutter build apk` 的失败面变小。
- 若将来真出现多表 join 或同步需求，再评估 Drift——那时迁移成本才是真实的，现在为零。

## 仍待验证

| 项 | 现状 |
|---|---|
| sqflite 在本工程的实际编译与读写 | **未试装**，`flutter pub add` 与依赖冲突未测 |
| 手写 200 行的估算 | 估算，不是实测 |
| 16 列 Drift 生成量 | 外推，实测锚点只有「2 列 → 361 行」 |
| `sqlite3_flutter_libs` EOL | 调研记录，本地未复核制品 |