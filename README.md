# catengar

Windows 上的 League Client 小工具。界面使用 [vercel-labs/native](https://github.com/vercel-labs/native)，业务和通信使用 **Zig 0.16.0**，没有 WebView、Node 或浏览器运行时。

## 使用

```powershell
# 首次下载固定版本依赖、编译并打开窗口
powershell -ExecutionPolicy Bypass -File scripts/run.ps1

# 只构建
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -BuildOnly

# 不连接客户端的自动化测试
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test
```

构建后直接打开 `zig-out/bin/catengar.exe`，不需要安装 Zig。首次构建需要网络下载 Zig 与 Native SDK，之后可以离线构建。SDK 固定在 `6b053188dc8ac415f602618be12717889cb0a986`，下载归档校验 SHA-256；不需要 npm。

1. 打开 League 客户端和工具。工具通过隐藏的 PowerShell 子进程读取 `LeagueClientUx.exe` 的命令行，获取 `--app-port` 和 `--remoting-auth-token`。
2. 启动时先检查读取认证所需的权限，再创建主窗口。如果读取命令行需要更高权限，**工具自动弹出 Windows UAC**，授权后只显示管理员实例的窗口，避免普通窗口先出现、关闭后再出现。取消授权后显示普通窗口，不会反复提示，可点击「管理员重试」。客户端未启动时仍正常打开；已经具有管理员权限或已有实例时不重复提权。
3. 英雄库与优先顺序位于同一块面板。英雄库采用连续滚动的头像网格，没有分页或头像下方的名称。按客户端语言的名称或英文名搜索，点击整张卡片加入优先选择，右上角勾选表示已选择，再次点击取消；使用右侧上下箭头设置优先级。最多 32 位，达到上限后仍可点击已选卡片取消，排在前面的优先。
4. 分别打开「自动接受对局」「优先英雄自动选取」。首次运行两个开关都关闭，后续恢复保存的设置。
5. 右上方「外观」下拉框可选择 ChatGPT 深色、ChatGPT 浅色、Nord 北欧、Catppuccin 和经典金色。立即生效，无需重启，选择自动保存到本地设置的 `theme` 字段，下次启动会恢复。

设置保存到 `%LOCALAPPDATA%\LoLRengar\settings.json`，图片和静态资料缓存在该目录的 `cache` 子目录。重命名为 catengar 后继续使用此目录，以保留已有设置。客户端重启、端口或 token 变化后会自动重新连接。

后台认证线程监听客户端进程退出，连接期间每 5 秒重新读取一次命令行并比较 PID、端口和 token（另计读取耗时）；客户端未启动或读取失败时每 3 秒重试。WebSocket 断线、HTTP 401/403 或连接检查失败会立即请求重新读取认证，至少退避 1 秒且等到新的认证查询完成后重试。恢复连接时重新订阅事件、同步当前状态，清除旧选人决策，保留本地开关和英雄优先级。主窗口隐藏到托盘后同样生效。

**点击窗口关闭按钮或 Alt+F4 会隐藏到系统托盘，自动化继续运行。** 点击托盘图标或右键菜单「打开 catengar」恢复窗口；右键菜单「完全退出」保存设置并停止后台服务。每个 Windows 用户只运行一个实例，重复启动会唤回已有窗口。管理员重启会等待旧实例释放锁后才启动服务；崩溃后操作系统自动释放锁，无需删除锁文件。

自动接受或抢英雄成功后，会在桌面右下角显示应用绘制的提示窗，沿用当前主题，约 4.5 秒后消失，也可点击关闭。它不使用系统通知，不会在弹出时抢焦点；主窗口隐藏到托盘后仍会显示。连续成功的提示依次展示，普通状态刷新不会重复弹出；抢英雄必须等客户端确认后才提示。

应用文件、窗口、任务栏和托盘使用 `assets/catengar-icon.png` 中的猫科图标，透明边缘保持不变。`assets/catengar.ico` 包含 16–256 px 的 9 种尺寸并内嵌在 exe 中；托盘所需的文件自动释放到本地数据目录，单独复制 exe 即可使用。从其他工作目录启动也能找到图标。更换源图后运行 `powershell -File scripts/build-icon.ps1` 重新生成 ICO，再构建应用；CI 直接使用已提交的 ICO，无需额外图片工具。

主窗口使用 macOS 风格的自绘标题栏：左侧红色按钮收进托盘，黄色按钮最小化，绿色按钮最大化或还原。空白标题栏可拖动、双击最大化/还原；保留系统边缘缩放和任务栏操作，Windows 11 使用系统圆角与阴影。标题栏随当前主题即时变化，三个按钮支持键盘焦点。托盘与任务栏继续使用猫科图标。

## 自动化行为

- 自动接受：仅在 `ReadyCheck`、`state=InProgress`、自己的 `playerResponse=None` 时提交接受请求。已接受或拒绝的不重复提交。
- 自动选人：只处理队列 450（ARAM）、2400（Mayhem），或客户端明确返回 `ARAM` / `ARAM_MAYHEM` 的队列。未知模式默认不执行。
- 优先从可用替补池交换，兼容 `benchChampionIds` 和 `benchChampions` 两种会话结构。只有比当前英雄排名更高的英雄才会被选中；当前英雄没有出现在优先列表时，列表中的任何可用英雄都可成为候选。
- 对提供卡片选择的会话，仅在自己的未完成 `pick` action 正在进行，且目标出现在 LCU `pickable-champion-ids` 中时提交选择。根据 `isLegacyChampSelect` 使用对应接口前缀。
- 成功请求后等待 WebSocket 会话事件确认英雄归属。3 秒未收到确认时补读一次状态。交换竞争、接口拒绝和短暂错误会退避重试，不假定抢选必定成功。
- 主要通过 **WSS / WAMP 事件订阅**实时获取游戏阶段、对局信息、接受状态、选人会话及可选英雄 ID。事件到达后唤醒工作线程；正常连接下不高频轮询这些状态。每 15 秒仅补读一次游戏阶段，验证认证与连通性并修复遗漏的阶段事件；REST 还用于首次连接、阶段切换缺失数据补齐、断线恢复、静态资源和 POST/PATCH 写操作。
- WebSocket 不可用时临时降级为 REST（选人 250 ms、接受 500 ms、空闲 1 秒，加上请求耗时），每 10 秒尝试恢复 WebSocket；界面显示当前通信方式。匹配确认和选人期间暂停可选的图片下载。
- 不主动排队，不使用重随点，不发起队友交易，不自动配置符文，不执行对局内操作。

## 静态资源

游戏数据均从当前 LCU 获取，没有打包英雄图片、固定英雄名称表或外部 CDN 回退：

| 内容 | LCU 接口 |
| --- | --- |
| 英雄索引和头像路径 | `/lol-game-data/assets/v1/champion-summary.json` |
| 英雄头像 | 索引返回的 `squarePortraitPath` |
| 符文资料与图片路径 | `/lol-perks/v1/perks` |
| 符文系 | `/lol-perks/v1/styles` |
| 召唤师技能 | `/lol-game-data/assets/v1/summoner-spells.json` |
| 缓存版本和语言 | `/lol-patch/v1/game-version`、`/riotclient/region-locale` |

本版显示英雄头像、同步符文/技能元数据；未展示的符文图片不会提前下载。头像路径严格限制在 `/lol-game-data/assets/` 内。版本或语言变化会使用新的缓存目录；版本无法确定时使用新的连接缓存，避免复用旧版本。

英雄候选始终排除英文标识以 `Jade_` 开头的条目（不区分大小写），包括搜索结果和客户端英雄清单接口不可用时的回退路径。

英雄网格仅构建实际滚动视口及相邻行的卡片，滚动条覆盖完整英雄库；搜索会回到顶部。只为可见、相邻行及优先列表中的英雄读取和解码头像，文件读取、WIC 解码和尺寸处理均在独立后台线程执行；界面按批合入 512×512 图集，同一批每张图集只上传一次。离开视口的已解码头像继续保留，滚回时直接复用。最多 256 位英雄及优先列表共用 Native SDK 的 16 个图片槽。图片尚未加载或获取失败时显示头像占位，不影响已配置英雄 ID 的自动选取。

滚轮和触控板直接跟随 Windows 提供的滚动量，不叠加 Native 默认的长时间惯性。停止输入后列表停在当前位置，顶部/底部限制在内容边界；拖动滚动条仍可精确定位。所有主题和左右两个列表使用相同规则。

后台仅在界面状态发生变化时发布快照，空闲检查不再反复重建界面。LCU 重连时保留当前英雄库、滚动位置和头像；只有版本、语言、英雄顺序或资料实际变化时才失效重载。已存在的磁盘头像在后台一次性检查，避免重连时每 50 ms 刷新一位英雄。

LCU 接口随客户端更新可能变化。当前客户端能否使用卡片选择、Mayhem 和新版 team-builder 路径，取决于它返回的实际字段及端点。接口参考：[LCU schema](https://lcu.kebs.dev/)、[Riot 队列定义](https://static.developer.riotgames.com/docs/lol/queues.json)。

## 认证与诊断

token 只在私有子进程管道及应用内存中使用，不进入日志、设置、图片 URL 或 HTTP 子进程参数。REST 和 WebSocket 均使用 WinHTTP，固定连接 `https://127.0.0.1:<port>` / `wss://127.0.0.1:<port>`，不使用代理、不跟随重定向；仅在这个本地连接上接受 LCU 的自签名证书。WebSocket 单条消息限制 2 MiB，只缓存五个已订阅资源；断线后丢弃旧缓存重新同步。初始 REST 快照不会覆盖更新的事件，阶段退出会清除上局选人数据，事件改变后旧决策不会继续提交。

WebSocket 使用 WinHTTP 异步接收与可取消等待。重连或退出时先唤醒接收线程，再取消句柄并等待最后的关闭回调，之后释放缓冲区；即使服务端不回复关闭握手，也不会阻塞在同步接收中。认证读取在线程中独立运行，不阻塞正常抢英雄循环。

```powershell
# 只读诊断；客户端已提权时，从管理员终端运行
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Diagnose
```

诊断验证 WebSocket 升级、订阅和空闲连接，输出接口状态码、条目数及游戏阶段，不输出认证信息。正常界面会自动申请管理员权限；命令行诊断仅报告需要权限。

## 源码

- `src/app.native`：原生界面。
- `src/titlebar.zig`：自绘标题栏和红黄绿窗口按钮。
- `src/main.zig`：UI 状态、消息、图片生命周期和 UAC 重启。
- `src/champion_grid.zig` / `src/portraits.zig`：网格可视范围、连续滚动和共享头像图集。
- `src/portrait_worker.zig` / `src/catalog.zig`：有界后台头像解码队列、目录内容标识和重连缓存复用。
- `src/toasts.zig` / `src/toast.native`：成功提示去重、排队、定时关闭与自绘提示窗。
- `src/auth.zig` / `src/lcu.zig`：命令行认证、WinHTTP 通信。
- `src/logic.zig`：可独立测试的模式判断、优先级选择及退避规则。
- `src/service.zig`：事件驱动自动化、动作确认、自动重连和资源缓存。
- `src/events.zig`：WebSocket 接收、WAMP 订阅、事件缓存和快照同步。
- `src/socket.zig`：可取消的 WinHTTP 异步 WebSocket、回调和句柄生命周期。
- `src/instance.zig`：跨权限单实例锁、重复启动唤回和管理员重启交接。
- `src/settings.zig`：配置解析和原子写入。
- `src/tests.zig`：离线协议与自动化测试。
- `scripts/test-transport.py` / `src/transport_test.zig`：本地 TLS/WAMP 故障测试。运行 `python scripts/test-transport.py`，仅需 Python 标准库和已安装的 Zig；模拟空闲连接取消、远端断线、token 更新、端口/PID 更换和重订阅，不读取真实 LCU 认证。`scripts/fixtures/loopback.pem` 是公开的自签名测试证书及测试密钥，仅供这些离线测试使用。

UI 调试可使用 `zig build -Doptimize=ReleaseSafe -Dautomation=true`。Native SDK 会在 `.zig-cache/native-sdk-automation` 输出语义快照，并接受它的文件自动化协议。正常构建未启用该调试通道。

无客户端时可额外传入 `-Dpreview-catalog=本地文件.json` 检查完整网格；文件格式为 `[{"id":1,"name":"英雄名称","alias":"EnglishName","icon_path":"本地LCU缓存头像路径"}]`。此预览构建不连接 LCU、不写入偏好；测试后使用普通构建命令生成正式程序。

当前固定版本 SDK 的 `Runtime.initAt` 会跳过大型托盘数组的默认值；应用在启动钩子中初始化这些托盘状态字段，避免首次创建菜单失败。

`scripts/bootstrap.ps1` 会应用 `scripts/patch-native.ps1` 中的性能补丁：Native 原本会在每帧、每个头像绘制时重新散列整张图集，现在在图像注册/更新时计算一次并沿用 `ReferenceImage.content_fingerprint`。图像内容改变仍会触发 GPU 上传；重复显示不再扫描像素。补丁针对固定 SDK，源码不匹配时明确报错，重复执行无副作用；运行 `zig build test-images` 验证不变内容复用、修改内容失效及图片槽移除后的正确性。

主题的背景、卡片、文字、强调色和交互状态集中在 `src/theme.zig` 与 `src/main.zig` 的 token 映射中。默认采用 ChatGPT 深色风格；ChatGPT 两款是参考其中性灰和黑白层次的适配，并非官方主题导出。[Nord](https://www.nordtheme.com/docs/colors-and-palettes/) 和 [Catppuccin Mocha](https://catppuccin.com/palette/) 参考官方色板，并为本工具的状态和边界做了调整。旧设置缺少主题、或含未知主题名称时，回退为 ChatGPT 深色，其余偏好继续保留。正文、次要文字及选中按钮的文字配色均有 4.5:1 对比度检查。

界面字体从本机 Windows 字体目录读取微软雅黑，内存中提取字体集合的第一个字面供 Native SDK 使用；不复制或分发系统字体。游戏资源仍全部由 LCU 提供。

## GitHub CI

`.github/workflows/build.yml` 在每次 push、pull request 和手动运行时执行 Windows 构建：格式检查 → 离线单元测试、图像缓存失效测试与 TLS/WebSocket 故障测试 → ReleaseSafe 编译 → 上传便携程序（保留 14 天）。不需要 League 客户端或任何账号密钥。故障测试使用运行器预装的 Python 标准库，不安装额外依赖；Zig 测试程序复用现有编译缓存。

缓存分两层：固定版本 Zig/Native SDK 按 bootstrap 脚本内容缓存；Zig 全局编译缓存和项目 `.zig-cache` 按构建配置和源码内容缓存。源码修改时回退到相同构建配置的缓存，复用标准库、C++ 宿主和未变更的编译结果。文档修改可直接命中已有编译缓存；同一分支的新 push 会取消过时任务。Actions 固定到完整 commit SHA。
