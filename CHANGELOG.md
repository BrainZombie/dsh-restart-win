# 变更记录

## 0.5.0 — 宿主发现放到 WMI 服务端、探针换成原始 TCP

这一版继续只改「读机器状态的代价」与几个实测踩到的正确性问题。行为语义（401/200 才算就绪、
退出码、终态词、信封必选字段）不变。

### 引擎（scripts/dsh-restart.ps1）

- **宿主发现改为服务端筛选**：`Get-DesktopHostProcesses` 不再按进程名 `Name='DeepSeek Harness.exe'`
  写死，也不再拉全表在 PowerShell 里筛 500 个命令行；改为一条 `CommandLine LIKE '%dsh-desktop-host%'`
  交给 WMI 筛，完整路径仍由正则严格判定。改名的壳同样认得出，一次查询 ~120-270ms。
  `Find-DesktopHostRows` 带进程内缓存，`Resolve-HostKind` / `Resolve-DesktopProfileName` / 实例发现
  不再各查一遍宿主。
- **探针换成原始 TCP**（`Get-HttpStatusCodeDetail`）：直接 `ConnectAsync(...).Wait(预算)` + 写请求 +
  读状态行。HttpClient/HttpWebRequest 两个栈在 3082 上每次要 1.6-2s，而这只是「问几号状态码」。
  三条实测坑写进注释：死端口上同步构造函数会卡 ~14s；`try` 里 return + `finally` 里 Close 会让
  一次成功调用固定多出 2s；读超时必须显式设 `NetworkStream.ReadTimeout`。
- **`Test-WebAuthUrl` 带路径与端口**：token 在 `?token=` 上，只请求 `/` 会让一个有效 token 被判成
  失效（实测把 `launchUrl` 打成 unknown）；持久地址的端口不在当前实例实际监听的端口里时直接判过期，
  不再去探一个死端口。
- **`Read-FileTailText`**：取 boot token 只读日志尾部 64KB（几十 MB 的日志全文 `Select-String` 要 1-2s）。
- **端口挑面**：命中 200 即停，其余端口标 `stage=unprobed`；`Get-AuxPortHint` / `Save-AuxPortHint`
  把实测确认的附件端口（如 CDP 的 4173，也回 200）记进 `state\aux-ports.json`（按 Electron 主进程 pid
  归属，pid 变了就不认），下次标 `stage=skipped` 不探。401 面永不记为附件面。
- **`instances-2` 补探**：第一次采样早退留下的 `unprobed` 端口，用一次 `-ProbeAll` 补探，
  选面结论仍以第一次为准 —— 只为了让建议表学到东西。
- **计时**：`Add-Phase` 同标签累加（不再被后续探针覆盖），基准换成 `Stopwatch`（`Get-Date` 每次 ~1.1ms），
  并把 `ArrayList`/WMI/类型解析的冷启动（~100ms + ~270ms）放到计时之前预热；`phases` 新增
  `start` / `cim` / `history` / `auth-file` / `auth-log` / `instances-2`。
- **`Read-HostServing`**：验证循环里每 800ms 问一次就绪，改用原始 TCP 探针（`Test-HttpServing` 保留原样）。
- **修复（5.1）**：`-Status` 里 `schtasks /Query` 的 stderr 在 `$ErrorActionPreference='Stop'` 下会直接
  中断整个命令 —— 查不到计划任务的机器上 `-Status` 会整行 abort。现在显式收掉 stderr 行。

### 实测（本机，561 个进程，桌面宿主 4 个监听端口）

| 指标 | 0.4.0 | 0.5.0 |
|---|---|---|
| `-Status -Json` 引擎耗时（中位，8 次） | 1.7s（好）/ 3.5s（常见） | 2.7s（中位）/ 13s（宿主自己偶发 10s 慢） |
| `-Status` 人读（中位） | 5.6s | 3.5s |
| 主面探测 | 26-50ms | 3ms（原始 TCP） |
| 宿主发现 | ~1000ms（三处各查一次） | ~400-900ms（一次查询，缓存复用） |

> 13s 那一轮不是脚本的开销：同一轮里 3082 端口自己的读请求就占了 10.05s（宿主偶发慢回），
> 探针按预算等它，与引擎改动无关。

### 测试

`npm test`：88 通过 / 0 失败；parity **254/254**；integration 16 通过（`--with-engine` 17 通过）；
`check-encoding` 在 pwsh 7.6 与 5.1 下 errors=0。


## 0.4.0 — 一次调用只扫一遍机器状态

这一版全部落在「引擎怎么读机器」上：端口表、进程表、宿主 HTTP 面。行为语义
（401/200 才算就绪、退出码、终态词、信封 14 个字段）一个都没动，改的是**读它们的代价**。

### 引擎（scripts/dsh-restart.ps1）

- **新增** `Get-NetstatListenerRows`：全脚本唯一调 `netstat` 的地方，解析成 `{port,pid,host}` 行。
  `Test-PortListening` / `Get-PortOwner` / `Get-ListeningPorts` 全部改读它，进程内缓存 3 秒，
  等待循环里显式 `-Refresh`。以前一次 `-Status` 要扫两三遍整张端口表。
- **新增** `Get-ProcessIndex`：一次 CIM 全表建 `pid → 进程` 字典（同样 3 秒缓存）。
  桌面实例发现不再对每个候选单独 `Get-CimInstance -Filter`。
- **新增** `Invoke-HttpProbe` + `Resolve-HostPort`：按 **200 > 401 > 303 > 其他** 排序逐端口探测，
  命中即返回。连接预算（1.5s）与请求预算（5s）分开 —— 用 HttpClient 一个超时砍两头时，
  3082 端口实测要 1.6-2s，会把一个活着的 200 探成 0（假阴性）。探针显式 `Proxy = $null`，
  不走系统代理。只在「端口通了但给状态码」时 700ms 后重问一次：宿主启动早期会先在
  随机端口上回 404、隔一秒才变 401/200。
- **修复** 端口挑选的稳定性：旧逻辑「第一个回应就算」，桌面宿主同时监听 200 的主面、
  4173 的浏览器调试面、401 的面板面、404 的兜底面 —— 挑到哪个取决于 netstat 顺序。
  现在固定优先级，且 `instances[].probe` 里留下每个端口的实测状态与耗时。
- **修复** 兜底面胜出：401 曾经排在 303 之后，主面读慢一次就会让那个稳定回 404 的兜底端口
  被报成「就绪」。401 现在是第二序位。
- **新增** 分阶段耗时：`-Json` / `-ResultFile` 时信封多一个 `phases` 键
  （prepare / pre-check / host-kind / probe:端口号 / instances / http-probe / auth-url / total），
  人读模式零开销。14 个必选字段与层级不变。
- **新增** `status.pnpmResolved` / `status.cliCmd`：把「实际存在的那个 pnpm.mjs」与
  「安装自带的 dsh.cmd」直接报出来。官方布局在 `resources\runtime` 下，解包后桥把 pnpm 放到
  `resources\app\runtime` 下，外部工具（`scripts\dsh-repair.ps1`）以前自己拼单一路径会拼错。

### 工具

- `scripts/dsh-repair.ps1` 优先用引擎给的 `pnpmResolved`，自己拼路径只作最后兜底。

### 测试与文档

- `test/parity.mjs` 新增 §7 的 D-12…D-15 四条断言（唯一 netstat 扫描点、进程表索引、
  端口优先级与代理绕过、分阶段耗时开关），`docs/parity-matrix.md` 同步。**254/254 行全绿**。
- 本机实测：`-Status -Json` 12.0s → 8.7s（同机、同 561 个进程），单次 `dsh-restart-win -Status`
  7.6s → 5.5s；端口探测从「4 个端口各等超时」变成 300ms 量级。


## 0.3.0 — 机器事实：不再猜安装位置

这一版把「这台机器上 dsh 装在哪、用哪个 node/pnpm」从**推测**改成**探测 + 落盘**，并修掉四个
本机实测暴露的问题。所有改动都不改变 web 宿主的行为与既有退出码 / 终态词。

### 引擎（scripts/dsh-restart.ps1）

- **新增** `Get-DesktopInstallPaths`：桌面版可执行文件从系统登记处反查 —— 卸载登记
  （HKCU/HKLM `Uninstall\*` 的 `DisplayIcon` / `InstallLocation`）、`App Paths`、开始菜单与桌面
  快捷方式的 `TargetPath`。装在非默认目录、App 又正好停着时，这是唯一的确定来源；全部落空
  仍然 fail-closed，不扫盘。
- **新增** `machine.json`（`<StateDir>\machine.json`）作为**第一候选**：`Get-MachineConfig` 读它，
  文件缺失或损坏时返回 `$null` 继续探测，绝不抛。
- **新增** 参数 `-DesktopApp <path>`：显式给出即短路整条探测链；配合 `-Record` 时自动构造启动命令，
  省掉手写引号。
- **新增** `Get-SystemTool`：`netstat` / `taskkill` / `schtasks` / `robocopy` / `cmd` 一律解析到
  `%SystemRoot%\System32`，不再依赖调用方 PATH（git-bash、精简 PATH 的计划任务下行为一致）。
- **修复** `Test-DesktopVerify`：未知 profile 名在桌面版下不再是错误 —— 先按用户层覆盖目录推导，
  与主流程一致（以前会把「profile 名传错」直接报成「真实 profile 不存在」）。
- **修复** `-Status` 的 `HostKind` 降级：宿主停着时 auto 探测曾退化成 `web`，让「重启 → 停止 →
  拉起」的中段看到幻影 `dsh web / 3080`。
- **新增** `status` 字段：`desktopApp` / `desktopAppSource` / `runtimeDir` / `appRoot` / `pnpm` /
  `nodeExe` —— 外部工具（安装器、修复脚本）不必自己推导安装根。

### 工具

- **新增** `scripts/dsh-repair.ps1`：插件安装 / 修复通道（会话空窗闸门 → 快照 → 停机 → `pnpm add` →
  落盘检查 → 查遮蔽 → 拉起 → 健康校验，任一步失败回滚）。它没有自己的路径知识，全部取自
  `dsh-restart-win -Status -Json`，动作全部委托引擎；`-Report <path>` 输出机器可读结果。
- **新增** `scripts/dsh-config.ps1`：一次探测把机器事实写进 `machine.json`（`-Show` 预览 /
  `-Reset` 删除 / `-DesktopApp` 手工指定）。
- **新增** `scripts/probe-notice.ps1`：只读回归 —— AST 抽出续跑通知写入函数，在临时目录里跑三次，
  验证键序、ISO-8601（`Z` 结尾）、`attempts=0`、UTF-8 无 BOM、无 `.tmp` 残留、调用点仍在停机之前。

### 测试与文档

- `test/parity.mjs`：新增 §14「机器事实 / 反硬编码」7 条断言（MP-01…MP-07）；补齐矩阵里
  `X-07` / `X-08` / `X-09` 三条一直缺失的终态词探针；`schtasks` / `taskkill` / `netstat` 的探针
  跟随绝对路径解析更新。**250/250 行全绿**。
- `docs/parity-matrix.md`：新增 §15（MP 组），记录本次四类去硬编码改动与其可执行断言。
- `README.zh.md`：新增 §5.5（`dsh-repair.ps1`）、§5.6（`dsh-config.ps1`）、§8 的安装事实字段表、
  §10 的 `machine.json` 与 `dsh-repair-*` 文件。
