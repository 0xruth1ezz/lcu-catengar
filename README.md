# Catengar

Windows 上的 League Client 小工具。界面使用 [vercel-labs/native](https://github.com/vercel-labs/native)，业务和通信使用 **Zig 0.16.0**。主界面使用原生渲染；英雄详情仅保留「haidou.pro」Tab，使用 Microsoft Edge WebView2 加载对应英雄网页，无需 Node。

应用名旁显示当前版本号，版本从 `app.zon` 的 `version` 字段生成。构建元数据使用完整语义版本；界面仅省略为零的补丁号，例如 `0.1.0` 显示为 **v0.1**，`0.1.1` 显示为 **v0.1.1**。

「设置 → 关于」显示应用简介、完整版本号、作者和 GitHub 仓库，可点击「打开 GitHub」在默认浏览器中查看项目。关于窗口跟随当前主题，支持 Escape、点击窗口外部或关闭按钮返回设置。

## 使用

```powershell
# 首次下载固定版本依赖、编译并打开窗口
powershell -ExecutionPolicy Bypass -File scripts/run.ps1

# 只构建
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -BuildOnly

# 不连接客户端的自动化测试
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test
```

构建后直接打开 `zig-out/bin/catengar.exe`，不需要安装 Zig。分发时必须将 `catengar.exe` 与 `catengar-auth.exe` 放在同一目录；`catengar-diagnose.exe` 是可选的命令行诊断工具。首次构建需要网络下载 Zig 与 Native SDK，之后可以离线构建。SDK 固定在 `6b053188dc8ac415f602618be12717889cb0a986`，下载归档校验 SHA-256；不需要 npm。

三个分发程序统一使用 `x86_64-windows-gnu` 与 `baseline` CPU 编译，普通构建也默认采用此配置。禁止按开发机或 CI 的原生 CPU 生成分发程序，避免 AMD 专有的 SSE4a 等指令导致其他 x64 电脑启动时出现 `Illegal instruction`。`src/portable_target.zig` 在编译期检查三个入口；`zig build test-target` 验证目标平台和 CPU 基线。

英雄详情的「haidou.pro」Tab 需要系统安装 Microsoft Edge WebView2 Runtime，分发时一并保留构建输出中的 `WebView2Loader.dll` 和 `WebView2-LICENSE.txt`。无法启动内嵌网页时，浮窗提示安装 Runtime，并提供重试和「浏览器打开」；自动选人功能仍可使用。海斗网页使用公共 HTTPS 地址，与 LCU 通信分离，不发送本地客户端认证信息。

1. 打开 League 客户端和工具，顺序不限。工具通过隐藏的 PowerShell 子进程读取 `LeagueClientUx.exe` 和 `LeagueClient.exe` 的命令行，获取 `--app-port` 和 `--remoting-auth-token`。命令行尚无认证信息时，再读取已检测到的客户端程序旁的 `lockfile`，并校验其中的 PID 对应当前 League 后台进程。客户端已经运行但认证尚未就绪时会自动等待重试。
2. 主程序直接显示窗口，不因认证而重启。后台先尝试读取客户端，确实需要更高权限时才启动独立的 **`catengar-auth.exe` 认证助手**。是否具备管理员权限通过 Windows 进程令牌验证：已有权限时直接继承启动助手，否则请求系统提权；Windows 可按用户设置自动授予权限，无需出现确认弹窗。主程序验证助手的实际权限，助手也自检，以成功建立认证管道并取得客户端认证信息为准。助手仅持续读取 League 客户端认证信息，主界面、配置保存、REST/WebSocket 和自动化仍由主程序负责。系统取消助手启动后不会反复请求，可点击「授权连接」重试；助手启动或管道临时失败会自动退避重试，客户端未启动时不会请求管理员权限。
3. 英雄库与优先顺序位于同一块面板。英雄库采用连续滚动的头像网格，没有分页或头像下方的名称。按客户端语言的名称或英文名搜索，**仅点击卡片右上角的加号／勾选按钮**加入或取消优先选择；头像和卡片空白不会修改选择。使用右侧上下箭头设置优先级，最多 32 位，排在前面的优先。达到上限后仍可取消已选英雄或查看资料。头像正下方居中的「查看」打开英雄详情浮窗，并立即在唯一的 **haidou.pro** Tab 内加载 `https://haidou.pro/champion/{id}/` 完整网页。查看资料不改变优先顺序；浮窗提供加载提示、刷新网页、启动失败重试、关闭按钮和原生区域的 Escape。点击「浏览器打开」可在默认浏览器查看对应英雄页面。
4. 顶部「自动接受对局」和整个英雄面板顶部的「自动选取英雄」分别控制两项功能。自动选取是英雄功能区的总开关，关闭时仍可编辑偏好。首次运行两个开关都关闭，后续恢复保存的设置。其下的「总是按照优先顺序选取英雄」复选框默认勾选：持续争取更高优先级的英雄；取消勾选后，本轮自动抢到任意优先英雄并经客户端确认即停止。此策略以 `always_prioritize` 保存，旧设置缺少该字段时默认勾选。启停状态由总开关表示；断线不会改变已保存的开关偏好。
5. 点击右上方「设置」，在「外观」中选择经典金色、ChatGPT 深色、ChatGPT 浅色、Nord 北欧或 Catppuccin，默认使用经典金色。立即生效，无需重启，选择自动保存到本地设置的 `theme` 字段，下次启动会恢复。设置页也提供重新连接和默认收起的诊断信息；使用「返回」回到英雄选择，搜索与优先顺序会保留。

主界面集中展示英雄库、优先顺序和当前功能状态，选人期间才显示当前英雄与可用池。右上方「日志」提供独立的活动记录页面；资源计数及本次接受/选取次数位于「设置 → 诊断」。需要处理的连接或授权问题、设置或日志保存失败仍直接提示。成功反馈沿用独立提示窗，不在主界面重复展示历史结果。

设置保存到 `%LOCALAPPDATA%\LoLRengar\settings.json`，图片和静态资料缓存在该目录的 `cache` 子目录。重命名为 Catengar 后继续使用此目录，以保留已有设置。客户端重启、端口或 token 变化后会自动重新连接。

加入优先顺序后，工具会将英雄 ID、名称、英文名、客户端资源路径及本地头像位置保存到同目录的 `priority-champions.json`，并优先下载这些英雄缺少的头像。下次启动时，即使未连接客户端，也会立即恢复已缓存优先英雄的名称、头像、搜索和「查看」入口；优先顺序仍可调整或移除。连接客户端后自动更新资料，头像下载失败会重试，接受对局和选人期间仍暂停图片下载。尚未下载或被手动清除的头像显示占位；首次使用本功能时，已有优先英雄会在连接客户端后自动补齐缓存。「查看」中的海斗网页仍需网络，与本地客户端连接无关。

普通窗口的位置和尺寸保存在同目录的 `window.json`，拖动或缩放结束后写入，下次启动在首次显示前恢复。连接、断线重连和认证完成不隐藏、重建或移动主窗口，也不唤回已隐藏或最小化的窗口。系统 UAC 提示仍可能临时切换到安全桌面；这是 Windows 的授权界面，不是主程序重新启动。移除显示器后，下次启动会将窗口放回可见工作区。

后台认证线程监听客户端进程退出，连接期间每 5 秒重新读取一次命令行并比较 PID、端口和 token（另计读取耗时）；客户端未启动或读取失败时每 3 秒重试。WebSocket 断线、HTTP 401/403 或连接检查失败后，至少退避 1 秒且等到新的认证查询完成后重试；普通读取可立即唤醒，管理员助手沿用每 5 秒的监视周期。恢复连接时重新订阅事件、同步当前状态，清除旧选人决策，保留本地开关和英雄优先级。主窗口隐藏到托盘后同样生效。

**点击窗口关闭按钮或 Alt+F4 会隐藏到系统托盘，自动化继续运行。** 点击托盘图标或右键菜单「打开 Catengar」恢复窗口；右键菜单「完全退出」保存设置并停止后台服务。每个 Windows 用户只运行一个实例，重复启动会唤回已有窗口。认证助手随主程序退出，助手存活期间的客户端重启和 token 刷新不重复请求 UAC；完全退出后再次启动助手仍可能需要授权。崩溃后操作系统自动释放锁，无需删除锁文件。

自动接受或抢英雄成功后，会在桌面右下角显示应用绘制的提示窗，沿用当前主题，约 4.5 秒后消失，也可点击关闭。它不使用系统通知，不会在弹出时抢焦点；主窗口隐藏到托盘后仍会显示。连续成功的提示依次展示，普通状态刷新不会重复弹出；抢英雄必须等客户端确认后才提示。

应用文件、窗口、任务栏和托盘使用 `assets/catengar-icon.png` 中的猫科图标，透明边缘保持不变。`assets/catengar.ico` 包含 16–256 px 的 9 种尺寸并内嵌在 exe 中；托盘所需的文件自动释放到本地数据目录，图标无需单独分发。从其他工作目录启动也能找到图标。更换源图后运行 `powershell -File scripts/build-icon.ps1` 重新生成 ICO，再构建应用；CI 直接使用已提交的 ICO，无需额外图片工具。

主窗口使用 macOS 风格的自绘标题栏，中间的 Catengar 名称旁显示嵌入 ICO 中的现有猫科 logo，无需额外图片文件：左侧红色按钮收进托盘，黄色按钮最小化，绿色按钮最大化或还原。空白标题栏可拖动、双击最大化/还原；保留系统边缘缩放和任务栏操作，Windows 11 使用系统圆角与阴影。标题栏随当前主题即时变化，三个按钮支持键盘焦点。托盘与任务栏继续使用猫科图标。

## 软件更新

应用启动约 10 秒后自动检查 GitHub 正式版，之后每 6 小时检查一次；已有可用更新或正在处理更新时跳过定时检查。发现新版本后显示不抢焦点的提示窗，顶部提供「发现新版本」入口。也可在「设置 → 软件更新」点击「检查更新」。**只有点击「更新并重启」后才下载、校验并安装更新**；安装完成会重新打开应用，保留偏好、窗口位置、缓存和日志。

匹配、接受对局、选人、游戏开始、对局和重连期间禁止安装；已连接但未知的游戏阶段也会暂停安装。下载完成和退出前再次核对阶段，安装进程还检查实际的 `League of Legends` 进程，避免 LCU 断线时误判空闲。下载期间进入匹配或对局时，更新包保留为就绪状态，结束后再次点击「更新并重启」。

更新只接受 [本项目 GitHub Releases](https://github.com/0xruth1ezz/lcu-catengar/releases) 中已公开发布、版本高于当前版本的正式版，不接受草稿、预发行版或降级。下载前重新核对版本与附件，验证 ZIP 的 GitHub SHA-256 摘要、文件大小、固定文件清单和主程序版本；安装前再次校验暂存文件。缺少完整可校验附件时不会替换程序。尚未包含更新功能的旧版需要先手动下载并安装一次支持更新的构建。

请将整套便携程序放在当前用户可写的目录；更新器不申请 UAC，`Program Files` 等受保护目录不可写时会提示移动程序。更新引擎嵌入主程序，通过 Windows 自带的 Windows PowerShell 5.1 在后台运行，无需 Node 或 Python。引擎、请求及结果记录位于应用实际数据目录的 `updates` 子目录（通常为 `%LOCALAPPDATA%\LoLRengar\updates`）；更新包、暂存文件及 `backup` 位于程序目录下的 `.catengar-update-<随机标识>` 中。

检查、下载或校验失败可按设置中的提示重试。替换或重新启动失败时会尝试恢复原文件并重新打开原版本；若恢复未完成，可从上述更新目录的 `backup` 恢复原文件。已有偏好、缓存和日志不参与替换。

## 自动化行为

### 活动日志

「日志」页面按本地时间显示连接/断开、连接恢复、功能开关变化、自动接受、抢英雄请求与结果。每条记录包含毫秒时间戳、类别、结果级别和具体内容。抢英雄仅在客户端确认归属后记为成功；接口失败、等待确认超时和连接中断各有记录。选人结束时，按本轮启用自动选取期间观察到的顺位英雄逐项汇总：已自动选中、非自动获得、请求失败、请求尚未确认、出现过机会但未提交、未发现可用机会。中途断线只汇总截至断线的已知情况，不推断最终对局结果。

日志默认保存在 `%LOCALAPPDATA%\LoLRengar\logs\activity.jsonl`（由打包应用启动时，Windows 可能重定向到该应用的 LocalCache；「打开日志目录」始终使用实际路径），采用可读的 UTF-8 JSON Lines 格式，跨重启保留，直到用户主动清空。「打开日志目录」通过 Windows Shell 的文件标识打开所在目录并选中日志文件；通过文件句柄解析真实磁盘路径，兼容中文、空格、不同启动目录以及 MSIX 启动器的 AppData 重定向，后台执行以保持界面响应。后台线程负责追加、落盘和读取，自动接受与选取线程不等待磁盘；界面每页 20 条，支持「较早」「较新」「最新」，全部历史均可查看。浏览历史时，新事件不会改变正在看的记录；「最新」恢复实时更新。

「清空所有日志」在页面内再次确认后清空该文件和待写的旧记录，不影响配置或图片缓存。清空后新发生的事件继续记录；磁盘写入失败会提示并后台重试，尚未落盘的记录只存在内存中。日志不包含认证 token、请求头或原始响应内容。

### 执行规则

- 自动接受：仅在 `ReadyCheck`、`state=InProgress`、自己的 `playerResponse=None` 时提交接受请求。已接受或拒绝的不重复提交。
- 自动选人：只处理队列 450（ARAM）、2400（Mayhem），或客户端明确返回 `ARAM` / `ARAM_MAYHEM` 的队列。未知模式默认不执行。
- 优先从可用替补池交换，兼容 `benchChampionIds` 和 `benchChampions` 两种会话结构。只有比当前英雄排名更高的英雄才会被选中；当前英雄没有出现在优先列表时，列表中的任何可用英雄都可成为候选。
- 勾选「总是按照优先顺序选取英雄」时，已选中英雄或完成选取后仍继续检查更高优先级的替补。例如顺序为 A、B、C，持有 B 时可升级到 A；持有 A 时即使只有 B、C 可用，也保留 A。
- 取消勾选时，仅在本应用提交的选取经 LCU 确认归属后停止本轮自动选人。手动持有优先英雄、请求返回 HTTP 204、失败或超时都不会单独完成本轮；未确认的请求按原有规则重试。
- 本次应用运行中，本轮已停止的状态在断线重连、切换主题、修改优先列表或关闭再打开总开关后保留；重新勾选策略可恢复持续优选。确认离开 `ChampSelect`，或观察到有效的正数 64 位 `gameData.gameId` 改变后，下一轮重新开始。该完成状态只保留在内存中。
- 对提供卡片选择的会话，仅在自己的未完成 `pick` action 正在进行，且目标出现在 LCU `pickable-champion-ids` 中时提交选择。根据 `isLegacyChampSelect` 使用对应接口前缀。
- 成功请求后等待 WebSocket 会话事件确认英雄归属。3 秒未收到确认时补读一次状态。交换竞争、接口拒绝和短暂错误会退避重试，不假定抢选必定成功。
- 主要通过 **WSS / WAMP 事件订阅**实时获取游戏阶段、对局信息、接受状态、选人会话及可选英雄 ID。事件到达后唤醒工作线程；开启自动接受时，每 1 秒补查游戏阶段，处于 `ReadyCheck` 时每 500 ms 补查接受状态（另计请求耗时），防止先开工具、后开客户端时事件缺失或接口暂未就绪导致漏接。补查不会覆盖期间到达的新事件，同一轮成功接受后不会重复提交。关闭自动接受时，阶段检查恢复为每 15 秒一次；REST 还用于首次连接、阶段切换缺失数据补齐、断线恢复、静态资源和 POST/PATCH 写操作。
- WebSocket 不可用时临时降级为 REST（选人 250 ms、接受 500 ms、空闲 1 秒，加上请求耗时），每 10 秒尝试恢复 WebSocket；界面显示当前通信方式。匹配确认和选人期间暂停可选的图片下载。
- 不主动排队，不使用重随点，不发起队友交易，不自动配置符文，不执行对局内操作。

## 静态资源

客户端静态资源均从当前 LCU 获取，没有打包英雄图片、固定英雄名称表或外部 CDN 回退。英雄详情单独通过 WebView2 加载 haidou.pro 网页；下表列出客户端静态资源的来源：

| 内容 | LCU 接口 |
| --- | --- |
| 英雄索引和头像路径 | `/lol-game-data/assets/v1/champion-summary.json` |
| 英雄头像 | 索引返回的 `squarePortraitPath` |
| 当前账号、名称与好友 ID | `/lol-summoner/v1/current-summoner`（同时订阅更新/删除事件） |
| 当前账号头像 | `/lol-game-data/assets/v1/profile-icons/{profileIconId}.jpg` |
| 符文资料与图片路径 | `/lol-perks/v1/perks` |
| 符文系 | `/lol-perks/v1/styles` |
| 召唤师技能 | `/lol-game-data/assets/v1/summoner-spells.json` |
| 缓存版本和语言 | `/lol-patch/v1/game-version`、`/riotclient/region-locale` |

本版显示英雄头像、同步符文/技能元数据；未展示的符文图片不会提前下载。头像路径严格限制在 `/lol-game-data/assets/` 内。版本或语言变化会使用新的缓存目录；版本无法确定时使用新的连接缓存，避免复用旧版本。

英雄候选始终排除英文标识以 `Jade_` 开头的条目（不区分大小写），包括搜索结果和客户端英雄清单接口不可用时的回退路径。

英雄网格仅构建实际滚动视口及相邻行的卡片，滚动条覆盖完整英雄库；搜索会回到顶部。只为可见、相邻行及优先列表中的英雄读取和解码头像，文件读取、WIC 解码和尺寸处理均在独立后台线程执行；界面按批合入 640×640 图集，同一批每张图集只上传一次。离开视口的已解码头像继续保留，滚回时直接复用。最多 256 位英雄及优先列表共用 11 张图集，为当前账号头像和标题栏 logo 各保留独立图片槽，整体不超过 Native SDK 的 16 槽限制。图片尚未加载或获取失败时显示头像占位，不影响已配置英雄 ID 的自动选取。

连接后，右下角显示当前账号的头像、召唤师名、完整好友 ID，以及「空闲／房间内／匹配中／选择英雄／对局中」等对局状态。顶部保留品牌、版本、日志和设置，连接状态与对局阶段使用独立文案。点击「复制 ID」复制原始 `gameName#tagLine`，成功后原处短暂显示「已复制」；剪贴板被占用时可重试。缺少名称或标签时不会用内部数字 ID 代替。账号资料只保存在内存中，头像缓存来自本机客户端；断线或退出登录立即隐藏账号资料和复制入口，右下角保留连接进度，需要授权或修复的问题仍显示操作提示。WebSocket 不可用时低频刷新账号，头像下载避开接受对局和选人阶段。

滚轮和触控板直接跟随 Windows 提供的滚动量，不叠加 Native 默认的长时间惯性。停止输入后列表停在当前位置，顶部/底部限制在内容边界；拖动滚动条仍可精确定位。所有主题和左右两个列表使用相同规则。

后台仅在界面状态发生变化时发布快照，空闲检查不再反复重建界面。LCU 重连时保留当前英雄库、滚动位置和头像；只有版本、语言、英雄顺序或资料实际变化时才失效重载。已存在的磁盘头像在后台一次性检查，避免重连时每 50 ms 刷新一位英雄。

LCU 接口随客户端更新可能变化。当前客户端能否使用卡片选择、Mayhem 和新版 team-builder 路径，取决于它返回的实际字段及端点。接口参考：[LCU schema](https://lcu.kebs.dev/)、[Riot 队列定义](https://static.developer.riotgames.com/docs/lol/queues.json)。

## 认证与诊断

主程序 manifest 为 `asInvoker`，认证助手为 `requireAdministrator`。助手路径固定为主程序同目录文件，命令行仅包含随机管道标识和父进程 PID。管道拒绝远程客户端，使用显式 ACL，并在两端核对进程 PID；助手还校验父进程为同目录的 `catengar.exe`，以 identification-only QoS 禁止服务端模拟管理员身份。助手不接收脚本、文件路径或通用管理员命令；PowerShell 与模块解析限定为 Windows 系统路径。

助手不安装服务或计划任务，不保存管理员授权。主程序退出或管道关闭后助手会退出；正在执行的命令行查询有 8 秒超时。软件更新由普通权限更新器负责，需要程序目录可写，不使用认证助手提权。

token 只在私有子进程管道、本机命名管道及应用内存中使用，不进入日志、设置、图片 URL 或 HTTP 子进程参数。REST 和 WebSocket 均使用 WinHTTP，固定连接 `https://127.0.0.1:<port>` / `wss://127.0.0.1:<port>`，不使用代理、不跟随重定向；仅在这个本地连接上接受 LCU 的自签名证书。WebSocket 单条消息限制 2 MiB，只缓存六个已订阅资源；断线后丢弃旧缓存重新同步。初始 REST 快照不会覆盖更新的事件，阶段退出会清除上局选人数据，事件改变后旧决策不会继续提交。

WebSocket 使用独立的 WinHTTP 连接池，避免重连时借用已有 REST 连接导致升级失败；旧系统不支持独立连接池时禁用握手请求的 keep-alive。WebSocket 使用 WinHTTP 异步接收与可取消等待。重连或退出时先唤醒接收线程，再取消句柄并等待最后的关闭回调，之后释放缓冲区；即使服务端不回复关闭握手，也不会阻塞在同步接收中。认证读取在线程中独立运行，不阻塞正常抢英雄循环。

```powershell
# 只读诊断；客户端已提权时，从管理员终端运行
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Diagnose
```

诊断验证 WebSocket 升级、订阅和空闲连接，输出接口状态码、条目数及游戏阶段，不输出认证信息。界面仅为独立认证助手自动申请管理员权限；命令行诊断仅报告需要权限。

## 源码

- `src/app.native`：原生界面。
- `src/titlebar.zig`：自绘标题栏和红黄绿窗口按钮。
- `src/ime.zig`：将画布输入焦点及光标位置同步给 Windows 输入法，定位候选栏并处理失焦清理；`zig build test-ime` 检查焦点与 DPI 坐标。
- `src/main.zig`：普通权限 UI 状态、消息和图片生命周期。
- `src/updater.zig` / `src/updater.ps1`：后台更新状态、正式版检查、更新包校验、进程退出握手、文件替换与恢复。`zig build test-core` 包含游戏阶段保护及真实原生工作线程启动 Windows PowerShell 的离线集成测试，验证环境、中文路径和结果读取。
- `src/champion_grid.zig` / `src/portraits.zig`：网格可视范围、连续滚动和共享头像图集。
- `src/champion_detail.native` / `src/champion_details.zig`：英雄详情浮窗、唯一的 haidou.pro Tab 与网页状态；打开详情时创建 WebView，禁用原生桥接。
- `src/portrait_worker.zig` / `src/catalog.zig`：有界后台头像解码队列、目录内容标识和重连缓存复用。
- `src/toasts.zig` / `src/toast.native`：成功提示去重、排队、定时关闭与自绘提示窗。
- `src/auth.zig`：认证监视、权限助手启动策略与重连身份管理。
- `src/auth_helper.zig` / `src/auth_discovery.zig`：独立管理员助手与固定的只读命令行查询。
- `src/auth_broker.zig` / `src/auth_protocol.zig`：受限本机命名管道、双向进程身份校验和有界认证消息。
- `src/lcu.zig`：普通权限 WinHTTP 通信。
- `src/logic.zig`：可独立测试的模式判断、优先级选择及退避规则。
- `src/service.zig`：事件驱动自动化、选取策略与本轮完成状态、动作确认、自动重连和资源缓存。
- `src/selection_policy_tests.zig`：选取策略、配置兼容、确认与重试、断线保留和新轮次重置测试，随 `zig build test-core` 执行。
- `src/journal.zig` / `src/journal_tests.zig`：后台持久日志、历史分页、清空屏障和落盘故障测试。
- `src/pick_audit.zig`：每轮顺位英雄机会、请求及确认结果汇总。
- `src/events.zig`：WebSocket 接收、WAMP 订阅、事件缓存和快照同步。
- `src/socket.zig`：可取消的 WinHTTP 异步 WebSocket、回调和句柄生命周期。
- `src/instance.zig`：单实例锁与重复启动唤回。
- `src/settings.zig`：配置解析和原子写入。
- `src/window_state.zig`：记录真实 Win32 窗口位置和尺寸，仅首次显示前恢复；`zig build test-window` 验证移动、隐藏、最小化与位置恢复。
- `src/tests.zig`：离线协议与自动化测试。
- `src/auth_broker_test.zig` / `src/auth_fixture.zig`：`zig build test-auth` 使用假凭据验证管道通信、身份拒绝、token 刷新、断开退出与读取取消；不请求 UAC、不读取真实认证，测试助手不打包。
- 手动运行 `zig build test-auth -Dtest-auth-elevated=true` 可额外验证测试助手实际获得管理员令牌并完成管道通信；此模式可能请求 Windows 授权，不在普通 CI 中执行，仍不读取真实客户端认证或发送游戏操作。
- `python scripts/test-auth-discovery.py` 使用模拟进程和临时连接文件，验证界面进程、后台进程、共享读取、未就绪状态及过期 PID 拒绝；不查询真实客户端，随 CI 执行。
- `scripts/test-startup.py`：构建后运行 `python scripts/test-startup.py`，将主程序及 WebView2 加载器复制到含空格和特殊字符的临时目录，使用隔离配置关闭自动接受和选人、载入离线优先英雄缓存及头像，验证窗口显示且启动后持续运行。此测试不携带管理员助手，不请求 UAC；结束后只停止测试进程并清理临时目录。可通过 `--build-dir` 检查指定构建。
- `scripts/test-updater.ps1`：运行 `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts/test-updater.ps1`，在临时目录用模拟 release 元数据、ZIP 和测试程序验证版本/摘要/文件清单拒绝、替换、文件占用回滚、确认后等待父进程退出及重新启动。不连接真实 LCU、不修改真实 release 或已安装程序。
- `scripts/test-transport.py` / `src/transport_test.zig`：本地 TLS/WAMP 故障测试。运行 `python scripts/test-transport.py`，仅需 Python 标准库和已安装的 Zig；模拟拒绝在 REST 连接上升级 WebSocket、空闲连接取消、远端断线、token 更新、端口/PID 更换和重订阅，不读取真实 LCU 认证。`scripts/fixtures/loopback.pem` 是公开的自签名测试证书及测试密钥，仅供这些离线测试使用。

UI 调试可使用 `zig build -Doptimize=ReleaseSafe -Dautomation=true`。Native SDK 会在 `.zig-cache/native-sdk-automation` 输出语义快照，并接受它的文件自动化协议。正常构建未启用该调试通道。

无客户端时可额外传入 `-Dpreview-catalog=本地文件.json` 检查完整网格；文件格式为 `[{"id":1,"name":"英雄名称","alias":"EnglishName","icon_path":"本地LCU缓存头像路径"}]`。此预览构建不连接 LCU、不写入偏好；测试后使用普通构建命令生成正式程序。

当前固定版本 SDK 的 `Runtime.initAt` 会跳过大型托盘数组的默认值；应用在启动钩子中初始化这些托盘状态字段，避免首次创建菜单失败。

`scripts/bootstrap.ps1` 会应用 `scripts/patch-native.ps1` 中的性能补丁：Native 原本会在每帧、每个头像绘制时重新散列整张图集，现在在图像注册/更新时计算一次并沿用 `ReferenceImage.content_fingerprint`。图像内容改变仍会触发 GPU 上传；重复显示不再扫描像素。补丁针对固定 SDK，源码不匹配时明确报错，重复执行无副作用；运行 `zig build test-images` 验证不变内容复用、修改内容失效及图片槽移除后的正确性。

主题的背景、卡片、文字、强调色和交互状态集中在 `src/theme.zig` 与 `src/main.zig` 的 token 映射中。默认采用经典金色风格；ChatGPT 两款是参考其中性灰和黑白层次的适配，并非官方主题导出。[Nord](https://www.nordtheme.com/docs/colors-and-palettes/) 和 [Catppuccin Mocha](https://catppuccin.com/palette/) 参考官方色板，并为本工具的状态和边界做了调整。旧设置缺少主题、或含未知主题名称时，回退为经典金色，其余偏好继续保留。正文、次要文字及选中按钮的文字配色均有 4.5:1 对比度检查。

界面字体从本机 Windows 字体目录读取微软雅黑，内存中提取字体集合的第一个字面供 Native SDK 使用；不复制或分发系统字体。游戏资源仍全部由 LCU 提供。

## GitHub CI

`.github/workflows/build.yml` 在每次 push、pull request 和手动运行时执行 Windows 构建：格式检查 → CPU 基线检查、离线单元测试、更新器集成与事务测试、图像缓存失效测试、输入法焦点与 DPI 测试、窗口位置测试、认证助手 IPC 测试及 TLS/WebSocket 故障测试 → ReleaseSafe 通用 x64 编译 → 真实窗口启动测试 → 上传便携程序（保留 14 天）。发布工作流也执行 CPU 基线和启动检查。不需要 League 客户端或任何账号密钥。更新器测试使用系统 Windows PowerShell；传输故障和启动测试使用运行器预装的 Python 标准库，不安装额外依赖；Zig 测试程序复用现有编译缓存。`.gitattributes` 固定文本使用 LF，避免 Windows 检出时的 CRLF 转换导致 `zig fmt --check` 失败。

缓存分两层：固定版本 Zig/Native SDK 按 bootstrap 脚本内容缓存；Zig 全局编译缓存和项目 `.zig-cache` 按构建配置和源码内容缓存。源码修改时回退到相同构建配置的缓存，复用标准库、C++ 宿主和未变更的编译结果。文档修改可直接命中已有编译缓存；同一分支的新 push 会取消过时任务。Actions 固定到完整 commit SHA。

## 创建 Release

在 GitHub 的 **Actions → Create release → Run workflow** 中选择默认分支运行 `.github/workflows/release.yml`：

- `version` 可选：填写 `0.2`、`v0.2`、`0.2.0` 或 `v0.2.0`，优先使用指定版本。省略补丁号时自动补 `0`，例如 `v0.2` 统一生成版本 `0.2.0`、标签 `v0.2.0` 和附件 `catengar-v0.2.0-windows-x64.zip`。版本必须大于 `app.zon` 中的当前版本；只接受两段或三段数字正式版本，每段不超过 65535（Windows 版本资源限制）。
- 留空 `version` 时，按 `bump` 自动升级：默认 `patch`（`0.1.0 → 0.1.1`）；也可选 `minor`（`0.1.0 → 0.2.0`）或 `major`（`0.1.0 → 1.0.0`）。

也可以使用 GitHub CLI：

```powershell
# 自动升级 patch
gh workflow run release.yml
# 指定版本；此时忽略 bump
gh workflow run release.yml -f version=0.2.0
# 简写版本会补齐为 0.2.0
gh workflow run release.yml -f version=v0.2
# 自动升级 minor
gh workflow run release.yml -f bump=minor
```

工作流同步更新 `app.zon` 及两个 Windows `.rc` 文件的版本，将版本提交与 `vX.Y.Z` 标签一起推送到默认分支，然后创建带自动生成更新说明的临时草稿。格式检查、离线测试与 ReleaseSafe 构建通过后，生成 `catengar-vX.Y.Z-windows-x64.zip` 并上传至该草稿的 release assets，上传成功后自动发布为 **pre-release**（`draft=false`、`prerelease=true`，不标记为 Latest）。ZIP 根目录包含 `catengar.exe`、`catengar-auth.exe`、`catengar-diagnose.exe`、`WebView2Loader.dll`、`WebView2-LICENSE.txt` 和 `README.md`；解压后保持这些文件在同一目录。应用显示版本和 EXE 版本资源来自本次升级后的源码。

完成后从运行摘要打开已发布的 pre-release，查看附件与说明，无需手动发布。**草稿和预发行版都不会触发应用更新；公开发布正式版及其完整 ZIP 后，应用才会发现它。** release 工作流同样执行原生更新工作线程集成测试和 `scripts/test-updater.ps1` 事务测试。发布前失败时使用该次运行的 **Re-run jobs**：同一运行会复用原标签、提交及草稿，即使默认分支已继续更新也不会再次升级版本；已发布的 release 不会被覆盖。重新点击 **Run workflow** 则表示创建下一版本。构建失败会保留版本提交、标签和草稿，方便重试。

创建草稿后直接使用创建接口返回的 ID 和链接，避免 release 列表尚未更新时误报失败；恢复和上传时按标签直接查询草稿。重跑会构建原标签对应的应用源码，同时保留本次检出的发布脚本，确保打包与上传继续使用后续修复过的发布逻辑。如果已经生成了标签或草稿，应重跑原任务，而不是再次点击 Run workflow 自动升级到另一版本。

工作流使用内置 `GITHUB_TOKEN` 的 `contents: write` 权限，不需要额外 PAT。仓库策略需允许 Actions 向默认分支及版本标签推送；保护规则拒绝时会明确失败，不会强制推送或绕过规则。所有 release 运行共享并发组；GitHub 默认最多保留一个等待中的运行，连续点击多次可能替换较早的等待项，请等待当前发布构建完成后再创建下一版。

发布工具的离线回归测试使用临时本地 Git 仓库与模拟 GitHub API，不会创建真实 release：`python -B -m unittest discover -s scripts -p test_release.py -v`。普通 CI 和 release 工作流都会执行这些测试。
