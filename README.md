# Cubic

Cubic 是原生 iOS / macOS 个人项目与行动管理工具。它把项目、可执行工作、实际投入和日历容量放在一起，帮助判断下一步做什么，以及当前计划能否满足截止时间。

当前仓库提供源码与开发工具。最低 App 系统版本为 iOS 26.0、macOS 26.0；尚无完成全渠道验收的正式发行包。下面包含使用、开发、架构与发布说明，不依赖仓库外的产品文档或私有验收资料。

## 主要功能

- 收件箱快速记录工作，整理为项目、节点和具体工作，支持前置关系、等待、验收与复核。
- 行动页根据当前状态展示可执行工作；共享工作按身份去重，统一参与个人容量计算。
- 日历页结合工作时段、精力、所选 Apple Calendar 的占用和工作时间块展示容量。时间块可拖动、编辑或移除，安排时间与实际投入分别记录。
- 排期与试算展示截止约束、风险和选择影响。试算不会自动开始工作或修改执行进度。
- 支持从 Markdown 创建项目，以及保存模板、调整截止时间后创建独立项目。
- iOS 与 Mac 可选择同一个 iCloud Drive 目录进行文件同步，查看待上传、待下载和冲突状态。
- 支持 JSON 备份与恢复、工作历史、提醒，以及在明确授权后关联 Apple Calendar 事件。

Mac 版提供侧栏、键盘命令和鼠标操作，与 iOS 共享主要领域逻辑和界面实现。

## 第一次使用

1. 首次打开是空工作空间。先在收件箱记录一项工作，或创建项目并添加节点与工作。
2. 在设置中填写工作时段、时区和日历使用规则。读取日历、写入关联事件和通知各自需要系统授权。
3. 在行动页选择下一步；未来安排放入日历时间块，已发生的劳动通过投入记录保存。
4. 需要跨设备时，在两端设置中选择同一个 iCloud Drive 同步目录，并等待文件完整下载。每台设备分别授予目录访问权限；不要复制另一台设备的目录 bookmark。
5. 更换安装或迁移前，可从设置导出 JSON 备份。恢复按事实合并，可能产生需要人工处理的冲突。

当前同步主路径是 iCloud Drive 文件目录，不要求 CloudKit capability。Release 禁用新的 CloudKit 连接；历史 CloudKit 数据的本机保留和导出，不代表未下载远端数据已完成迁移。

## 从 Markdown 创建项目

项目页选择“从 Markdown 快速创建”，粘贴后先预览，再保存。第一行是项目，一级列表是节点，下一层是工作，例如：

```markdown
产品演示准备, 11.20
- 演示内容
    - 整理需求, 2h
    - 制作样例, 90min
- 演练
    - 完整演练, 1h
```

支持 Markdown heading、无序或有序列表。逗号后的日期可用 `11.20`、`11/20` 或 `2026-11-20`；省略年份时使用当前年份，日期型截止按当前时区日末处理。耗时支持 `2h`、`1.5h`、`30min` 等格式，未填写时默认 60 分钟。错误日期或层级会在预览中阻止保存。

项目详情中可“保存为模板”。模板保留结构、耗时、内部关系和验收规则；从模板创建时填写新截止时间，生成新的实体身份并重置执行进度。修改或删除模板不会改变已创建的项目。

## 项目结构与架构

| 路径 | 职责 |
|---|---|
| `Core/` | `CubicCore` Swift Package；领域模型、命令与查询、排期、模板、同步 journal、合并和 SQLite 缓存，以及 Core tests |
| `CubicApp/` | 共享 SwiftUI 界面、`AppModel`、本地提交入口、日历、通知及同步 adapters；iOS App 入口 |
| `CubicMac/` | Mac App 入口、资源与 sandbox entitlements |
| `Cubic.xcodeproj/` | Xcode 工程、workspace 与 shared schemes |
| `Tests/`、`CubicUITests/`、`CubicMacUITests/` | App、架构、通知及原生 UI 测试 |
| `project.yml` | XcodeGen 工程描述，修改工程配置时同步维护 |
| `scripts/`、`config/` | 测试入口、发布 CLI、toolchain lock 与非敏感配置模板 |

界面通过 `AppModel` 发起领域操作，`WorkspaceSession` 校验编辑所依据的快照并提交到 `SyncJournal`。不可变 revisions 保存事实；SQLite 保存可重建的合法投影缓存。同步经 `SyncCoordinator` 和 transport 读取远端 revisions，再做确定性归并。冲突事实会保留，不能把非法投影当作精确排期依据。

`CalendarBridge` 负责系统日历关联与对账；EventKit I/O 与领域提交分开处理。系统权限、目录访问 bookmark、日历写入绑定等信息留在设备本地。备份中的事实恢复与偏好恢复分步进行，失败时应核对已完成部分。

## 开发环境与构建

需要 macOS、完整 Xcode 和 XcodeGen。当前发布 toolchain lock 位于 `config/release-toolchain.json`，记录 Xcode 26.3、Swift 6.2.4、XcodeGen 2.46.0 和 XcodeBuildMCP 2.7.0；发布检查会核对具体 build、SDK 和工具版本。release CLI 使用 Python 3.9+；部分测试脚本还需要提供 `timeout` 命令。

Core 没有远程 Swift package 依赖，通过系统 SQLite binding 访问 SQLite。

从仓库根目录重新生成工程：

```sh
xcodegen generate --spec project.yml --project . --project-root .
open Cubic.xcodeproj
```

在 Xcode 选择 `CubicMac` scheme 构建 Mac App，选择 `Cubic` scheme 构建 iPhone App。首次设备构建需在 Signing & Capabilities 中配置有权限的 Team 和对应签名资产；工程中现有 Team 不代表其他开发者拥有该 Team 权限。

自用副本应统一调整 `project.yml`、生成工程和相关 entitlements 中的应用身份；不要只修改一处 Bundle ID，也不要用新身份覆盖原有数据迁移的假设。设备调试先列出本次实际连接设备，再明确选择目标，避免依赖作者的本地 defaults：

```sh
xcodebuildmcp device list --output json
```

仓库不提供证书、私钥或 provisioning profiles。`local.liwei.Cubic` 与 `local.liwei.CubicMac` 是当前两端应用身份，iCloud container 另见 entitlements；这些标识不是凭据。

## 测试

从仓库根目录运行 Core tests 和发布工具 contract tests：

```sh
swift test --package-path Core
python3 -B -m unittest discover -s scripts/release/tests -p 'test_*.py'
```

`CubicArchitecture` scheme 编译实际 App sources 并运行 macOS App tests；`scripts/test-architecture.sh`、`scripts/test-notifications.sh` 提供补充 Foundation harness。iOS / Mac UI tests 分别位于对应 UITests target。

涉及真实 iCloud、系统权限和多阶段 UI 的测试可能要求 opt-in environment 或先前 checkpoint，具体条件在各测试源码中。Core 或模拟 I/O 的通过结果不能代替真实设备、系统日历和双设备同步验收；执行记录应注明 commit、设备、命令、失败与 skipped 场景。

## 发布工具

统一入口为 `scripts/release.sh`，也有 `release-preflight.sh`、`release-build.sh` 和 `release-package.sh` wrappers。查看可用参数：

```sh
./scripts/release.sh --help
./scripts/release.sh preflight --help
./scripts/release.sh build --help
./scripts/release.sh package --help
```

将 `config/release.example.env` 复制为已忽略的 `config/release.local.env`，填写 commit、Team、Bundle ID、version/build 和签名输入后显式加载；CLI 不会自动读取该文件。不要提交真实 credentials、设备名单或 profiles。

流程为：对 clean committed source 执行 `preflight` → 用 `build` 创建隔离 Release archive → 按 receipt 用 `package` 本地导出 → 对最终候选做安装、权限、同步、恢复和渠道验收。`--unsigned` 仅用于源码/编译检查，产物不能用于派发。

Mac 渠道为 Developer ID，iOS 支持 TestFlight、App Store 和登记设备范围内的 Ad Hoc。签名需要合法的本机证书/private-key identity 和匹配 profiles；Mac notarization 由显式 `--notary` 触发。工具不会自动上传到 App Store Connect、注册设备或授予发行资格。

<a id="release-validation"></a>

### 候选验收记录

每个候选需单独记录 commit、版本与 build、平台/架构、最终文件 SHA-256、签名/entitlements、安装和首次启动、权限拒绝与恢复、备份恢复、同步及冲突场景，并标明 pass、fail、blocked 或 not run。Mac 还需核对 notarization/stapling/Gatekeeper，iOS 需核对对应渠道的实际安装或 processing 结果。

`package --acceptance-reference` 可指定该候选的实际记录位置。默认引用本节只是记录规范，不代表候选已通过；生成的 manifest 初始验收状态仍是 `not-run`，不能据此宣称正式可用。当前新 Mac/Intel、TestFlight 等完整发行组合仍缺少已完成的验收。

## 本地资料与 Git 范围

`docs/` 是本地产品、架构、实施和 QA 历史资料，已被 Git 忽略，普通 checkout 不提供。`evidence`、`.scratch`、`.lody` 及 `.xcodebuildmcp/` 也是本地资料，不是构建依赖。已有兼容 symlink 的目标位于项目外；新开发者不需要创建这些 symlink。

`.gitignore` 同时保留构建目录、Xcode 用户状态、Python bytecode、`release-output/` 和指定私有 release 输入的排除规则。本地备份、日志、签名材料和任意新增私有配置应放入明确忽略的位置；示例配置可以进入 Git。
