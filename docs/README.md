# docs 目录说明

| 位置 | 内容 | 状态 |
|---|---|---|
| `plan/` | 项目方案与评审意见 | **当前口径是 `plan/SeniorNav_项目初步方案_v0.2.md`** |
| `adr/` | 架构决策记录，编号递增 | 有效 |
| `m0/` | M0 技术验证的产出与记录 | 进行中 |
| `figures/` | 方案配图 | **已过期**，见 `figures/README.md` |
| `GIT_COMMIT_RULES.md` | 提交规范与隐私红线，配套钩子在 `.githooks/` | 有效 |

## plan/

- `SeniorNav_项目初步方案_v0.2.md` —— 现行方案，交互冻结稿，已按 ADR 0002 的实测结果修订。
- `SeniorNav_项目初步方案_v0.2.docx` —— 导出版。**落后于同名 md**：md 已修正 §4.4 的 `direction` 字段映射等 10 余处，docx 里仍是旧的错误描述（会让实现者把行车方向写成下车站）。重新生成之前不要单独引用 docx。
- `SeniorNav_项目初步方案_v0.1.*` —— 历史版本。v0.1 的定位是"老年人出行导航与家属守护应用"，含 SOS、位置共享、Traccar，这些已被 v0.2 §1.4 明确删除。保留是为了理解 v0.2 为什么砍掉一半功能，不作为实现依据。
- `SeniorNav_方案评审意见_v0.1.md` —— 对 v0.1 的评审，P0-1～P0-5 与 P1-1～P1-13。其中大部分已回写进 v0.2，未回写的在 v0.2 §10 的 D7–D11 里挂账。

## adr/

- `0001-坐标系统一为BD09.md` —— 坐标系决策，有效。
- `0002-路线数据源WebAPI实测.md` —— A 路（Web API）实测结论；D1 仍开放。
- `0003-AndroidSDK检索组件静态探针.md` —— B 路（Android SDK）静态验证：制品、体积、字段覆盖；运行时探针已可编译但**一次检索都没发起**，D1 不因此关闭。

## m0/

- `纸面摘要样张.md` —— M0 任务 3 的朗读测试材料，由 `app/tool/render_paper_summary.dart` 从 `app/test/fixtures/` 的真实录制响应生成，不手抄。
- `客户端密钥与隐私审计.md` —— 服务端 AK/SK 未进 APK 的产物级证据；含申请 Android-端 AK 所需的包名与 SHA1，以及探针包不可分发的警告。
- `真机导航测试清单.md` —— M0 任务 2/3/4 的真机执行清单：URI 参数组合、点击次数口径、关怀版是否支持调起。**所有实测列都是空的**，本机只完成静态准备。

真机测试记录也放这里，按 `GIT_COMMIT_RULES` §3.7 先删设备序列号、手机号与精确家庭位置。

## 配套代码与工具（在 docs 之外）

- `app/lib/` —— 解析器、摘要模型与文案规则、URI 构造；`app/test/` 72 个用例。
- `app/tool/render_paper_summary.dart` —— 生成纸面样张；`app/tool/parse_sdk_dump.dart` —— 用同一套解析器消费 SDK 探针的 dump。
- `tools/sdk-probe/` —— Search SDK 最小运行时探针（纯 Java，需 Android-端 AK 才能跑），步骤见其 `README.md`。
- `tools/scan_apk_secrets.py` —— APK 密钥与私人数据扫描，只输出命中位置不回显值。

## 路径约定

文档正文里提到的仓库路径一律写成**从仓库根开始**的形式（`app/lib/route_summary.dart`、`docs/adr/0002-…`），不写相对路径，这样文件在 docs 内部移动时引用不会失效。只有 Markdown 超链接才用相对路径，移动后需要同步修改。
