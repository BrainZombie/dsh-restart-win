#!/usr/bin/env node
/**
 * workspace-store-doctor.mjs —— 体检 / 修复 `$DSH_HOME/storages/workspace.json`
 *
 * 为什么需要它：workspace.json 是 workspace 域（`@deepseek-ai/dsh-workspace`）的
 * 持久化状态，宿主启动时会用 zod schema 校验整份数据。**任何一条记录不合规，
 * 整个域直接 FAILED**，于是 `workspaceRegistry` 不存在，侧栏「工作区」变成
 * 「暂无会话」，`workspace-kit` / `sessions-manager` / `mcp-connector` /
 * `dsh-bridge` / `web-ui-task-board` 等依赖项全部 PENDING，
 * 而报错只出现在宿主日志里（`[dsh-plugin-compat-check] PROBLEM ... state=FAILED`）。
 *
 * 已知的最常见破坏方式：外部脚本重建工作区花名册时把 `updatedAt` 写成
 * `Date.now()` 的毫秒数。schema 要求 `z.string()`，于是 number 直接判不合规。
 *
 * 用法：
 *   node scripts/workspace-store-doctor.mjs --check
 *   node scripts/workspace-store-doctor.mjs --check --json
 *   node scripts/workspace-store-doctor.mjs --fix --apply
 *   node scripts/workspace-store-doctor.mjs --archive-older-than 7
 *   node scripts/workspace-store-doctor.mjs --archive-older-than 7 --apply
 *   node scripts/workspace-store-doctor.mjs --unarchive <id,id> --apply
 *   node scripts/workspace-store-doctor.mjs --restore <backup.json>
 *
 * 选项：
 *   --home <dir>      指定 DSH_HOME（默认 $DSH_HOME，再退回 ~/.dsh）
 *   --min-bytes <n>   --archive-older-than 时忽略比它小的会话文件（默认 1024，滤掉空会话）
 *   --list            逐条列出将被归档的会话
 *   --force           宿主正在运行也写盘（只在 workspace 域已经 FAILED、不会回写时用）
 *   --json            机器可读输出
 *
 * 退出码：0 正常 / 1 数据或参数错误 / 2 宿主在跑且没给 --force
 *
 * 注意：状态在宿主内存里有一份，宿主正常运行时写盘会被整份盖回去。只有在
 * workspace 域 FAILED（那份 state 根本没能加载）或宿主已退出时才直接改文件。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import zlib from 'node:zlib';

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const value = (n) => {
  const i = argv.indexOf(n);
  return i >= 0 && i + 1 < argv.length && !argv[i + 1].startsWith('--') ? argv[i + 1] : undefined;
};

const CHECK = flag('--check');
const FIX = flag('--fix');
const APPLY = flag('--apply');
const FORCE = flag('--force');
const JSON_OUT = flag('--json');
const LIST = flag('--list');
const RESTORE = value('--restore');
const HOME_ARG = value('--home');
const OLDER_THAN = value('--archive-older-than');
const UNARCHIVE = value('--unarchive');
const RECONCILE = flag('--reconcile');
const MIN_BYTES = Number(value('--min-bytes') ?? 1024);

const DSH_HOME = HOME_ARG || process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const WS_FILE = path.join(DSH_HOME, 'storages', 'workspace.json');
const SESSIONS = path.join(DSH_HOME, 'sessions');
const DESKTOP_IMAGE = process.env.DSH_DESKTOP_IMAGE || 'DeepSeek Harness.exe';

function die(code, msg) {
  console.error(msg);
  process.exit(code);
}

function log(...a) {
  if (!JSON_OUT) console.log(...a);
}

function dshRunning() {
  if (process.platform !== 'win32') return false;
  try {
    const out = execFileSync('tasklist', ['/FI', `IMAGENAME eq ${DESKTOP_IMAGE}`, '/NH'], {
      encoding: 'utf8',
      windowsHide: true,
    });
    return new RegExp(DESKTOP_IMAGE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i').test(out);
  } catch {
    return false;
  }
}

const isIso = (v) => typeof v === 'string' && Number.isFinite(Date.parse(v)) && /^\d{4}-\d{2}-\d{2}T/.test(v);
const isStr = (v) => typeof v === 'string';
const isStrArray = (v) => Array.isArray(v) && v.every(isStr);

if (!fs.existsSync(WS_FILE)) {
  die(1, `找不到 ${WS_FILE}\n用 --home <dir> 指定 DSH_HOME，或确认 DSH 至少启动过一次。`);
}

if (RESTORE) {
  if (!fs.existsSync(RESTORE)) die(1, `找不到备份文件：${RESTORE}`);
  if (dshRunning() && !FORCE) die(2, '[abort] 宿主正在运行，先完全退出（或加 --force）。');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  fs.copyFileSync(WS_FILE, `${WS_FILE}.bak-before-restore-${stamp}`);
  fs.copyFileSync(RESTORE, WS_FILE);
  log('[done] 已从备份还原:', RESTORE);
  process.exit(0);
}

let ws;
try {
  ws = JSON.parse(fs.readFileSync(WS_FILE, 'utf8'));
} catch (e) {
  die(1, `workspace.json 不是合法 JSON：${e.message}\n先从 .bak-* 备份还原。`);
}

/** 校验整份状态；返回错误/警告数组。`fix` 就地修补能安全修补的字段。 */
function inspect(state, { fix = false } = {}) {
  const errors = [];
  const warnings = [];
  const fixed = [];
  const err = (where, msg) => errors.push({ where, msg });
  const warn = (where, msg) => warnings.push({ where, msg });

  if (!state.unit || state.unit.name !== 'workspace') err('unit', `unit.name 应为 'workspace'，实际 ${JSON.stringify(state.unit?.name)}`);
  if (state.unit?.version !== 2) err('unit', `unit.version 应为 2，实际 ${JSON.stringify(state.unit?.version)}`);

  const g = state.global;
  if (!g || typeof g !== 'object') {
    err('global', '缺少 global 对象');
    return { errors, warnings, fixed };
  }
  if (typeof g.initialized !== 'boolean') err('global.initialized', `应为 boolean，实际 ${typeof g.initialized}`);
  if (g.defaultWorkspaceId !== undefined && !isStr(g.defaultWorkspaceId)) err('global.defaultWorkspaceId', '应为 string');
  if (!isStrArray(g.workspaceIds)) err('global.workspaceIds', '应为 string[]');
  for (const key of ['archivedSessionIds', 'pinnedSessionIds']) {
    if (g[key] === undefined) {
      if (fix) {
        g[key] = [];
        fixed.push(`global.${key} 缺失，已补 []`);
      } else err(`global.${key}`, '缺失（schema 有 default，但补上更安全）');
    } else if (!isStrArray(g[key])) err(`global.${key}`, '应为 string[]');
  }

  const tables = state.tables?.workspaces;
  if (!tables || typeof tables !== 'object') {
    err('tables.workspaces', '缺少 workspaces 表');
    return { errors, warnings, fixed };
  }
  if (!Array.isArray(g.workspaceIds)) g.workspaceIds = [];

  for (const [wid, rec] of Object.entries(tables)) {
    const w = `tables.workspaces['${wid}']`;
    if (!rec || typeof rec !== 'object') {
      err(w, '记录不是对象');
      continue;
    }
    for (const key of ['path', 'title']) {
      if (!isStr(rec[key])) err(`${w}.${key}`, `应为 string，实际 ${typeof rec[key]}`);
      else if (!rec[key]) warn(`${w}.${key}`, '为空字符串');
    }
    for (const key of ['createdAt', 'updatedAt']) {
      const v = rec[key];
      if (isIso(v)) continue;
      if (typeof v === 'number' && Number.isFinite(v)) {
        const iso = new Date(v).toISOString();
        if (fix) {
          rec[key] = iso;
          fixed.push(`${w}.${key}: ${v} (epoch ms) → ${iso}`);
          continue;
        }
        err(`${w}.${key}`, `数字时间戳 ${v}（epoch ms）不是 schema 要求的 ISO-8601 字符串；这会让整个 workspace 域 FAILED`);
        continue;
      }
      err(`${w}.${key}`, `应为 ISO-8601 字符串，实际 ${typeof v} ${JSON.stringify(v)?.slice(0, 40)}`);
    }
    if (!isStrArray(rec.sessionIds)) {
      err(`${w}.sessionIds`, '应为 string[]');
    } else if (new Set(rec.sessionIds).size !== rec.sessionIds.length) {
      warn(`${w}.sessionIds`, '存在重复 id（显示层会重复，但不会让域失败）');
    }
  }

  // 交叉校验
  const ids = Object.keys(tables);
  const order = g.workspaceIds ?? [];
  const missingInOrder = ids.filter((id) => !order.includes(id));
  const extraInOrder = order.filter((id) => !ids.includes(id));
  if (missingInOrder.length) {
    if (fix) {
      g.workspaceIds = [...order.filter((id) => ids.includes(id)), ...missingInOrder];
      fixed.push(`global.workspaceIds 补上 ${missingInOrder.length} 个记录 id`);
    } else err('global.workspaceIds', `缺少记录 ${missingInOrder.join(', ')}`);
  }
  if (extraInOrder.length) err('global.workspaceIds', `引用了不存在的记录 ${extraInOrder.join(', ')}`);
  if (isStr(g.defaultWorkspaceId) && !ids.includes(g.defaultWorkspaceId)) {
    warn('global.defaultWorkspaceId', '指向不存在的记录（启动时会重建默认工作区）');
  }

  const byPath = new Map();
  const bySession = new Map();
  for (const [wid, rec] of Object.entries(tables)) {
    if (!isStr(rec?.path)) continue;
    if (byPath.has(rec.path)) err('tables.workspaces', `两个工作区指向同一路径 ${rec.path}`);
    byPath.set(rec.path, wid);
    for (const id of Array.isArray(rec.sessionIds) ? rec.sessionIds : []) {
      if (bySession.has(id)) err('tables.workspaces', `会话 ${id} 同时挂在 ${bySession.get(id)} 和 ${wid} 下`);
      bySession.set(id, wid);
    }
  }
  const archived = new Set(isStrArray(g.archivedSessionIds) ? g.archivedSessionIds : []);
  const pinned = new Set(isStrArray(g.pinnedSessionIds) ? g.pinnedSessionIds : []);
  for (const id of pinned) if (archived.has(id)) warn('global', `会话 ${id} 同时被置顶和归档（归档应丢弃置顶）`);

  return { errors, warnings, fixed };
}

/** sessions/ 下每个会话：id → { mtimeMs, size, dir } */
function indexSessions() {
  const map = new Map();
  let dirs;
  try {
    dirs = fs.readdirSync(SESSIONS, { withFileTypes: true });
  } catch {
    return map;
  }
  for (const wsDir of dirs) {
    if (!wsDir.isDirectory()) continue;
    const wp = path.join(SESSIONS, wsDir.name);
    let subs;
    try {
      subs = fs.readdirSync(wp, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const sub of subs) {
      if (!sub.isDirectory()) continue;
      const sp = path.join(wp, sub.name);
      let files;
      try {
        files = fs.readdirSync(sp).filter((f) => f.startsWith('session.')).sort();
      } catch {
        continue;
      }
      if (!files.length) continue;
      let best;
      for (const f of files) {
        try {
          const st = fs.statSync(path.join(sp, f));
          if (!best || st.size > best.size) best = { mtimeMs: st.mtimeMs, size: st.size };
        } catch {
          /* 单个文件读不到就跳过 */
        }
      }
      if (best) map.set(sub.name, { ...best, dir: wsDir.name });
    }
  }
  return map;
}

function writeState(state, label) {
  if (dshRunning() && !FORCE) {
    die(
      2,
      '\n[abort] 宿主正在运行。注册表内存里的那份 state 会在下一次工作区变更时整份盖掉这次写入。\n' +
        '        先完全退出 DSH 再写；只有确认 workspace 域已经 FAILED（内存里没有 state）时才加 --force。',
    );
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backup = `${WS_FILE}.bak-${label}-${stamp}`;
  fs.copyFileSync(WS_FILE, backup);
  fs.writeFileSync(WS_FILE, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
  return backup;
}

// ---------------------------------------------------------------- --check / --fix
if (CHECK || FIX) {
  const before = JSON.parse(JSON.stringify(ws));
  const { errors, warnings, fixed } = inspect(ws, { fix: FIX });
  const report = {
    workspaceJson: WS_FILE,
    workspaces: Object.keys(ws.tables?.workspaces ?? {}).length,
    archived: ws.global?.archivedSessionIds?.length ?? 0,
    pinned: ws.global?.pinnedSessionIds?.length ?? 0,
    errors,
    warnings,
    fixed,
  };
  if (FIX && fixed.length) {
    if (!APPLY) {
      log('[dry-run] 可修补项：');
      for (const f of fixed) log('  -', f);
      log('\n加 --apply 落盘。');
    } else {
      report.backup = writeState(ws, 'doctor-fix');
      log('[done] 备份:', report.backup);
      for (const f of fixed) log('[fixed]', f);
    }
  }
  if (JSON_OUT) {
    console.log(JSON.stringify({ ...report, beforeHash: undefined}, null, 2));
  } else {
    log('workspace.json :', report.workspaceJson);
    log('工作区数        :', report.workspaces);
    log('归档 / 置顶     :', report.archived, '/', report.pinned);
    if (warnings.length) {
      log('\n[warn]', warnings.length, '条');
      for (const w of warnings) log('  -', w.where, '→', w.msg);
    }
    if (errors.length) {
      log('\n[error]', errors.length, '条');
      for (const e of errors) log('  -', e.where, '→', e.msg);
      log('\n[fail] 这份数据会让 workspace 域整体 FAILED。加 --fix --apply 修可修项。');
    } else {
      log('\n[ok] schema 自检通过。');
    }
  }
  if (errors.length) process.exit(1);
  if (!OLDER_THAN && !UNARCHIVE) process.exit(0);
}

// ---------------------------------------------------------------- archive / unarchive
const touchingArchive = OLDER_THAN !== undefined || UNARCHIVE !== undefined;
if (touchingArchive) {
  const tables = ws.tables?.workspaces ?? {};
  if (!ws.global) ws.global = {};
  ws.global.archivedSessionIds = Array.isArray(ws.global.archivedSessionIds) ? ws.global.archivedSessionIds : [];
  const archived = new Set(ws.global.archivedSessionIds);
  const pinned = new Set(Array.isArray(ws.global.pinnedSessionIds) ? ws.global.pinnedSessionIds : []);

  const added = [];
  const removed = [];
  if (OLDER_THAN !== undefined) {
    const days = Number(OLDER_THAN);
    if (!Number.isFinite(days) || days <= 0) die(1, `--archive-older-than 需要正数天数，收到 ${OLDER_THAN}`);
    const cut = Date.now() - days * 86400_000;
    const sess = indexSessions();
    const skipped = { notInWorkspace: 0, noSessionFile: 0, tooSmall: 0, recent: 0, alreadyArchived: 0, pinned: 0 };
    const seen = new Set();
    for (const [wid, rec] of Object.entries(tables)) {
      for (const id of Array.isArray(rec.sessionIds) ? rec.sessionIds : []) {
        if (seen.has(id)) {
          skipped.notInWorkspace++;
          continue;
        }
        seen.add(id);
        if (archived.has(id)) {
          skipped.alreadyArchived++;
          continue;
        }
        if (pinned.has(id)) {
          skipped.pinned++;
          continue;
        }
        const info = sess.get(id);
        if (!info) {
          skipped.noSessionFile++;
          continue;
        }
        if (info.size < MIN_BYTES) {
          skipped.tooSmall++;
          continue;
        }
        if (info.mtimeMs > cut) {
          skipped.recent++;
          continue;
        }
        added.push({ id, workspace: rec.title, mtimeMs: info.mtimeMs, size: info.size });
      }
    }
    added.sort((a, b) => b.mtimeMs - a.mtimeMs);
    log(`[plan] 归档 ${added.length} 条（早于 ${new Date(cut).toISOString().slice(0, 16).replace('T', ' ')}，且 ≥${MIN_BYTES} 字节）`);
    const byWs = new Map();
    for (const a of added) byWs.set(a.workspace, (byWs.get(a.workspace) || 0) + 1);
    for (const [k, n] of [...byWs].sort((x, y) => y[1] - x[1])) log('  ', String(n).padStart(4), k);
    log('[plan] 跳过：', JSON.stringify(skipped));
    if (LIST) {
      for (const a of added) {
        log('   ', new Date(a.mtimeMs).toISOString().slice(0, 16).replace('T', ' '), String(a.size).padStart(9), a.id, a.workspace);
      }
    }
  }

  if (UNARCHIVE !== undefined) {
    for (const id of String(UNARCHIVE).split(',').map((s) => s.trim()).filter(Boolean)) {
      if (archived.delete(id)) removed.push(id);
    }
    log(`[plan] 取消归档 ${removed.length} 条`);
  }

  if (JSON_OUT && !APPLY) {
    console.log(JSON.stringify({ archiveAdds: added.length, unarchiveRemoves: removed.length, dryRun: true }, null, 2));
    process.exit(0);
  }
  if (!APPLY) {
    log('\n[dry-run] 未写盘。确认后加 --apply。');
    process.exit(0);
  }

  for (const a of added) archived.add(a.id);
  ws.global.archivedSessionIds = [...archived];
  const { errors } = inspect(ws, { fix: false });
  if (errors.length) {
    for (const e of errors) console.error('[error]', e.where, '→', e.msg);
    die(1, '[abort] 写完会不合规，未落盘。');
  }
  const backup = writeState(ws, 'doctor-archive');
  log('[done] 备份:', backup);
  log('[done] 归档集合:', ws.global.archivedSessionIds.length, '条（本次 +', added.length, '，-', removed.length, '）');
  process.exit(0);
}


// ---------------------------------------------------------------- --reconcile
/**
 * 按磁盘事实重建每个工作区的花名册：
 *  - 只保留 header cwd 与工作区 path 一致、且不是子代理（delegationDepth > 0）的会话；
 *  - 把磁盘上属于该 cwd、但还没登记的主会话按 mtime 倒序补进花名册；
 *  - 清掉重复 id、缺失文件、指向别处的 id；
 *  - 其它字段（title/path/createdAt）与归档/置顶集合原样保留，updatedAt 写成 ISO。
 * 这是「写入方」唯一推荐的重建路径：先 --reconcile 预演，再 --apply。
 */
const canon = (v) => String(v).replace(/\//g, '\\').replace(/\\+$/, '').toLowerCase();

function readSessionHeader(file) {
  try {
    const buf = fs.readFileSync(file);
    let plain;
    try {
      plain = zlib.zstdDecompressSync(buf);
    } catch {
      plain = buf;
    }
    const nl = plain.indexOf(10);
    const head = nl === -1 ? plain : plain.subarray(0, nl);
    const value = JSON.parse(head.toString('utf8'));
    return value && typeof value === 'object' ? value : undefined;
  } catch {
    return undefined;
  }
}

/** id -> { cwd, depth, size, mtimeMs }，只读每个会话目录里最大的那份日志的 header。 */
function indexSessionsWithHeaders() {
  const map = new Map();
  let dirs;
  try {
    dirs = fs.readdirSync(SESSIONS, { withFileTypes: true });
  } catch {
    return map;
  }
  for (const wsDir of dirs) {
    if (!wsDir.isDirectory()) continue;
    const wp = path.join(SESSIONS, wsDir.name);
    let subs;
    try {
      subs = fs.readdirSync(wp, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const sub of subs) {
      if (!sub.isDirectory()) continue;
      const sp = path.join(wp, sub.name);
      let files;
      try {
        files = fs.readdirSync(sp).filter((f) => f.startsWith('session.')).sort();
      } catch {
        continue;
      }
      let best;
      for (const f of files) {
        try {
          const st = fs.statSync(path.join(sp, f));
          if (!best || st.size > best.size) best = { path: path.join(sp, f), size: st.size, mtimeMs: st.mtimeMs };
        } catch {
          /* 单个文件读不到就跳过 */
        }
      }
      if (!best) continue;
      const header = readSessionHeader(best.path);
      if (!header || typeof header.id !== 'string') continue;
      map.set(header.id, {
        cwd: typeof header.cwd === 'string' ? header.cwd : undefined,
        depth: Number.isInteger(header.delegationDepth) ? header.delegationDepth : 0,
        size: best.size,
        mtimeMs: best.mtimeMs,
      });
    }
  }
  return map;
}

if (RECONCILE) {
  const tables = ws.tables?.workspaces ?? {};
  const sessions = indexSessionsWithHeaders();
  const owners = new Map(); // session id -> workspace id (重建后)
  const report = { workspaces: [], attached: 0, droppedSubagent: 0, droppedForeign: 0, droppedMissing: 0, deduped: 0, changed: [] };

  // 第一遍：清点现有花名册
  for (const [wid, rec] of Object.entries(tables)) {
    const pathKey = canon(rec.path);
    const keep = [];
    let droppedSub = 0;
    let droppedForeign = 0;
    let droppedMissing = 0;
    let deduped = 0;
    const seen = new Set();
    for (const id of Array.isArray(rec.sessionIds) ? rec.sessionIds : []) {
      if (seen.has(id)) {
        deduped += 1;
        continue;
      }
      seen.add(id);
      const info = sessions.get(id);
      if (!info) {
        droppedMissing += 1;
        continue;
      }
      if (info.depth > 0) {
        droppedSub += 1;
        continue;
      }
      if (!info.cwd || canon(info.cwd) !== pathKey) {
        droppedForeign += 1;
        continue;
      }
      keep.push(id);
      owners.set(id, wid);
    }
    report.droppedSubagent += droppedSub;
    report.droppedForeign += droppedForeign;
    report.droppedMissing += droppedMissing;
    report.deduped += deduped;
    report.workspaces.push({ id: wid, title: rec.title, path: rec.path, before: Array.isArray(rec.sessionIds) ? rec.sessionIds.length : 0, after: keep.length, droppedSub, droppedForeign, droppedMissing, deduped });
  }

  // 第二遍：把磁盘上未登记的主会话补回对应工作区
  const byPath = new Map();
  for (const [wid, rec] of Object.entries(tables)) byPath.set(canon(rec.path), wid);
  const additions = new Map(); // wid -> [{id, mtimeMs}]
  let unattached = 0;
  for (const [id, info] of sessions) {
    if (info.depth > 0) continue;
    if (!info.cwd) continue;
    if (owners.has(id)) continue;
    const wid = byPath.get(canon(info.cwd));
    if (!wid) {
      unattached += 1;
      continue;
    }
    const bucket = additions.get(wid) ?? [];
    bucket.push({ id, mtimeMs: info.mtimeMs });
    additions.set(wid, bucket);
  }
  report.attached = [...additions.values()].reduce((n, b) => n + b.length, 0);
  report.unattached = unattached;

  // 组装新花名册：保留原顺序，再按 mtime 倒序追加新成员
  for (const [wid, rec] of Object.entries(tables)) {
    const keep = [];
    const seen = new Set();
    for (const id of Array.isArray(rec.sessionIds) ? rec.sessionIds : []) {
      const info = sessions.get(id);
      if (!info || info.depth > 0) continue;
      if (!info.cwd || canon(info.cwd) !== canon(rec.path)) continue;
      if (seen.has(id)) continue;
      seen.add(id);
      keep.push(id);
    }
    const add = (additions.get(wid) ?? []).sort((a, b) => b.mtimeMs - a.mtimeMs);
    for (const a of add) if (!seen.has(a.id)) {
      seen.add(a.id);
      keep.push(a.id);
    }
    if (keep.length !== (Array.isArray(rec.sessionIds) ? rec.sessionIds.length : 0)) {
      report.changed.push({ id: wid, title: rec.title, before: (rec.sessionIds ?? []).length, after: keep.length });
      rec.sessionIds = keep;
      rec.updatedAt = new Date().toISOString();
    }
  }

  // 检查 + 汇报
  const { errors } = inspect(ws, { fix: false });
  if (!JSON_OUT) {
    log('工作区花名册重建（host 退出后才可落盘）：');
    for (const w of report.workspaces) {
      log(`  ${String(w.before).padStart(4)} → ${String(w.after).padStart(4)}  ${w.title}  (${w.path})` +
        (w.droppedSubagent || w.droppedForeign || w.droppedMissing || w.deduped
          ? `  [子代理 ${w.droppedSubagent}, 异地 ${w.droppedForeign}, 缺失 ${w.droppedMissing}, 重复 ${w.deduped}]`
          : ''));
    }
    log(`  新增登记 ${report.attached} 条；未归属 (无同名工作区) ${report.unattached} 条`);
    if (errors.length) for (const e of errors) console.error('[error]', e.where, '→', e.msg);
  }
  if (JSON_OUT) {
    console.log(JSON.stringify({ ...report, errors, apply: APPLY }, null, 2));
  }
  if (errors.length) die(1, '[abort] 重建后仍不合规，未落盘。');
  const changed = report.changed.length > 0 || report.attached > 0;
  if (!APPLY) {
    log(changed ? '\n[dry-run] 未写盘。确认后加 --apply。' : '\n[ok] 花名册已经与磁盘一致，无需写盘。');
    process.exit(0);
  }
  if (!changed) {
    log('[ok] 无需写盘。');
    process.exit(0);
  }
  const backup = writeState(ws, 'doctor-reconcile');
  log('[done] 备份:', backup);
  log('[done] 已按磁盘事实重建花名册。重启宿主后生效。');
  process.exit(0);
}

if (!CHECK && !FIX && !RECONCILE) die(1, '需要 --check / --fix / --reconcile / --archive-older-than <days> / --unarchive <ids> / --restore <file> 之一。');
