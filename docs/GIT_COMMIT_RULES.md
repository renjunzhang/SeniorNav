# Git 提交规则：密钥与私人信息保护

> 适用仓库：`renjunzhang/SeniorNav`
> 当前状态：**private 空仓库**（2026-11-12 设置）。本规则按"随时可能公开"设计——**一旦公开，历史无法真正撤回**，所以按最坏情况执行。
> 本规则优先于"先把东西提交上去再说"的习惯；与规则冲突时，以不泄露为第一原则。

---

## 1. 三条铁律

1. **不把任何密钥、令牌、证书、口令提交进仓库**，包括"只提交一次""马上删掉"的情况。
2. **不把真实私人信息提交进仓库**：家庭住址、精确坐标、门牌、家人手机号、身份证、POI UID、含定位的截图。
3. **每次提交前假设"下一秒仓库就会公开"**。删除一次 commit 不等于清除；GitHub 缓存、fork、克隆、搜索引擎都可能已经留下副本。

---

## 2. 永不提交清单

| 类别 | 典型内容 | 正确做法 |
|---|---|---|
| SSH / 签名私钥 | `id_rsa`、`id_ed25519`、`*.pem`、`*.p12`、`*.pfx`、`*.jks`、`*.keystore` | 放 `~/.ssh` 或本机密钥库，权限 600；仓库只放 `.pub`（公开密钥可以提交，但本项目也不需要） |
| 平台令牌 | `ghp_…`、`github_pat_…`、`gho_…`、`AKIA…`、`AIza…`、`sk-…`、`xoxb-…` | 放环境变量 / CI Secrets / 本机 ignored 文件 |
| 百度 AK / 服务端密钥 | `BAIDU_AK=…`、`ak=…` | `--dart-define` 注入、`local.properties`（已忽略）、CI Secret；**不要写进 Dart 源码或文档** |
| 本机配置 | `local.properties`、`.env`、`google-services.json` | 保留本机，`.gitignore` 排除 |
| 构建产物 | `app/build/`、`.dart_tool/`、APK/AAB/IPA | 一律忽略；需要发布时走 Release，不进仓库 |
| 日志 / 崩溃记录 | `*.log`、`flutter run` 输出、含定位的调试日志 | 忽略；需要排查时脱敏后另存 |
| 真实地点 | 小区名、楼栋门牌、精确经纬度（小数 4 位以上）、POI UID | 测试用公共地标或虚构点；真实地址只存手机本地 |
| 联系人信息 | 手机号、身份证号、家庭关系、病历 | 测试用 `138****0000` 之类虚构值 |
| 截图 / 录屏 | 含地图定位、通讯录、通知栏、家人聊天 | 打码后再提交；默认不提交 |
| 文档元数据 | docx 作者/公司/批注/修订记录、图片 EXIF | 提交前清理；见 §6 |
| 对话 / 评审记录 | 评审意见里引用真实小区名、坐标 | 提交前替换为脱敏表述 |

> 判断标准只有一条：**这段内容如果出现在公开网页上，我是否愿意让陌生人看到？** 犹豫就不提交。

---

## 3. 本项目专属规定

1. **测试地点必须虚构或使用公共地标**：M0/M1 的 `Destination` 常量不得使用真实住址；测试点与真实住址距离建议 > 2km。
2. **家的真实坐标只存在于手机本地数据库/家属设置中**，不进入代码、测试、文档、截图。
3. **坐标脱敏**：文档示例最多保留 3 位小数（约 100m 精度）；代码测试用虚构值，不要用真实点。
4. **POI UID 也按私人信息处理**：UID 可反查地点，不能提交真实住址的 UID。
5. **百度 AK**：只通过 `--dart-define=BAIDU_AK=…`、本机 ignored 文件或 CI Secret 注入；AK 绑定包名 + SHA1，H5 端 AK 绑定 Referer 白名单。
6. **文档**：方案与评审意见统一放 `docs/plan/`。`.docx` 提交前检查作者/公司/修订记录；评审意见初稿含真实小区名，入库版本已脱敏，后续修订同样要先脱敏，否则钩子会拦截。
7. **M0 记录**：真机测试记录写入 `docs/m0/` 时，删除设备序列号、手机号、精确家庭位置，只保留机型/Android 版本/结论。

---

## 4. 提交前 60 秒

```bash
git status --short
git diff --cached --stat
git diff --cached          # 逐行看新增内容，不要只看文件名
```

- **不要 `git add .`**，用明确路径：`git add app/lib/xxx.dart README.md`。
- 二进制文件（docx、图片、APK）先问自己"里面有什么"，再决定是否提交。
- 钩子会自动扫描；**不要用 `--no-verify` 绕过**（例外见 §9）。
- 提交信息不要写手机号、地址、令牌；不要贴含敏感信息的命令输出。

---

## 5. 密钥管理

- 生成：优先 ed25519；私钥不离开本机，权限 `600`。
- 存放：环境变量、`--dart-define`、CI Secrets、系统钥匙串；不写进源码、文档、issue、聊天记录。
- 轮换：怀疑泄露立即轮换，**先轮换再清理历史**；删除 commit 不能阻止已泄露的密钥被使用。
- 百度 AK：App 端 AK 与 Web 端 AK 分开；开启额度告警；不在客户端日志打印 AK。
- GitHub：HTTPS 用 `gh auth setup-git` 的凭据助手；不要把手动生成的 PAT 写进 remote URL（`https://user:token@…` 会留在 `.git/config` 和 shell 历史里）。

---

## 6. 私人信息处理

- 代码/测试：用 `DEMO_HOME` 之类的虚构常量；断言里也不要出现真实地址。
- 文档：小区名→"某小区"，精确坐标→取整或删除，UID→删除，电话→`138****0000`。
- 截图：地图定位点打码、通知栏清理、联系人打码。
- docx 元数据检查：

```bash
unzip -p 文件.docx docProps/core.xml
unzip -p 文件.docx docProps/app.xml
```

- 提交前全仓扫描（钩子会做，但可手动复核）：

```bash
git grep -nI -E '<真实小区名>|<真实纬度>|<真实经度>|1[3-9][0-9]{9}'
```

---

## 7. 防线（从内到外）

| 层 | 作用 | 状态 |
|---|---|---|
| `.gitignore` | 阻止密钥/构建产物被 `git add` | 已提供 |
| `.githooks/pre-commit` | 提交前扫描文件名、密钥模式、手机号/身份证、本地隐私词 | 已提供，需启用 |
| `.githooks/pre-push` | 推送前扫描待推送历史，兜底 `--no-verify` 的提交 | 已提供，需启用 |
| `gitleaks`（可选） | 更完整的密钥规则库 | 建议安装 |
| GitHub Secret scanning / Push protection | 服务端最后一道门 | 仓库公开后立即开启 |
| CI（GitHub Actions） | 每次 push/PR 自动扫描 | 建议加 |
| 人工 review | 看 `git diff --cached` | 必做 |

> 钩子不是安全边界：`git commit --no-verify` 可以绕过；真正的兜底是服务端扫描和"不把敏感信息写进工作区"。

---

## 8. 如果已经泄露

1. **先轮换**：吊销/重置密钥、AK、token；不要先忙着删 commit。
2. 评估范围：哪些 commit、哪些分支、是否已 push、是否已公开。
3. 清理历史：`git filter-repo`（推荐）或 BFG；然后 `git push --force --all` 和 `--tags`。
4. 联系 GitHub Support 清理缓存视图；如果已公开，假设已被 fork/克隆，无法完全收回。
5. 复盘：把这次的模式写进 `.git/privacy-terms` 或钩子规则，防止再次发生。

---

## 9. 例外与审计

- 确需提交示例数据：必须脱敏，并在 commit message 里注明"示例数据，已脱敏"。
- 紧急情况使用 `--no-verify`：仅限事故处理；commit message 标注 `[skip-hooks]`，24 小时内用 `gitleaks detect` 补扫并记录原因。
- 任何例外都要在 `docs/adr/` 或 PR 描述里留痕。

---

## 10. 检查清单

- [ ] `git diff --cached` 中没有密钥、令牌、真实地址、电话、身份证
- [ ] 没有 `.env` / `local.properties` / `*.jks` / `*.keystore` / `*.pem` 被 add
- [ ] 没有 `app/build/`、`.dart_tool/`、APK/AAB 被 add
- [ ] 大文件/二进制已确认内容
- [ ] docx 元数据已检查
- [ ] 本地隐私词表已配置（`.git/privacy-terms`）
- [ ] 钩子已启用且本次提交通过
- [ ] 提交信息不含敏感内容
- [ ] 仓库若公开：Secret scanning + Push protection 已开启

---

## 附录 A：启用钩子（首次提交前执行）

```bash
cd /home/zrj/SeniorNav
git init
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push

# 本地隐私词表：只存在 .git/ 内，永不提交（一行一个词）
# 把真实小区名、完整坐标、POI UID 等写进去；不要写进本文件
printf '%s\n' '<真实小区名>' '<真实纬度>' '<真实经度>' '<真实POI_UID>' > .git/privacy-terms
chmod 600 .git/privacy-terms
```

验证钩子：

```bash
# 应被拦截
printf 'ghp_%s\n' "$(head -c 36 /dev/zero | tr '\0' a)" > /tmp/leak.txt
cp /tmp/leak.txt ./leak.txt && git add leak.txt && git commit -m test   # 期望失败
git restore --staged leak.txt 2>/dev/null; rm -f leak.txt
```

> `.git/privacy-terms` 在 `.git/` 内，不会进入任何 commit；`git clone` 也不会带走。

---

## 附录 B：gitleaks（可选但推荐）

```bash
# 安装后
gitleaks protect --staged --redact
gitleaks detect --source . --redact
```

钩子检测到 `gitleaks` 会自动调用 `protect --staged`；没有安装则跳过。

---

## 附录 C：提交信息模板

```text
<type>: <简短说明>

- 改了什么
- 为什么

安全自查：无密钥/无真实地址/钩子通过
```

`type` 用 `feat|fix|docs|test|chore|refactor`。
