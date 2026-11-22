# 变更记录

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
