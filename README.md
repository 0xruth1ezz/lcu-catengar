# Catengar

Windows 上的 League Client 助手，使用 **Rust + [NSH](https://github.com/longbridge/nsh)**。主界面、托盘、通知与自动化引擎均为 Rust；NSH 使用原生 Windows 渲染，无需 Node 或 JavaScript 运行时。英雄详情按需使用 WebView2 打开 haidou.pro。

NSH 固定到 `a5036af48ddc193b5023ece9b9196c76b8f8d3f5`，依赖由 `Cargo.lock` 锁定。版本唯一来源是 `Cargo.toml`，Windows EXE 版本资源在构建时生成。界面省略为零的补丁号。

`vendor/nsh-platform-windows` 保存该版本的 Windows 后端和局部键盘修复：Tab / Shift+Tab 遍历按钮、复选框与输入框，Enter / Space 激活控件，焦点样式跟随当前主题；遍历跳过禁用控件并限制在当前对话框。其余 NSH 组件直接使用固定的上游代码。来源、修改范围与许可见该目录的 README 和 LICENSE。

## 构建和运行

需要 Windows x64、[Rust / rustup](https://rustup.rs/)、Visual Studio 2022 Build Tools 的 **Desktop development with C++** 工作负载及 Windows SDK。`rust-toolchain.toml` 固定 Rust 1.99.1。详情页需要 Microsoft Edge WebView2 Runtime。

本地构建使用 [Mr. Boxington](https://mr-boxington.jdx.dev/) 共享编译缓存，`mise.toml` 固定版本。安装 [mise](https://mise.jdx.dev/)，在仓库运行 `mise trust`、`mise install` 即可；已有 Rust 工具链继续由 rustup 管理。`run.ps1` 和 `cargo.ps1` 自动查找已安装的 mbx，无需修改全局 Cargo shim、编辑器或 PowerShell 配置。未安装 mbx 时回退到普通 Cargo。

```powershell
# 开发构建并运行（默认 debug，使用增量编译）
./scripts/run.ps1
# 仅编译优化后的便携版
./scripts/run.ps1 -Release -BuildOnly
# 调试构建；不连接 League、不检查更新
$env:CATENGAR_DATA_DIR = Join-Path $PWD '.tools/preview-data'
./scripts/run.ps1 -Debug -Preview
# 只读认证诊断（不会自动请求管理员权限）
./scripts/run.ps1 -Diagnose
# 只做编译检查，不链接 EXE
./scripts/cargo.ps1 check --locked --all-targets
```

默认输出为 `target/x86_64-pc-windows-msvc/debug/`，`-Release` 输出为 `target/x86_64-pc-windows-msvc/release/`。`-Debug` 仍可显式选择开发构建。加 `-Timings` 会生成 Cargo HTML 构建耗时报告。Release 保留 `opt-level=3`，使用 16 个 codegen units，关闭跨 crate LTO，减少每次修改后的编译和链接时间。构建不启用未使用的 NSH 自定义 shader 与代码语法高亮，主界面仍使用 Direct2D 原生渲染。

分发时保留 `catengar.exe`、`catengar-auth.exe`、`catengar-diagnose.exe`、`WebView2Loader.dll`、`WebView2-LICENSE.txt` 和本 README。使用者不需要 Rust。`.cargo/config.toml` 固定通用 x64 CPU 和静态 MSVC CRT，避免依赖开发机 CPU 指令或另装 VC Runtime。首次构建需要网络；已缓存依赖后可使用 Cargo 的 `--offline`。开发脚本不再额外运行一次全量 `cargo fetch`；Cargo 按当前构建下载所需依赖。

`.mbx.toml` 保留本地开发的 Cargo 增量编译，依赖由 mbx 缓存；项目脚本默认关闭 managed targets，现有 `target/` 不会被移动。缓存默认位于 `%LOCALAPPDATA%/mbx`，可以设置 `MBX_CACHE_DIR` 改到同一磁盘以便硬链接恢复。`./scripts/cargo.ps1 explain --last` 查看最近一次缓存命中；直接调用 `cargo` 则跳过项目的 mbx 入口。通过 PowerShell 脚本转发编译器或测试参数时，将分隔符写成 `'--'`，例如 `./scripts/cargo.ps1 clippy --locked --all-targets '--' -D warnings`。对比缓存效果时，应使用两个全新的 `--target-dir`，避免把 Cargo 自身的 Fresh 误当成 mbx 命中。

**WebView2 的用途：**只有「查看」打开的 haidou.pro 内嵌英雄详情使用 WebView2 Runtime，首页、设置、日志与自动化不依赖浏览器渲染。当前 MSVC 构建已将 loader 静态链接进 EXE，因此单独的 `WebView2Loader.dll` 不是启动依赖；发布 ZIP 仍保留它，以兼容旧版更新器的六文件清单。启动测试特意不复制该 DLL。静态 loader 不包含浏览器引擎，详情页仍需电脑上安装 WebView2 Runtime。

## 使用

- 自动连接同一台电脑上的 League 客户端。首次启动时自动接受和自动选取均关闭，后续恢复已保存开关。
- 搜索客户端语言的英雄名称或英文标识。只有头像右上角按钮增删优先英雄；「查看」打开英雄资料。最多保存 32 位，箭头调整顺序，列表越靠前优先级越高。
- 首页顶部集中自动化开关，英雄库直接显示名称，与优先列表分别滚动；「英雄／日志／设置」导航始终可用，支持 880 × 720 的最小窗口。
- 「总是按照优先顺序选取英雄」默认开启：持续换取更高顺位英雄。关闭后，本轮首次确认自动选中优先英雄即停止。
- 进入支持的选人阶段后，屏幕右侧居中出现一个置顶按钮：「暂停本局抢英雄／开启本局抢英雄」。单击切换，按住拖动可调整并记住位置；不会抢走客户端焦点，主窗口隐藏时也能使用。仅本局生效，下局恢复保存的设置。手动开启会让本局持续按优先级选取，即使原设置关闭或单次选取已完成；暂停后按钮保留，可随时恢复。
- 首页显示连接状态、当前英雄和可用替补。连接后右下角显示头像、好友 ID 与阶段，点击好友 ID 复制。
- 「日志」查看历史活动，每页 20 条，翻阅历史时不被新记录挤动；清空需二次确认，不影响设置。
- 「设置」提供经典金色、OAI 深色、OAI 浅色、Nord 北欧、Catppuccin 五种主题，立即生效。也可检查更新、重新连接、查看诊断和关于。
- 关闭主窗口会隐藏到托盘；托盘菜单可恢复或完全退出。重复启动恢复已有实例。成功操作通知不抢焦点，约 4.5 秒后关闭。
- 窗口使用自绘红黄绿按钮，支持拖动、缩放、最大化和位置恢复。中文文本输入由 NSH 的 Windows 输入组件处理。

悬浮按钮一直保留到 LCU 会话进入 `GAME_STARTING` 或离开 `ChampSelect`；`FINALIZATION`、锁定卡片和倒计时为零都不会提前关闭按钮。断线时暂时隐藏，同局重连保留暂停状态。位置单独保存到 `pick-control-window.json`，不保存本局开关；显示器变化时恢复到可见区域。

## 自动化边界

自动接受仅在 `ReadyCheck` 且本人 `playerResponse` 为 `None` 时提交；同轮成功后不重复接受。不会主动排队。

自动选取仅支持 ARAM（450）、Mayhem（2400），或客户端明确声明 `ARAM` / `ARAM_MAYHEM` 的队列；未知模式、观战、竞技场和云顶不执行。开启后按优先顺序直接尝试 LCU 返回的替补、可选英雄和个人卡池，不等待 UI 倒计时、`isInProgress`、`benchEnabled` 或 `isAvailable` 放行。自己的未完成 pick action 使用 `PATCH /lol-champ-select/v1/session/actions/{id}`；已有英雄时，对替补或个人卡池使用 `POST /lol-champ-select/v1/session/bench/swap/{id}`。个人卡池来自 `/lol-lobby-team-builder/champ-select/v1/subset-champion-list`，锁定卡片后仍可继续尝试交换。已有优先英雄时仅升级到更高顺位，是否接受请求由 LCU 决定。

HTTP 成功只表示提交成功，必须由客户端会话确认英雄归属。等待确认时每 250 ms 补读，且仍可立即争取更高顺位；同一英雄不重复提交，也不降级到比已提交目标更低的顺位。3 秒仍未确认则重新尝试。接口拒绝时继续尝试其他候选或同英雄的另一条适用接口，失败项每 250 ms 可重试；HTTP 429 时暂停选取请求 1 秒。关闭自动选取立即停止新请求；用户取消持续优选后，仍按“首次确认自动选中即停止”的设置执行。每轮完成状态在断线、开关、主题和优先级修改后保留，仅确认离开选人或有效正数 64 位 gameId 改变时重置。手动持有英雄不会被计为自动成功。

匹配确认完成进入选人时，已知红蓝阵营模式从本人队伍字段识别阵营，立即在当前屏幕右下角提示，并向当前选人聊天发送一次；阵营提示优先显示，不等待接受对局等旧通知，也不依赖自动选英雄。聊天室尚未建立时监听其创建事件并补发，缺失数据每 250 毫秒补查；未知阵营不猜测。发送时核对会话、对局和聊天室，明确失败最多尝试 5 次，网络中断导致结果未知时不重复发送。不会发起交易、使用重随点、配置符文或执行对局内操作。

WSS / WAMP 事件唤醒工作线程；REST 补齐缺失数据并提交操作。开启自动接受或自动选取时每秒补查阶段，接受阶段每 500 ms 补查状态；选取启用期间每 250 ms 补查会话和候选池，避免事件缺失或早期空列表造成漏抢。同一资源的新事件优先于更早发出的 REST 读，不因无关资源更新丢弃候选池响应；提交前重新检查观测值和事件版本。WebSocket 不可用时临时使用 REST（选人 250 ms、接受 500 ms、空闲 1 秒，另计请求耗时），每 10 秒尝试重连。

## 认证、缓存与日志

默认数据目录仍为 `%LOCALAPPDATA%\LoLRengar`，保留旧版 `settings.json`、`priority-champions.json`、`window.json` 和 `logs/activity.jsonl` 格式。`CATENGAR_DATA_DIR` 可指定独立目录。未指定目录的 `--preview` 使用单独的 `LoLRengar-preview` 目录。无法读取的设置不会被默认值直接覆盖；修改偏好后尝试保存。保存失败会提示并重试。

认证监视器先使用普通权限查询本机进程及其旁边的 lockfile；必要时启动同目录 `catengar-auth.exe` 请求管理员授权。主界面和 LCU 请求始终运行在主程序权限下。用户取消 UAC 后不会自动反复请求，可点击「授权连接」重试。助手经随机私有命名管道传输有界消息，双方验证进程身份。认证凭据不输出到日志或诊断。

LCU 请求限制为 `127.0.0.1`，禁用代理与重定向；只为这个本机端点接受客户端自签名证书。WebView 页面不接收 LCU 凭据。Windows 进程查询和事务更新仍嵌入已验证的 PowerShell 脚本，并使用系统目录内的 Windows PowerShell；没有 Zig 代码或运行时。

英雄、头像、符文及技能元数据来自本机 LCU。资源工作线程独立于自动化，匹配确认与选人时暂停新图片下载。头像缓存按客户端版本和语言分目录，路径限制在本地资源范围内；失败图片延迟重试，不阻塞其他头像。候选列表排除 `Jade_` 开头的标识。优先英雄名称和头像可离线编辑，完整英雄网格由 NSH 虚拟列表连续滚动。

活动日志由独立线程追加 JSONL，保存失败保留待写记录并重试。记录连接、接受、选取确认和每轮优先英雄结果；断线汇总明确标记记录截止于中断，不猜测后续结果。

## 更新

启动约 10 秒后及之后每 6 小时检查 GitHub 正式版；草稿与预发行版不触发更新。设置页可手动检查，只有点击「更新并重启」才下载并安装。下载校验 SHA-256、版本和固定文件清单，安装需主程序提交退出握手；游戏阶段及游戏进程保护会推迟安装，文件占用或替换失败会回滚。更新结果在下次启动显示。

## 源码

| 文件 | 职责 |
| --- | --- |
| `src/ui.rs` | Rust NSH 组件、虚拟英雄网格、日志、设置、WebView2 详情 |
| `src/theme.rs` | 五套主题的颜色、字体、间距与控件尺寸 |
| `src/platform.rs` | Win32 窗口、托盘、通知、单实例、DPI 与位置恢复 |
| `src/notifications.rs` | 通知文案、队列与阵营提示优先展示 |
| `src/model.rs` / `src/engine.rs` | 配置、模式与优先级规则、每轮状态、确认重试和阵营提示 |
| `src/service.rs` | 后台调度、连接恢复、资源缓存与更新协调 |
| `src/transport.rs` | 本机 TLS REST、WSS / WAMP、事件缓存及写操作保护 |
| `src/auth.rs` / `src/auth_discovery.ps1` | 普通权限发现、管理员助手及私有管道 |
| `src/storage.rs` / `src/journal.rs` | 兼容设置、原子保存、持久日志分页 |
| `src/updater.rs` / `src/updater.ps1` | 正式版检查、校验、退出握手、替换与回滚 |
| `tests/` / `scripts/test-*` | 离线规则、协议及 Windows 集成验证 |

## 验证与 CI

```powershell
. ./scripts/bootstrap.ps1
& $CatengarCargo fmt --all --check
& $CatengarCargo clippy --locked --all-targets -- -D warnings
& $CatengarCargo test --locked --all-targets
& $CatengarCargo test --locked -p nsh-platform-windows --lib input::tests::keyboard
python scripts/test-auth-discovery.py
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts/test-updater.ps1
python -B -m unittest discover -s scripts -p test_release.py -v
python scripts/test-transport.py $CatengarCargo
./scripts/run.ps1 -Release -BuildOnly
python scripts/test-startup.py
```

TLS/WAMP 测试启动 OS 分配端口的本地假服务器，验证聊天室创建事件唤醒、重订阅、连接中断、token 轮换、过期认证禁止写入及关闭时限。测试证书 `scripts/fixtures/loopback.pem` 是公开测试材料。启动测试使用含空格和中文的临时路径、独立离线缓存及关闭的开关；不查询真实 LCU、不请求 UAC。普通 `cargo test` 会跳过需要 Python 服务器或原生桌面的集成测试，`test-transport.py` 显式运行协议测试。

在交互式 Windows 桌面运行 `./scripts/cargo.ps1 test --locked --test toast '--' --ignored --nocapture` 可验证原生通知：使用临时离线数据，检查主窗口隐藏时红蓝提示立即替换接受通知、工作区右下角位置、不抢焦点及自动消失；不会连接真实客户端。

运行 `./scripts/cargo.ps1 test --locked --test pick_control '--' --ignored --nocapture` 验证单按钮悬浮控件的置顶、不抢焦点、单击切换、拖动不误触、位置恢复和本局生命周期。可设置 `CATENGAR_CAPTURE_DIR` 保存各主题下按钮的截图，测试始终使用临时离线资料。

Windows CI 执行格式、Clippy、Rust 及 NSH Windows 后端测试、认证/更新/发布脚本测试、TLS/WAMP、便携程序启动检查并上传构建产物。离线测试不替代真实客户端的 UAC、中文 IME 候选窗、多显示器和对局交互验证。鼠标操作、搜索输入和 Escape 关闭关于窗口已经验证。新增键盘补丁已通过遍历规则测试，完整原生窗口的键盘交互仍需人工确认。

普通构建和发布复用 `.github/actions/windows-ci`，显式使用 `-Release` 打包，并生成 Cargo timings。两者安装固定版本的 mbx，默认使用 GitHub target 缓存（包含 Cargo 下载）。缓存键包含编译器身份、构建配置、依赖清单和 vendored 后端源码；普通源码提交命中同一依赖基线后不再重新打包上传整份缓存。成功推送默认分支时才保存新基线，PR 和发布仅读取。每次发布仍重新构建带版本资源的应用并执行全部检查；需要不读取编译缓存时，在发布工作流勾选 `clean_build`。

CI 单独关闭 dev/test 的调试信息与增量状态，保留调试断言和溢出检查，以减小编译产物及缓存；并行编译按 runner CPU 数量设置，上限为 4。本地 debug、Release 优化级别和测试范围不变。编译配置变化会建立新的缓存基线，第一次运行需要预热。发布工具测试始终在版本提交、标签和草稿创建之前运行。

## 发布

Actions → **Create release** → **Run workflow**。可指定 `version=0.2` / `v0.2.0`，或使用 `bump=patch`（默认）、`minor`、`major`；版本必须递增。脚本同时更新 `Cargo.toml` 和 `Cargo.lock`，资源版本由 Cargo 生成。

工作流推送版本提交和标签，创建草稿，验证后上传六文件便携 ZIP 并自动发布为 **pre-release**，不标记 Latest。只有手动转为正式版后应用才发现更新。失败时使用原运行的 **Re-run jobs** 复用提交、标签和草稿；新的 Run workflow 表示创建下一版本，已发布附件不会被覆盖。需要仓库允许内置 `GITHUB_TOKEN` 的 `contents: write` 推送，不绕过保护规则。

## 第三方软件

NSH © Longbridge，按 Apache License 2.0 使用。Microsoft WebView2 的许可随包附在 `WebView2-LICENSE.txt`。依赖版本与来源见 `Cargo.lock`。

<details><summary>NSH · Apache License 2.0</summary>

<pre>
Copyright 2026 Longbridge <https://longbridge.com>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

                              Apache License
                        Version 2.0, January 2004
                     http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

   "License" shall mean the terms and conditions for use, reproduction,
   and distribution as defined by Sections 1 through 9 of this document.

   "Licensor" shall mean the copyright owner or entity authorized by
   the copyright owner that is granting the License.

   "Legal Entity" shall mean the union of the acting entity and all
   other entities that control, are controlled by, or are under common
   control with that entity. For the purposes of this definition,
   "control" means (i) the power, direct or indirect, to cause the
   direction or management of such entity, whether by contract or
   otherwise, or (ii) ownership of fifty percent (50%) or more of the
   outstanding shares, or (iii) beneficial ownership of such entity.

   "You" (or "Your") shall mean an individual or Legal Entity
   exercising permissions granted by this License.

   "Source" form shall mean the preferred form for making modifications,
   including but not limited to software source code, documentation
   source, and configuration files.

   "Object" form shall mean any form resulting from mechanical
   transformation or translation of a Source form, including but
   not limited to compiled object code, generated documentation,
   and conversions to other media types.

   "Work" shall mean the work of authorship, whether in Source or
   Object form, made available under the License, as indicated by a
   copyright notice that is included in or attached to the work
   (an example is provided in the Appendix below).

   "Derivative Works" shall mean any work, whether in Source or Object
   form, that is based on (or derived from) the Work and for which the
   editorial revisions, annotations, elaborations, or other modifications
   represent, as a whole, an original work of authorship. For the purposes
   of this License, Derivative Works shall not include works that remain
   separable from, or merely link (or bind by name) to the interfaces of,
   the Work and Derivative Works thereof.

   "Contribution" shall mean any work of authorship, including
   the original version of the Work and any modifications or additions
   to that Work or Derivative Works thereof, that is intentionally
   submitted to Licensor for inclusion in the Work by the copyright owner
   or by an individual or Legal Entity authorized to submit on behalf of
   the copyright owner. For the purposes of this definition, "submitted"
   means any form of electronic, verbal, or written communication sent
   to the Licensor or its representatives, including but not limited to
   communication on electronic mailing lists, source code control systems,
   and issue tracking systems that are managed by, or on behalf of, the
   Licensor for the purpose of discussing and improving the Work, but
   excluding communication that is conspicuously marked or otherwise
   designated in writing by the copyright owner as "Not a Contribution."

   "Contributor" shall mean Licensor and any individual or Legal Entity
   on behalf of whom a Contribution has been received by Licensor and
   subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   copyright license to reproduce, prepare Derivative Works of,
   publicly display, publicly perform, sublicense, and distribute the
   Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   (except as stated in this section) patent license to make, have made,
   use, offer to sell, sell, import, and otherwise transfer the Work,
   where such license applies only to those patent claims licensable
   by such Contributor that are necessarily infringed by their
   Contribution(s) alone or by combination of their Contribution(s)
   with the Work to which such Contribution(s) was submitted. If You
   institute patent litigation against any entity (including a
   cross-claim or counterclaim in a lawsuit) alleging that the Work
   or a Contribution incorporated within the Work constitutes direct
   or contributory patent infringement, then any patent licenses
   granted to You under this License for that Work shall terminate
   as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the
   Work or Derivative Works thereof in any medium, with or without
   modifications, and in Source or Object form, provided that You
   meet the following conditions:

   (a) You must give any other recipients of the Work or
       Derivative Works a copy of this License; and

   (b) You must cause any modified files to carry prominent notices
       stating that You changed the files; and

   (c) You must retain, in the Source form of any Derivative Works
       that You distribute, all copyright, patent, trademark, and
       attribution notices from the Source form of the Work,
       excluding those notices that do not pertain to any part of
       the Derivative Works; and

   (d) If the Work includes a "NOTICE" text file as part of its
       distribution, then any Derivative Works that You distribute must
       include a readable copy of the attribution notices contained
       within such NOTICE file, excluding those notices that do not
       pertain to any part of the Derivative Works, in at least one
       of the following places: within a NOTICE text file distributed
       as part of the Derivative Works; within the Source form or
       documentation, if provided along with the Derivative Works; or,
       within a display generated by the Derivative Works, if and
       wherever such third-party notices normally appear. The contents
       of the NOTICE file are for informational purposes only and
       do not modify the License. You may add Your own attribution
       notices within Derivative Works that You distribute, alongside
       or as an addendum to the NOTICE text from the Work, provided
       that such additional attribution notices cannot be construed
       as modifying the License.

   You may add Your own copyright statement to Your modifications and
   may provide additional or different license terms and conditions
   for use, reproduction, or distribution of Your modifications, or
   for any such Derivative Works as a whole, provided Your use,
   reproduction, and distribution of the Work otherwise complies with
   the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise,
   any Contribution intentionally submitted for inclusion in the Work
   by You to the Licensor shall be under the terms and conditions of
   this License, without any additional terms or conditions.
   Notwithstanding the above, nothing herein shall supersede or modify
   the terms of any separate license agreement you may have executed
   with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade
   names, trademarks, service marks, or product names of the Licensor,
   except as required for reasonable and customary use in describing the
   origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or
   agreed to in writing, Licensor provides the Work (and each
   Contributor provides its Contributions) on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied, including, without limitation, any warranties or conditions
   of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
   PARTICULAR PURPOSE. You are solely responsible for determining the
   appropriateness of using or redistributing the Work and assume any
   risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory,
   whether in tort (including negligence), contract, or otherwise,
   unless required by applicable law (such as deliberate and grossly
   negligent acts) or agreed to in writing, shall any Contributor be
   liable to You for damages, including any direct, indirect, special,
   incidental, or consequential damages of any character arising as a
   result of this License or out of the use or inability to use the
   Work (including but not limited to damages for loss of goodwill,
   work stoppage, computer failure or malfunction, or any and all
   other commercial damages or losses), even if such Contributor
   has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing
   the Work or Derivative Works thereof, You may choose to offer,
   and charge a fee for, acceptance of support, warranty, indemnity,
   or other liability obligations and/or rights consistent with this
   License. However, in accepting such obligations, You may act only
   on Your own behalf and on Your sole responsibility, not on behalf
   of any other Contributor, and only if You agree to indemnify,
   defend, and hold each Contributor harmless for any liability
   incurred by, or claims asserted against, such Contributor by reason
   of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

</pre></details>
