# 工作区状态库与侧栏分批展开

两件事经常一起出问题：`workspace.json` 被写坏导致**整个工作区域 FAILED**，以及侧栏把几百条会话一次性
渲染进 DOM。这份文档记录诊断口径、修复工具和侧栏 overlay 的预期行为。

## 1. `storages/workspace.json` 是强 schema 的

`<DSH_HOME>/storages/workspace.json` 是 `@deepseek-ai/dsh-workspace` 的持久化状态，启动时整份数据要过
`zod` 校验（`src/spec.ts`）：

```ts
const workspaceRecord = z.object({
  path: z.string(),
  title: z.string(),
  sessionIds: z.array(sessionId),
  createdAt: z.string(),
  updatedAt: z.string(),
})
```

**任何一条记录不合规，域直接 FAILED**，不是跳过那条记录。后果是连锁的：

```
include:workspace  state=FAILED  reason=DomainError: domain 'workspace':
  stored record '<uuid>' in table 'workspaces' does not match its schema
  ├─ include:workspace-controller      PENDING missing=[workspaceRegistry]
  ├─ include:session-controller        PENDING missing=[fileUploads, workspaceRegistry]
  ├─ include:workspace-kit             PENDING missing=[workspaceRegistry]
  ├─ include:dsh-sessions-manager      PENDING missing=[workspaceRegistry]
  ├─ include:mcp-connector             PENDING missing=[workspaceRegistry]
  ├─ include:dsh-bridge                PENDING missing=[workspaceRegistry]
  ├─ include:web-ui-task-board         PENDING missing=[workspaceRegistry]
  └─ include:web-ui-session-archive    PENDING missing=[workspaceRegistry]
```

用户看到的是：侧栏「工作区」变成「暂无会话」、工作区卡片消失，而会话文件一个都没少。错误只写在
`host.desktop.out.log` 的 `[dsh-plugin-compat-check] PROBLEM` 行里。

已知的破坏方式：外部脚本按 header `cwd` 重建工作区花名册时把 `updatedAt` 写成 `Date.now()` 的毫秒数。
`z.string()` 直接判不合规 —— 时间戳是数字也会让整份状态作废。

### 体检与修复

```bash
node scripts/workspace-store-doctor.mjs --check
node scripts/workspace-store-doctor.mjs --fix --apply      # 数字时间戳 → ISO、补空数组、补 workspaceIds
node scripts/workspace-store-doctor.mjs --check --json
```

`--check` 用 exit 1 表示“这份数据会让域 FAILED”，可以直接当门禁。它校验的项：

- `unit.name === 'workspace'`、`unit.version === 2`
- `global.initialized` 是 boolean，`workspaceIds` / `archivedSessionIds` / `pinnedSessionIds` 是 `string[]`
- 每条记录 `path` / `title` 是字符串，`createdAt` / `updatedAt` 是可解析的 ISO-8601 字符串，`sessionIds` 是 `string[]`
- 交叉项：`workspaceIds` 与表里的记录 id 一致、默认工作区存在、无重复路径、无会话被两个工作区同时占用

**写盘前提**：宿主正常运行时，注册表内存里有一份 state，任何工作区变更都会把旧 state 整份写回磁盘。
只有在域已经 FAILED（那份 state 根本没加载）或宿主已退出时才直接改文件；工具默认拒绝在宿主运行时写盘，
确认过前提再加 `--force`。

## 2. 批量归档

官方的“归档会话”就是 `global.archivedSessionIds` 这个集合：不删文件、不改 `sessionIds` 槽位、不碰 mtime，
所以 `session-find` / `session_show` 照常能读到已归档会话的原文。

```bash
node scripts/workspace-store-doctor.mjs --archive-older-than 7            # 预演
node scripts/workspace-store-doctor.mjs --archive-older-than 7 --list     # 逐条看
node scripts/workspace-store-doctor.mjs --archive-older-than 7 --apply    # 落盘
node scripts/workspace-store-doctor.mjs --unarchive <id,id> --apply
```

筛选口径：在工作区花名册里、会话文件存在、`≥ --min-bytes`（默认 1024，滤掉空会话）、mtime 早于 N 天、
不在归档集合里、不在置顶集合里（归档与置顶互斥）。恢复走官方 UI 的「取消归档」，或 `--unarchive`。

## 3. 侧栏分批展开（app overlay）

`@deepseek-ai/dsh-client-ui-workspace` 的原生行为是：每个工作区默认显示 5 行 + 「展开其余 N 个会话」，
点一次 +5 行；而“每页会话数”在原始 bundle 里根本没有实现（菜单项拿不到 state）。

overlay（由 `@local/dsh-local-repair` 的 `appOverlays` 覆盖，见其 `repairs/registry.json`）做三件事：

1. `.GAkraW_wide.GAkraW_treeBody { overflow-y:auto }` —— 让会话树本身成为滚动容器；
2. 把行水位改成**分批展开**：折叠 5 行，每点一次「展开其余 N 个会话」追加一批；
3. 视图选项菜单新增「展开批大小」：50 / 100 / 200 / 500 / 1000（默认 200，切换分组方式时重置）。
   批大小只决定每次追加多少，**不设上限** —— 最后一批显示剩余全部，尾部永远可达。

`reason` 字段里写清了动机，`version` 锁定到当前 app 的 bundle 版本：app 升级后版本号不匹配，overlay 会被
跳过并在启动日志里报告，而不是把为旧版本写的代码贴进新版本。


## 4. 会话列表预算与会话加载优化（persistence overlay）

侧栏只显示 `session/list` 里有的会话；`session/list` 又来自 `session-persistence-jsonl` 的
`list()`。在这台机器上（900+ 会话、233 MB 日志）这条链路有三处会被卡住，overlay 分别处理：

| 症状 | 根因 | overlay 的处理 |
| --- | --- | --- |
| 某个工作区明明有会话，侧栏却是空的 | `list()` 每个项目目录只取**最新 200 份**；`C:\tools` 里 211 份 mnemon 子代理外壳把 82 份真会话挤出了窗口 | 每个项目目录的窗口默认 **1000** 份（`listBudget.limit`），本机最大的目录 312 份，全部进窗口 |
| 宿主冷启动慢、日志里 `[header-cache] listed 826/909` 反复出现 | 每次 sweep 都要解 900+ 个 zstd 头帧并逐条 realpath 校验身份 | **跨重启 header 索引**：`<DSH_HOME>\cache\session-header-index.json`，键是日志路径 + (size, mtimeMs)，命中就直接复用，未命中才解码；写盘是 tmp+rename，失败只退回旧路径 |
| 侧栏 / 会话管理器 / 搜索索引各拉一份 list，互相重叠 | 三个轮询器各自按自己的定时器调用 `list()` | 1.5 s 内的并发调用**合并成一次 sweep**，后来者等同一个 in-flight 结果（带 signal 的调用保持原路径，不被合并） |

文件位置（`@local/dsh-local-repair` 的 `overlays`，`scope: shared`）：

```
patches/dsh-session-persistence-jsonl-0.2.2-rc.3/lib/index.js
  -> ~/.dsh/profiles/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js
```

诊断日志（`host.<hostKind>.err.log`）：

```
[local-repair] list() budget: 909 generation(s) in 11 project(s), 909 considered,
               826 listed, 2 pending, limit=1000/project, header-cache=826 hit(s), 120ms
```

`listed` 小于 `considered` 说明有会话在 header 阶段被判无效（格式不支持 / 身份不符），不是被预算裁掉；
`header-cache` 命中数在冷启动后的第二次 sweep 起应当接近 `considered`。

## 5. 花名册重建（`--reconcile`）

工作区的 `sessionIds` 是**有序的所有权账本**，不按 header 自动重算；外部脚本重建它时最容易犯两种错：
把子代理会话写进去（侧栏永远不显示，却占着预算），或者把数字 epoch 写进 `updatedAt`（整域 FAILED）。

`workspace-store-doctor.mjs --reconcile` 是唯一推荐的重建路径：

```bash
node scripts/workspace-store-doctor.mjs --reconcile           # 预演，只读
node scripts/workspace-store-doctor.mjs --reconcile --apply   # 宿主退出后落盘（默认拒绝在宿主运行时写）
```

规则：

- 只保留 header `cwd` 与工作区 `path` 一致、且 `delegationDepth === 0` 的会话；子代理、异地会话、
  磁盘上已经不存在的 id 一律从账本里清掉（会话文件不动）；
- 磁盘上属于该 cwd、却没登记的主会话，按 mtime 倒序补回账本；
- 去重、保持原顺序；`updatedAt` 写成 ISO；`archivedSessionIds` / `pinnedSessionIds` / `title` / `path`
  原样保留；
- 写完前用 `--check` 同一套 schema 再验一遍，不通过就不落盘；落盘前固定备份
  `workspace.json.bak-doctor-reconcile-<stamp>`。

本机 2026-11-24 的实测账本（重建前后）：

```
266 → 245  default-workspace
 82 →  50  tools            # 32 条是子代理，侧栏本来就不显示
289 →   1  Mnemon · Skills  # 288 条是 mnemon 子代理，path 也不是它们的 cwd
```

重建之后再配合 §4 的 1000 份窗口，`tools` 的 50 条主会话才会真正出现在侧栏（之前窗口里只剩
mnemon 外壳，组就是空的）。
