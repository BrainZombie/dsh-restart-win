#!/usr/bin/env node
/**
 * Parity harness: `docs/parity-matrix.md` → machine assertions.
 *
 * The matrix is the single source of truth for "no capability was lost"
 * (CONTRACT §0.2 / §7). A table nobody executes decays into prose, so this file
 * turns every row into three assertions:
 *
 *   1. **Anchor** — the "插件目标位置" cell resolves. A `scripts/x.ps1::Fn`
 *      anchor must exist as `function Fn`, `lib/tools.js::win_restart` must be a
 *      real tool name, `…@param` must be declared in the param block,
 *      `lib/config.js#key` must be a real config key, and every referenced file
 *      must exist. A `**不带入**` row asserts absence instead.
 *   2. **Behaviour** — the row's own `PROBES` entry encodes what the matrix's
 *      "验证方式" column promises (`parity:<ID> 断言 …`). Symbol presence alone
 *      proves nothing, so every row has at least one behavioural probe.
 *   3. **Evidence** — the verification cell either carries `parity:<ID>` (this
 *      test) or an explicit manual/local prefix (`本机:` / `人工:` / `扫描词表`),
 *      each cross-referenced ID must exist, and every row must have a probe.
 *
 * Failure modes this file is *supposed* to surface (they are findings, not test
 * bugs): an empty evidence cell, an anchor pointing at a file or symbol that
 * does not exist, a duplicate or missing capability id, a row with no machine
 * assertion, and a probe whose contract does not hold in the target.
 *
 * Usage:
 *   node test/parity.mjs                 # full run, exit 1 on any finding
 *   node test/parity.mjs --only=P-01,X-26
 *   node test/parity.mjs --json          # machine-readable report
 *   node test/parity.mjs --summary       # per-section counts only
 *
 * Portable: reads files only, so it runs on Linux CI as well. Local-only
 * evidence (`.local/evidence/**`) is validated when present and reported as
 * "not collected here" otherwise — never silently treated as passing.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { CONFIG_KEYS, DEFAULTS } from '../lib/config.js';
import { TOOL_NAMES } from '../lib/tools.js';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const MATRIX = 'docs/parity-matrix.md';

const ENGINE = 'scripts/dsh-restart.ps1';
const TOOLS = 'lib/tools.js';
const CONFIG = 'lib/config.js';
const RUNNER = 'lib/runner.js';
const PATHS = 'lib/paths.js';
const HOSTLIB = 'lib/host.js';
const LAUNCHER = 'lib/delayed-spawn.mjs';
const CLI = 'bin/dsh-restart-win.mjs';
const TASK_XML = 'scripts/dsh-restart.task.xml';
const CHECK_ENCODING = 'scripts/check-encoding.ps1';
const INSTALL = 'install.ps1';
const PACKAGE = 'package.json';
const CORDIS = 'cordis.patch.yml';
const CI = '.github/workflows/ci.yml';
const README = 'README.md';
const README_ZH = 'README.zh.md';
const MIGRATION = 'docs/migration.md';

// --------------------------------------------------------------------------
// File access
// --------------------------------------------------------------------------

const cache = new Map();

/** @param {string} relative @returns {string|null} file text without a BOM */
function read(relative) {
    if (cache.has(relative)) return cache.get(relative);
    let text = null;
    try {
        const bytes = readFileSync(join(ROOT, relative));
        const utf16le = bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe;
        text = (utf16le ? bytes.toString('utf16le') : bytes.toString('utf8')).replace(/^\uFEFF/, '');
    } catch {
        text = null;
    }
    cache.set(relative, text);
    return text;
}

/** @param {string} relative @returns {string} */
function mustRead(relative) {
    const text = read(relative);
    if (text === null) throw new Error(`${relative} does not exist`);
    return text;
}

/**
 * Body of one PowerShell function: from `function Name` up to the next line
 * that is exactly `}` at column 0. PowerShell functions in this engine are all
 * laid out that way.
 *
 * @param {string} text @param {string} name @returns {string|null}
 */
function functionBody(text, name) {
    const start = text.search(new RegExp(`^function\\s+${escapeRe(name)}\\b`, 'm'));
    if (start < 0) return null;
    const rest = text.slice(start);
    const end = rest.search(/\n\}/);
    return end < 0 ? rest : rest.slice(0, end + 2);
}

/** @param {string} value @returns {string} */
function escapeRe(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * @param {string} text @param {RegExp|string} pattern
 * @param {number} [limit]
 * @returns {number} number of matches (strings count as includes)
 */
function countMatches(text, pattern, limit = Infinity) {
    if (typeof pattern === 'string') {
        let count = 0;
        let index = text.indexOf(pattern);
        while (index >= 0 && count < limit) {
            count += 1;
            index = text.indexOf(pattern, index + pattern.length);
        }
        return count;
    }
    const flags = pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`;
    const re = new RegExp(pattern.source, flags);
    let count = 0;
    let match = re.exec(text);
    while (match && count < limit) {
        count += 1;
        if (match[0] === '') re.lastIndex += 1;
        match = re.exec(text);
    }
    return count;
}

// --------------------------------------------------------------------------
// Matrix parser
// --------------------------------------------------------------------------

/**
 * Split one markdown table line; `\|` is an escaped pipe inside a cell.
 * @param {string} line @returns {string[]}
 */
function splitRow(line) {
    const body = line.replace(/^\|/, '').replace(/\|\s*$/, '');
    const cells = [];
    let current = '';
    for (let index = 0; index < body.length; index += 1) {
        const character = body[index];
        if (character === '\\' && body[index + 1] === '|') {
            current += '\\|';
            index += 1;
            continue;
        }
        if (character === '|') {
            cells.push(current.trim());
            current = '';
            continue;
        }
        current += character;
    }
    cells.push(current.trim());
    return cells;
}

/**
 * @param {string} text
 * @returns {{ id: string, line: number, section: string, cells: string[] }[]}
 */
function parseMatrix(text) {
    const rows = [];
    let section = '';
    const lines = text.split(/\r?\n/);
    for (let index = 0; index < lines.length; index += 1) {
        const line = lines[index];
        const heading = /^##\s+(\d+(?:\.\d+)?)[.、]?\s*(.*)$/.exec(line);
        if (heading) {
            section = `${heading[1]} ${heading[2]}`.trim();
            continue;
        }
        const idMatch = /^\|\s*([A-Z]{1,2}-\d{2})\s*\|/.exec(line);
        if (!idMatch) continue;
        rows.push({ id: idMatch[1], line: index + 1, section, cells: splitRow(line) });
    }
    return rows;
}

// --------------------------------------------------------------------------
// Anchors
// --------------------------------------------------------------------------

const PATH_RE = /((?:scripts|lib|bin|test|docs)\/[A-Za-z0-9._/-]+|\.github\/workflows\/[A-Za-z0-9._-]+\.yml|package\.json|cordis\.patch\.yml|install\.ps1|README(?:\.zh)?\.md|LICENSE)/g;
const LOCAL_PATH_RE = /\.local\/[A-Za-z0-9._/-]+/g;
const SYMBOL_RE = /::([A-Za-z][A-Za-z0-9_-]*)/g;
const PARAM_RE = /@param\b/g;
const CONFIG_KEY_RE = /([A-Za-z0-9._/-]+)#([A-Za-z][A-Za-z0-9_]*)/g;

/**
 * Resolve one row's "插件目标位置" cell into concrete anchors.
 *
 * @param {{ id: string, line: number, cells: string[] }} row
 * @returns {{ kind: 'file'|'symbol'|'param'|'config'|'negative', value: string, file?: string }[]}
 */
function targetAnchors(row) {
    const cell = row.cells[3] ?? '';
    const anchors = [];
    if (/不带入/.test(cell)) {
        anchors.push({ kind: 'negative', value: cell });
        return anchors;
    }

    /** Remember which file the most recent `::symbol` / `@param` belongs to. */
    let currentFile = null;
    const scanner = /((?:scripts|lib|bin|test|docs)\/[A-Za-z0-9._/-]+|package\.json|cordis\.patch\.yml|install\.ps1|README(?:\.zh)?\.md|LICENSE)|::([A-Za-z][A-Za-z0-9_-]*)|@param\b|#([A-Za-z][A-Za-z0-9_]*)/g;
    let match = scanner.exec(cell);
    let sawAnything = false;
    while (match) {
        if (match[1]) {
            currentFile = match[1];
            anchors.push({ kind: 'file', value: currentFile });
            sawAnything = true;
        } else if (match[2]) {
            const symbol = match[2];
            if (!currentFile) throw new Error(`${row.id}: symbol ::${symbol} has no preceding file`);
            // `::stop 分支（main 内 …）` names a region of the top-level main
            // flow, not a function; the cell says so explicitly.
            const region = /分支/.test(cell.slice(match.index, match.index + 24)) && /main 内/.test(cell)
                ? 'main'
                : undefined;
            anchors.push({ kind: 'symbol', value: symbol, file: currentFile, region });
            sawAnything = true;
        } else if (match[0] === '@param') {
            if (!currentFile) throw new Error(`${row.id}: @param has no preceding file`);
            anchors.push({ kind: 'param', value: currentFile, file: currentFile });
            sawAnything = true;
        } else if (match[3]) {
            const key = match[3];
            if (!currentFile || !currentFile.endsWith('config.js')) {
                throw new Error(`${row.id}: config key #${key} must hang off lib/config.js (got ${currentFile ?? 'nothing'})`);
            }
            anchors.push({ kind: 'config', value: key, file: currentFile });
            sawAnything = true;
        }
        match = scanner.exec(cell);
    }
    if (!sawAnything) {
        // A target cell that names a file must resolve; a category description
        // ("test fixtures", "docs/*.md") is covered by the row's probes instead.
        const namesAFile = !/\*/.test(cell)
            && /^[A-Za-z0-9_-]+\.(?:ps1|js|mjs|json|yml|xml|md)\b|(?:^|[\s(（])(?:scripts|lib|bin|test|docs)\//.test(cell);
        if (namesAFile) throw new Error(`${row.id}: target cell names a file but has no resolvable anchor: ${cell}`);
        return [{ kind: 'prose', value: cell }];
    }
    return anchors;
}

/**
 * Check one anchor against the repository.
 * @param {{ kind: string, value: string, file?: string }} anchor
 * @returns {string|null} an error message, or null when satisfied
 */
function checkAnchor(anchor) {
    if (anchor.kind === 'file') {
        if (anchor.value.startsWith('.local/')) return null; // local evidence, checked separately
        if (!existsSync(join(ROOT, anchor.value))) return `anchor file does not exist: ${anchor.value}`;
        const stat = statSync(join(ROOT, anchor.value));
        if (!stat.isFile()) return `anchor path is not a file: ${anchor.value}`;
        return null;
    }
    if (anchor.kind === 'negative') return null; // absence is asserted by the row's probes
    if (anchor.kind === 'prose') return null; // category description; the probes do the work
    if (anchor.kind === 'config') {
        if (!CONFIG_KEYS.includes(anchor.value)) return `config key does not exist in lib/config.js: ${anchor.value}`;
        if (!Object.hasOwn(DEFAULTS, anchor.value)) return `config key has no default: ${anchor.value}`;
        return null;
    }
    const text = read(anchor.file);
    if (text === null) return `anchor file does not exist: ${anchor.file}`;
    if (anchor.kind === 'param') return null; // params come from the capability column, checked in runRow
    if (anchor.kind === 'symbol') {
        const symbol = anchor.value;
        if (anchor.file.endsWith('.ps1')) {
            if (symbol === 'main' || anchor.region === 'main') {
                // The engine's main flow is top-level script code, not a function;
                // the matrix uses `::main` for that block (see §2 F-01).
                return /^# =+ 主流程$/m.test(text) ? null : `${anchor.file} has no main-flow banner`;
            }
            return functionBody(text, symbol) === null ? `${anchor.file} has no function ${symbol}` : null;
        }
        if (symbol === 'main') return null;
        return new RegExp(`\\b${escapeRe(symbol)}\\b`).test(text) ? null : `${anchor.file} never mentions ${symbol}`;
    }
    return `unknown anchor kind ${anchor.kind}`;
}

/**
 * Every `[switch]$Name` / `[string]$Name` / `[int]$Name` declared in the row's
 * capability cell must exist in the engine param block.
 *
 * @param {{ id: string, cells: string[] }} row
 * @returns {string[]} missing parameter names
 */
function declaredParams(row) {
    const capability = row.cells[1] ?? '';
    const names = [...capability.matchAll(/\[(?:switch|string|int)\]\$([A-Za-z][A-Za-z0-9_]*)/g)].map((match) => match[1]);
    return [...new Set(names)];
}

/** @param {string} text @returns {string} the `param( … )` block */
function paramBlock(text) {
    const start = text.search(/^param\(/m);
    if (start < 0) return '';
    const end = text.indexOf('\n)', start);
    return end < 0 ? text.slice(start) : text.slice(start, end);
}

// --------------------------------------------------------------------------
// Privacy scanner
//
// The detection capability belongs in source; machine identifiers do not.
// Everything below is either a *shape* (a format any machine can produce) or a
// value read at runtime — never a literal user name, host name or workspace
// path (CONTRACT §6: those must not appear in a tracked file, scanners
// included). Findings report `file:line: category` and never the matched text.
// --------------------------------------------------------------------------

/** Shapes that identify a machine regardless of which machine it is. */
const LEAK_SHAPES = [
    // A profile path with a concrete name. `<user>`, `%USERNAME%` and `{user}`
    // are placeholders, not machines; `PLACEHOLDER_NAMES` filters them.
    { category: 'windows-user-profile', re: /C:\\Users\\[^\\\s"%|<>]+/g },
    { category: 'posix-home', re: /\/home\/[^/\s"'`]+/g },
    { category: 'github-token', re: /gh[pousr]_[A-Za-z0-9]{20,}/g },
    { category: 'api-key', re: /sk-[A-Za-z0-9]{16,}/g },
    { category: 'bearer-token', re: /Bearer\s+[A-Za-z0-9._-]{20,}/g },
    // A drive-letter path with three space-free literal segments is a real
    // installation location. `%VAR%`-based paths never match, and a segment
    // with a space (e.g. the standard program-files directory) is generic.
    { category: 'absolute-path', re: /[A-Za-z]:\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_.-]+\\[^%\s"']/g },
];

/** Words that stand in for a name in documentation rather than naming a machine. */
const PLACEHOLDER_NAMES = /^(?:<[^>]*>|\{[^}]*\}|%[A-Za-z_]+%|user|username|example|sample|someone|yourname|本机用户名)$/i;

/** Terms supplied by a local, gitignored file (never part of the package). */
const REDACTION_TERMS_FILE = '.local/audit/redaction-terms.txt';

/**
 * Build the machine-identifier list for this run.
 *
 * Order: the curated local term list when it exists (local runs), then values
 * derived from the environment (CI, another machine). Nothing is written back.
 *
 * @param {{ root?: string, env?: Record<string, string | undefined> }} [options]
 * @returns {{ terms: string[], shapes: {category: string, re: RegExp}[], allow: string[], source: string }}
 */
function loadRedactionTerms(options = {}) {
    const root = options.root ?? ROOT;
    const env = options.env ?? process.env;
    const terms = new Set();
    const allow = new Set();
    const shapes = [...LEAK_SHAPES];
    let source = 'environment';

    const text = read(REDACTION_TERMS_FILE);
    if (text !== null) {
        source = REDACTION_TERMS_FILE;
        for (const raw of text.split(/\r?\n/)) {
            const line = raw.trim();
            if (line === '' || line.startsWith('#')) continue;
            if (line.startsWith('ALLOW:')) {
                allow.add(line.slice('ALLOW:'.length));
                continue;
            }
            if (line.startsWith('REGEX:')) {
                try {
                    shapes.push({ category: 'local-term-regex', re: new RegExp(line.slice('REGEX:'.length), 'g') });
                } catch {
                    // A malformed local pattern must not break the run.
                }
                continue;
            }
            if (line.length >= 4) terms.add(line);
        }
    }

    // Values derived from the environment (CI, another machine). Only whole
    // paths and the user/host names are added: a path segment like `Local` or
    // `tools` is an ordinary word and would turn every scan into noise.
    const candidates = [];
    const profile = typeof env.USERPROFILE === 'string' ? env.USERPROFILE.trim() : '';
    if (profile !== '') {
        candidates.push(profile);
        const base = profile.split(/[\\/]/).filter(Boolean).pop();
        if (base) candidates.push(base);
    }
    for (const key of ['USERNAME', 'COMPUTERNAME', 'DSH_HOME', 'LOCALAPPDATA']) {
        const value = typeof env[key] === 'string' ? env[key].trim() : '';
        if (value !== '') candidates.push(value);
    }
    // Ancestor directories of the package root, as whole paths: catches a
    // hardcoded workspace path without naming any segment here.
    let directory = root.replace(/[\\/]+$/, '');
    for (let depth = 0; depth < 3; depth += 1) {
        const parent = dirname(directory);
        if (!parent || parent === directory) break;
        directory = parent;
        candidates.push(directory);
    }
    for (const value of candidates) {
        if (value.length >= 4) terms.add(value);
    }

    return {
        terms: [...terms].filter((term) => term.length >= 4),
        shapes,
        allow: [...allow],
        source,
    };
}

/** A drive-letter path with at least one segment: `C:\name\`. */
const DRIVE_PATH_RE = /[A-Za-z]:\\[A-Za-z0-9_.-]+\\/;
const PLACEHOLDER_UUID = ['00000000', '0000', '0000', '0000', '000000000000'].join('-');

/**
 * Scan text for privacy leaks. Returns categories only.
 *
 * @param {string} text
 * @param {ReturnType<typeof loadRedactionTerms>} terms
 * @returns {{ category: string, line: number }[]}
 */
function scanForLeaks(text, terms) {
    const hits = [];
    const lineAt = (index) => text.slice(0, index).split('\n').length;
    const lower = text.toLowerCase();
    for (const term of terms.terms) {
        let from = 0;
        const needle = term.toLowerCase();
        while (true) {
            const at = lower.indexOf(needle, from);
            if (at < 0) break;
            from = at + needle.length;
            const matched = text.slice(at, at + term.length);
            if (terms.allow.some((allowed) => matched.includes(allowed))) continue;
            hits.push({ category: 'machine-term', line: lineAt(at) });
        }
    }
    for (const shape of terms.shapes) {
        const re = new RegExp(shape.re.source, shape.re.flags.includes('g') ? shape.re.flags : `${shape.re.flags}g`);
        let match = re.exec(text);
        while (match) {
            const allowed = terms.allow.some((value) => match[0].includes(value));
            const placeholder = shape.category === 'windows-user-profile'
                && PLACEHOLDER_NAMES.test(match[0].slice('C:\\Users\\'.length));
            const documentedFixture = match[0].toLowerCase() === PLACEHOLDER_UUID;
            if (!allowed && !placeholder && !documentedFixture) hits.push({ category: shape.category, line: lineAt(match.index) });
            if (match[0] === '') re.lastIndex += 1;
            match = re.exec(text);
        }
    }
    return hits;
}

/**
 * @param {string} file @param {ReturnType<typeof loadRedactionTerms>} terms
 * @returns {{ file: string, line: number, category: string }[]}
 */
function scanFileHits(file, terms) {
    const text = read(file);
    if (text === null) return [];
    return scanForLeaks(text, terms).map((hit) => ({ file, line: hit.line, category: hit.category }));
}

/**
 * @param {string} file @param {ReturnType<typeof loadRedactionTerms>} terms
 * @returns {string[]} `file:line: hit category` messages (never the matched text)
 */
function scanFile(file, terms) {
    return scanFileHits(file, terms).map((hit) => `${hit.file}:${hit.line}: hit ${hit.category}`);
}

/** Cached term set for the probe table. */
let cachedTerms = null;
function redactionTerms() {
    cachedTerms ??= loadRedactionTerms();
    return cachedTerms;
}

// --------------------------------------------------------------------------
// Probe helpers
// --------------------------------------------------------------------------

/** @param {RegExp|string} pattern @param {object} [options] */
const eng = (pattern, options = {}) => ({ file: ENGINE, has: pattern, ...options });
/** @param {RegExp|string} pattern @param {object} [options] */
const tls = (pattern, options = {}) => ({ file: TOOLS, has: pattern, ...options });
/** @param {RegExp|string} pattern @param {object} [options] */
const cfg = (pattern, options = {}) => ({ file: CONFIG, has: pattern, ...options });
/** @param {RegExp|string} pattern @param {object} [options] */
const run = (pattern, options = {}) => ({ file: RUNNER, has: pattern, ...options });
/** @param {RegExp|string} pattern @param {object} [options] */
const pth = (pattern, options = {}) => ({ file: PATHS, has: pattern, ...options });
/** @param {RegExp|string} pattern @param {object} [options] */
const xml = (pattern, options = {}) => ({ file: TASK_XML, has: pattern, ...options });
/** @param {RegExp|string} pattern @param {object} [options] */
const chk = (pattern, options = {}) => ({ file: CHECK_ENCODING, has: pattern, ...options });

/**
 * One probe.
 *
 *   has / lacks      regex or literal; `count` bounds the number of matches
 *   inFunction       restrict the search to one PowerShell function body
 *   before           [a, b] — first match of `a` must precede the first `b`
 *   fn               custom check `(ctx) => void`; throw to fail
 *   note             why this probe exists (quoted from the matrix)
 */
const PROBES = {
    // ---------------------------------------------------------------- §1 params
    'P-01': [eng(/\$Profile/g, { min: 2, note: 'profile is consumed, not just declared' }), eng(/--profile \$Profile/)],
    'P-02': [{ file: ENGINE, inFunction: 'Get-MutexName', has: /Local\\dsh-restart-p' \+ \$Port/, note: 'mutex name is port-derived' }],
    'P-03': [
        eng(/http:\/\/\$\{BindHost\}:\$Port\/|http:\/\/\$\{BindHost\}:\$P\//, { note: 'probe URL is built from $BindHost' }),
        {
            note: 'CONTRACT §3.8 / U-04: -BindHost only affects probes, never the launch command',
            fn: (ctx) => {
                const text = ctx.text(ENGINE);
                const line = /DEFAULT_LAUNCH\['args'\]\s*=\s*(.+)$/m.exec(text);
                assert.ok(line, 'DEFAULT_LAUNCH args line not found');
                assert.ok(!/\$BindHost/.test(line[1]), `DEFAULT_LAUNCH args consume $BindHost: ${line[1].trim()}`);
                assert.ok(/--host 127\.0\.0\.1/.test(line[1]), `DEFAULT_LAUNCH must keep the literal loopback host: ${line[1].trim()}`);
                const record = /else \{ 'pnpm dsh web --no-open --host (.+?) --port \{PORT\}' \}/.exec(text);
                assert.ok(record, 'record default command not found');
                assert.ok(!/\$BindHost/.test(record[1]), `-Record default command consumes $BindHost: ${record[1]}`);
                assert.ok(/127\.0\.0\.1/.test(record[1]), `-Record default command must keep the literal loopback host: ${record[1]}`);
            },
        },
    ],
    'P-04': [eng(/\$env:DSH_HOME\).*Join-Path \$env:USERPROFILE '\.dsh'/)],
    'P-05': [eng(/\$env:DSH_RESTART_HOME\).*Join-Path \$env:LOCALAPPDATA 'dsh-restart'/)],
    'P-06': [eng(/Wait-HostReady \$[^\n]*\$ReadySec/, { count: 2, note: 'both readiness call sites are budgeted by -ReadySec' })],
    'P-07': [eng(/AddSeconds\(\$VerifyReadySec\)/)],
    'P-08': [eng(/Stop-DshInstance \$script:TargetPid \$GraceSec/, { count: 2 })],
    'P-09': [eng(/Wait-PortFree \$Port \$PortFreeSec/, { count: 2 })],
    'P-10': [eng(/if \(\$WaitIdleSec -gt 0\) \{ \[void\]\(Wait-SessionIdle/)],
    'P-11': [eng(/\[Math\]::Min\(\$WaitIdleSec, \$IdleMaxSec\)/)],
    'P-12': [eng(/if \(\$Status\) \{ Show-Status; Write-Terminal 'status' 0; exit 0 \}/), tls(/win_restart_status/)],
    'P-13': [
        eng(/Add-Step 'dry-run'/, { min: 2 }),
        eng(/if \(\$DryRun\) \{/, { min: 2, note: '-Stop -DryRun and the main dry-run branch' }),
    ],
    'P-14': [eng(/if \(-not \$Start\) \{/, { min: 2, note: 'dump-config and the pending notice are skipped by -Start' })],
    'P-15': [
        eng(/if \(\$Stop\) \{[\s\S]{0,4000}Write-Terminal 'stopped' 0/),
        {
            note: 'the -Stop path returns before any launch or pending notice',
            fn: (ctx) => {
                const text = ctx.text(ENGINE);
                const stopBlock = text.indexOf('if ($Stop) {');
                const notice = text.indexOf('Write-PendingNotice $sid $Reason');
                assert.ok(stopBlock > 0 && notice > stopBlock, '-Stop must be handled before the notice is written');
            },
        },
    ],
    'P-16': [
        eng(/\[Console\]::Out\.WriteLine\(\$jsonText\)/, { count: 1, note: 'the only stdout write' }),
        eng(/Write-EngineResult$/m, { count: 1, note: 'one JSON exit for every terminal path' }),
        eng(/Write-Output/, { count: 0, note: 'no Write-Output may pollute stdout' }),
    ],
    'P-17': [eng(/if \(\$Fast\) \{/)],
    'P-18': [eng(/if \(\$script:TargetPid -and -not \$ForceUnverified\)/), eng(/-ForceUnverified：已显式承担/)],
    'P-19': [eng(/if \(\$VerifyOnly -or \$Preflight\) \{/)],
    'P-20': [eng(/if \(\$VerifyOnly -or \$Preflight\) \{/, { count: 1, note: 'single shared branch — no invented difference' })],
    'P-21': [eng(/if \(\$VerifyTempRoot\) \{ \$VerifyTempRoot \} else \{ \$env:TEMP \}/)],
    'P-22': [eng(/\$env:DSH_SESSION_ID\) \{ \$env:DSH_SESSION_ID \} else \{ '' \}/)],
    'P-23': [eng(/reason\s*=\s*\$Why/)],
    'P-24': [eng(/if \(\$Record\) \{/)],
    'P-25': [eng(/--host 127\.0\.0\.1 --port \{PORT\}'/, { note: 'the recorded command keeps the {PORT} placeholder' })],
    'P-26': [eng(/if \(\$RecordWorkingDirectory\) \{ \$RecordWorkingDirectory \} else \{ \(Get-Location\)\.Path \}/)],
    'P-27': [eng(/if \(\$TryCtrlC\) \{/, { count: 2 })],
    'P-28': [eng(/if \(\$ViaTask\) \{[\s\S]{0,600}exit 0/)],
    'P-29': [eng(/\[switch\]\$ViaTaskInner/), xml(/-ViaTaskInner/)],
    // 系统工具改为绝对路径解析（Get-SystemTool）：断言的是「解析到的 schtasks 收到同一组参数」
    'P-30': [eng(/\$o = & \(Get-SystemTool 'schtasks'\) \/Create \/TN \$TaskName \/XML \$path \/F/)],
    'P-31': [eng(/\(Get-SystemTool 'schtasks'\) \/Delete \/TN \$TaskName \/F/)],
    'P-32': [eng(/\$TaskName/g, { min: 6 })],
    'P-33': [eng(/\$DoNotTouchDshHome/g, { count: 1, note: 'declared only — the frozen contract forbids giving it semantics' })],
    'P-34': [eng(/#Requires -Version 5\.1/), eng(/\$ErrorActionPreference = 'Stop'/), eng(/Set-StrictMode -Version 2\.0/)],
    'P-35': [
        eng(/\$script:VERSION\s*=\s*/, { note: 'P-35/M-05: one version source' }),
        eng(/package\.json/, { note: 'the engine reads package.json for its version' }),
        {
            note: 'a missing package.json degrades to a dev fallback instead of breaking the engine',
            fn: (ctx) => {
                const text = ctx.text(ENGINE);
                const assignment = /^.*\$script:VERSION\s*=.*$/m.exec(text);
                assert.ok(assignment, 'VERSION assignment not found');
                const nearby = text.slice(Math.max(0, assignment.index - 400), assignment.index + 400);
                assert.ok(/package\.json/.test(nearby), 'the VERSION assignment does not mention package.json');
                assert.ok(/0\.0\.0-dev|catch/.test(nearby), 'a missing or unreadable package.json must fall back, not throw');
            },
        },
    ],
    'P-36': [eng(/\$MyInvocation\.InvocationName -eq '\.'/)],
};

// ------------------------------------------------------------------ §2 main flow
PROBES['F-01'] = [{
    note: 'action dispatch order is the semantics: short paths return before anything touches an instance',
    fn: (ctx) => {
        // The main flow is top-level code after the banner; function definitions
        // above it must not be mistaken for dispatch order.
        const banner = ctx.text(ENGINE).search(/^# =+ 主流程$/m);
        assert.ok(banner > 0, 'main-flow banner not found');
        const text = ctx.text(ENGINE).slice(banner);
        const order = [
            'if ($UnregisterTask) {',
            'if ($RegisterTask) {',
            'if ($ViaTask) {',
            'if ($Record) {',
            'if (-not (Enter-RestartLock)) {',
            'if ($needsDeepVerify) {',
            'if ($Status) { Show-Status',
            'if ($VerifyOnly -or $Preflight) {',
            '$instances = @(Get-DshInstances)',
        ];
        let previous = -1;
        for (const marker of order) {
            const at = text.indexOf(marker);
            assert.ok(at >= 0, `dispatch marker missing: ${marker}`);
            assert.ok(at > previous, `dispatch marker out of order: ${marker}`);
            previous = at;
        }
    },
}];
PROBES['F-02'] = [{ file: ENGINE, inFunction: 'Enter-RestartLock', has: /System\.Threading\.Mutex|Get-MutexName/ }];
PROBES['F-03'] = [eng(/finally \{[\s\S]{0,400}Exit-RestartLock/)];
PROBES['F-04'] = [
    { file: ENGINE, inFunction: 'Get-Ps7RuntimeStatus', has: /PSVersion\.Major -ge 7/ },
    { file: ENGINE, inFunction: 'Get-Ps7RuntimeStatus', has: /hasEnvironment/ },
    eng(/engine-requires-pwsh/),
];
PROBES['F-05'] = [eng(/\(-not \$Status\) -and \(-not \$Stop\) -and \(-not \$Start\) -and \(-not \$Fast\) -and \(-not \$DryRun\)/)];
PROBES['F-06'] = [eng(/\$instances = @\(Get-DshInstances\)/, { note: '@() keeps a single instance from being unwrapped' })];
PROBES['F-07'] = [eng(/\$symOk = Test-SymlinkPrivilege/), eng(/\$dv = Invoke-DeepVerifyWithRetry/), eng(/\$symOk = Test-SymlinkPrivilege[\s\S]*\$dv = Invoke-DeepVerifyWithRetry/, { note: 'symlink preflight runs before the 60s deep verification' })];
PROBES['F-08'] = [eng(/instances\.Count -ge 1/), eng(/\$script:TargetPid = \$instances\[0\]\.pid/)];
PROBES['F-09'] = [eng(/-Stop 与 -Start 互斥/), eng(/if \(\$Stop\) \{[\s\S]{0,200}if \(\$Start\) \{/)];
PROBES['F-10'] = [eng(/不拉起、不写续跑通知/)];
PROBES['F-11'] = [eng(/端口 \$Port 无监听者，无需停机/)];
PROBES['F-12'] = [eng(/if \(-not \$instances\[0\]\.isNode\)/), eng(/stop-refused' 12/)];
PROBES['F-13'] = [eng(/= Test-ConfigOperationGate/g, { count: 2, note: '-Stop path and the main restart path' })];
PROBES['F-14'] = [eng(/if \(-not \(Test-HostAlive \$script:TargetPid \$Port\)\)/, { count: 2 })];
PROBES['F-15'] = [
    eng(/Stop-DshInstance \$script:TargetPid \$GraceSec/, { count: 2 }),
    eng(/Wait-PortFree \$Port \$PortFreeSec/, { count: 2 }),
];
PROBES['F-16'] = [eng(/\$dumpOk = \$null/), eng(/\$dumpOk = \$false/), eng(/\$dumpOk = \$true/), eng(/if \(\$dumpOk -eq \$false\)/)];
PROBES['F-17'] = [eng(/Test-StopPermission \$permPid/), eng(/Test-StopPermission \$permPid[\s\S]*Invoke-DeepVerifyWithRetry/, { note: 'elevation gate before the 60s deep verification (desktop: main pid)' })];
PROBES['F-18'] = [eng(/if \(-not \$dv\) \{ Add-Step 'deep-verify' '验证被跳过（找不到 dsh 本体）' 'warn' \}/)];
PROBES['F-19'] = [eng(/Write-Terminal 'verify-required' 10/)];
PROBES['F-20'] = [eng(/\$envPlan = Get-RegistryEnvironmentBlock/), eng(/-DryRun 不做副作用/)];
PROBES['F-21'] = [eng(/Test-LaunchPrereq \$launch\.raw \$launch\.cwd/), eng(/Test-LaunchPrereq[\s\S]*Stop-DshInstance \$script:TargetPid \$GraceSec/, { note: 'launch prerequisites are checked before the host is stopped' })];
PROBES['F-22'] = [eng(/= Test-ConfigOperationGate[\s\S]*Stop-DshInstance \$script:TargetPid \$GraceSec/)];
PROBES['F-23'] = [eng(/if \(\$WaitIdleSec -gt 0\) \{ \[void\]\(Wait-SessionIdle/)];
PROBES['F-24'] = [eng(/Write-PendingNotice \$sid \$Reason[\s\S]*Stop-DshInstance \$script:TargetPid \$GraceSec/, { note: 'notice is written before the host is stopped' })];
PROBES['F-25'] = [eng(/Write-Terminal 'stop-failed' 6/g, { min: 3 })];
PROBES['F-26'] = [eng(/if \(\$script:TargetPid\) \{ \$script:StoppedPid = \$script:TargetPid \}/)];
PROBES['F-27'] = [
    { file: ENGINE, inFunction: 'Remove-OrphanDshChildren', has: /deepseek-ai\|codegraph/ },
    { file: ENGINE, inFunction: 'Remove-OrphanDshChildren', has: /Get-Process -Id \$ppid/, note: 'a live parent means the process is not an orphan' },
];
PROBES['F-28'] = [
    { file: ENGINE, inFunction: 'Wait-PortFree', has: /Test-PortBindable/ },
    eng(/if \(-not \(Wait-PortFree \$Port \$PortFreeSec\)\) \{[\s\S]{0,300}Write-Terminal 'port-busy' 7/),
];
PROBES['F-29'] = [
    eng(/DSH_UC_PROFILE_NODE_MODULES = \$vNm/),
    eng(/NPM_CONFIG_LEGACY_PEER_DEPS/),
    eng(/UTF8Encoding\(\$false\)/),
];
PROBES['F-30'] = [{ file: ENGINE, inFunction: 'Wait-HostReady', has: /Get-PortOwner \$P/ }, { file: ENGINE, inFunction: 'Wait-HostReady', has: /\$hop -lt 6/ }];
PROBES['F-31'] = [eng(/\$killPids \+= \$script:NewPid/), eng(/proc\.Id -ne \$script:NewPid/), eng(/Add-Step 'abort-cleanup'/)];
PROBES['F-32'] = [{ file: ENGINE, inFunction: 'Get-ResidualChildren', lacks: /taskkill/, note: 'residual children are reported, never killed' }];
PROBES['F-33'] = [eng(/Add-Step 'client-plugin'/)];
PROBES['F-34'] = [eng(/Wait-NewHostToken\(\[string\]\$LogPath, \[int\]\$MaxWaitMs = 20000\)/), eng(/20s 内未等到新的 boot token/)];
PROBES['F-35'] = [eng(/Write-Terminal 'restarted-ok' 0/)];
PROBES['F-36'] = [eng(/\} catch \{/), eng(/Invoke-RescueLaunch \$fatal/), eng(/Write-Terminal \("aborted:" \+ \$fatal\) 1/)];
PROBES['F-37'] = [eng(/finally \{[\s\S]{0,400}Exit-RestartLock/)];
PROBES['F-38'] = [eng(/Add-Step\(\[string\]\$name, \[string\]\$detail, \[string\]\$state = 'ok'\)/), eng(/\[\{0\}\] \{1,-18\} \{2\}/)];
PROBES['F-39'] = [eng(/function Write-Audit\(\[string\]\$level, \[string\]\$message\)/), eng(/\[void\]\$script:Audit\.Add/)];
PROBES['F-40'] = [
    { file: ENGINE, inFunction: 'Write-Terminal', has: /\[ordered\]@\{/ },
    { file: ENGINE, inFunction: 'Write-Terminal', has: /restart-history\.jsonl/ },
    { file: ENGINE, inFunction: 'Write-Terminal', has: /dsh-restart\.log/ },
    { file: ENGINE, inFunction: 'Write-Terminal', lacks: /Write-Host|Write-Diag/, note: 'never writes a second JSON document to stdout' },
];
PROBES['F-41'] = [{ file: ENGINE, inFunction: 'New-Utf8NoBom', has: /UTF8Encoding\(\$false\)/ }];
PROBES['F-42'] = [eng(/Select-Object -Last 12/), eng(/'ERROR\|Error:\|error:\|failed\|exit code'/)];
PROBES['F-43'] = [{ file: ENGINE, inFunction: 'Format-KillOutput', has: /Access is denied\|拒绝访问/ }, { file: ENGINE, inFunction: 'Format-KillOutput', has: /terminated forcefully/ }];
PROBES['F-44'] = [eng(/\[System\.IO\.File\]::AppendAllText\(\$f, \$banner, \(New-Object System\.Text\.UTF8Encoding\(\$false\)\)\)/)];
PROBES['F-45'] = [eng(/\$script:PrevBootToken = ''/), eng(/\$script:LogOffsetBeforeLaunch = 0/), eng(/\$script:PrevBootToken = ''[\s\S]*Start-Process -FilePath \$launch\.file/)];
PROBES['F-46'] = [{ file: ENGINE, inFunction: 'Start-DshInstance', has: /\$env:USERPROFILE/ }];
PROBES['F-47'] = [eng(/if \(\$env:DSH_RESTART_DEBUG\) \{/g, { count: 2 })];
PROBES['F-48'] = [eng(/Add-Step 'lock'/), eng(/Add-Step 'discover'/), eng(/Add-Step 'launch'/), eng(/Add-Step 'ready'/), eng(/Add-Step 'url'/)];

// ------------------------------------------------------------------ §3 exit codes
PROBES['MF-01'] = [eng(/Write-Terminal 'restarted-ok' 0/)];
PROBES['MF-02'] = [eng(/Write-Terminal 'status' 0/)];
PROBES['MF-03'] = [eng(/Write-Terminal 'verify-only-ok' 0/)];
PROBES['MF-04'] = [eng(/Write-Terminal 'dry-run' 0/g, { count: 2 })];
PROBES['MF-05'] = [eng(/Write-Terminal 'stopped' 0/g, { count: 2 })];
PROBES['MF-06'] = [eng(/'task-registered' \} else \{ 'task-register-failed' \}\) \$\(if \(\$ok\) \{ 0 \} else \{ 1 \}\)/)];
PROBES['MF-07'] = [eng(/Write-Terminal 'task-unregistered' \$\(if \(\$LASTEXITCODE -eq 0\) \{ 0 \} else \{ 1 \}\)/)];
PROBES['MF-08'] = [eng(/Write-Terminal 'via-task-dispatched' 0/)];
PROBES['MF-09'] = [eng(/Write-Terminal 'recorded' 0/)];
PROBES['X-10'] = [eng(/Write-Terminal \("rescued-after-abort:" \+ \$fatal\) 0/), eng(/if \(\$script:HostUrl\) \{ \[void\]\(Save-WebAuthUrlRecord/)];
PROBES['X-11'] = [eng(/Write-Terminal \("aborted:" \+ \$fatal\) 1/)];
PROBES['X-12'] = [eng(/'task-registered' \} else \{ 'task-register-failed' \}\)/)];
PROBES['X-13'] = [eng(/Write-Terminal 'locked' 2/)];
PROBES['X-14'] = [eng(/Write-Terminal 'engine-requires-pwsh' 2/)];
PROBES['X-15'] = [eng(/Write-Terminal 'invalid-args' 2/g, { min: 2 })];
PROBES['X-16'] = [eng(/Write-Terminal 'config-invalid' 3; exit 3/)];
PROBES['X-17'] = [eng(/Write-Terminal 'verify-only-failed' 4/)];
PROBES['X-18'] = [eng(/Write-Terminal 'verify-failed' 4/)];
PROBES['X-19'] = [eng(/Write-Terminal 'gate-blocked' 5/g, { count: 2 })];
PROBES['X-20'] = [eng(/Write-Terminal 'stop-failed' 6/g, { count: 3 })];
PROBES['X-21'] = [eng(/Write-Terminal 'port-busy' 7/g, { count: 2 })];
PROBES['X-22'] = [
    eng(/Write-Terminal \('ready-failed:' \+ \$ready\.reason\) 8/),
    eng(/reason = 'port-owner-mismatch'/),
    eng(/reason = 'exited'/),
    eng(/reason = 'timeout'/),
];
PROBES['X-23'] = [eng(/Write-Terminal 'via-task-failed' 9/)];
PROBES['X-24'] = [eng(/Write-Terminal 'verify-required' 10/)];
PROBES['X-25'] = [eng(/Write-Terminal 'launch-prereq-failed' 11/)];
PROBES['X-26'] = [eng(/Write-Terminal 'stop-refused' 12/)];

// ------------------------------------------------------------------ §4 state files
PROBES['S-01'] = [{
    note: 'boot-record.json schema: 8 keys, replayed verbatim',
    ...{ file: ENGINE, inFunction: 'Save-BootRecord', has: /\[ordered\]@\{/ },
}];
PROBES['S-01'].push({ file: ENGINE, inFunction: 'Save-BootRecord', fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'Save-BootRecord');
    for (const key of ['recordedAt', 'command', 'cwd', 'profile', 'port', 'host', 'dshHome', 'note']) {
        assert.ok(new RegExp(`^\\s+${key}\\s+=`, 'm').test(body), `boot-record key missing: ${key}`);
    }
    assert.ok(/ConvertTo-Json -Depth 5/.test(ctx.text(ENGINE)), 'boot record is serialized with -Depth 5');
} });
PROBES['S-02'] = [eng(/Join-Path \$DshHome '\.smart-restart'/), eng(/sessionId = \$SessionId; reason = \$Why; when = Get-NowIso/)];
PROBES['S-03'] = [{
    note: 'restart-history.jsonl: 16 fixed keys (external consumers parse them)',
    fn: (ctx) => {
        const body = ctx.functionBody(ENGINE, 'Write-Terminal');
        const keys = ['ts', 'version', 'result', 'rc', 'profile', 'port', 'target_pid', 'new_pid', 'url', 'session', 'reason', 'host', 'user', 'steps', 'warnings', 'audit'];
        for (const key of keys) assert.ok(new RegExp(`^\\s+${key}\\s+=`, 'm').test(body), `history key missing: ${key}`);
        assert.ok(/host\s+= \$env:COMPUTERNAME/.test(body), 'host key records the machine name');
    },
}];
PROBES['S-04'] = [eng(/\{0\} \[dsh-restart\] 终态 result=\{1\} rc=\{2\} 旧pid=\{3\} 新pid=\{4\} profile=\{5\} port=\{6\} session=\{7\}/)];
PROBES['S-05'] = [{
    note: 'web-auth-url.txt: 7 keys, source records how the URL was obtained',
    fn: (ctx) => {
        const body = ctx.functionBody(ENGINE, 'Save-WebAuthUrlRecord');
        for (const key of ['url', 'token', 'pid', 'port', 'profile', 'savedAt', 'source']) {
            assert.ok(new RegExp(`^\\s+${key}\\s+=`, 'm').test(body), `web-auth-url key missing: ${key}`);
        }
        const text = ctx.text(ENGINE);
        assert.ok(/url 步（token 变化判据）/.test(text), 'source value for the launch step');
        assert.ok(/rescue 步（token 变化判据）/.test(text), 'source value for the rescue step');
        assert.ok(/\(Get-HostLogName 'out'\) \+ '（-Status 校验后补写）'/.test(text), 'source value for the -Status refresh (names the per-kind log it actually read)');
    },
}];
PROBES['S-06'] = [
    eng(/function Get-HostLogName/),
    eng(/host\.\{0\}\.\{1\}\.log/),
    eng(/Get-HostLogName 'out'/),
    eng(/Get-HostLogName 'err'/),
];
PROBES['S-07'] = [eng(/UnicodeEncoding\(\$false, \$true\)/), eng(/function Get-TaskXmlPath/), eng(/'dsh-restart\.task\.xml'/)];
PROBES['S-08'] = [eng(/Join-Path \(Get-StatePath 'fallback'\) 'dsh-restart\.log'/), eng(/Join-Path \(Get-StatePath 'fallback'\) 'restart-history\.jsonl'/), eng(/break/g, { min: 2 })];
PROBES['S-09'] = [eng(/"dsh-verify\." \+ \[guid\]::NewGuid/), eng(/KeepDir/)];
PROBES['S-10'] = [eng(/\$dir = Join-Path \$StateDir 'symlink-probe'/), { file: ENGINE, inFunction: 'Test-SymlinkPrivilege', has: /finally/ }];
PROBES['S-11'] = [eng(/marker\.json/), eng(/marker\s+= \$\(try \{ Get-Content/)];
PROBES['S-12'] = [{
    note: 'SAFE MODE cleanup is an operations product, not engine behavior — it must not be carried into the repo',
    ...{ file: ENGINE },
    fn: (ctx) => {
        assert.ok(!existsSync(join(ROOT, 'safe-mode-cleanup')), 'safe-mode-cleanup/ must not exist in the repo');
        assert.ok(!/safe-mode-cleanup/.test(ctx.text(ENGINE)), 'the engine must not write a safe-mode-cleanup directory');
    },
}];
PROBES['S-13'] = [{
    note: '_bak/ version archives are replaced by git history',
    ...{ file: ENGINE },
    fn: () => assert.ok(!existsSync(join(ROOT, '_bak')), '_bak/ must not be carried into the repo'),
}];
PROBES['S-14'] = [{
    note: 'the engine neither reads nor writes hermes-restart-*.log',
    ...{ file: ENGINE },
    fn: (ctx) => assert.equal(countMatches(ctx.text(ENGINE), /hermes/i), 0, 'the engine must not mention hermes'),
}];

// ------------------------------------------------------------------ §5 fail-closed gates
PROBES['G-01'] = [{ file: ENGINE, inFunction: 'Enter-RestartLock', has: /WaitOne\(0\)/, note: 'no queueing, no retry' }];
PROBES['G-02'] = [{ file: ENGINE, inFunction: 'Get-Ps7RuntimeStatus', has: /PSVersion\.Major -ge 7/ }, { file: ENGINE, inFunction: 'Get-Ps7RuntimeStatus', has: /Start-Process -Environment|hasEnvironment/ }];
PROBES['G-03'] = [eng(/Add-Step 'symlink-preflight'/), eng(/开发者模式/), eng(/管理员/)];
PROBES['G-04'] = [{ file: ENGINE, inFunction: 'Test-SymlinkPrivilege', has: /\$ok = \$true/, note: 'a failing probe must not block; the deep verification gives the real verdict' }];
PROBES['G-05'] = [eng(/CanQueryTargetToken/), eng(/已跳过深度验证/)];
PROBES['G-06'] = [eng(/if \(\$script:TargetPid -and -not \$ForceUnverified\) \{/)];
PROBES['G-07'] = [{ file: ENGINE, inFunction: 'Test-LaunchPrereq', has: /cmd\(\\\.exe\)\?\|powershell\(\\\.exe\)\?\|pwsh\(\\\.exe\)\?/ }];
PROBES['G-08'] = [{ file: ENGINE, inFunction: 'Test-LaunchPrereq', has: /package\.json/ }, { file: ENGINE, inFunction: 'Test-LaunchPrereq', has: /localScript/ }];
PROBES['G-09'] = [{ file: ENGINE, inFunction: 'Test-ConfigOperationGate', has: /\.transaction/ }, { file: ENGINE, inFunction: 'Test-ConfigOperationGate', has: /RECOVERY_REQUIRED/ }];
PROBES['G-10'] = [{ file: ENGINE, inFunction: 'Get-StaleEnvLockAdvice', has: /30/ }, { file: ENGINE, inFunction: 'Get-StaleEnvLockAdvice', has: /return \$null/, note: 'any uncertainty returns null instead of guessing' }];
PROBES['G-11'] = [eng(/Write-Terminal 'port-busy' 7/)];
PROBES['G-12'] = [eng(/Add-Step 'abort-cleanup'[\s\S]{0,600}Write-Terminal \('ready-failed:'/)];
PROBES['G-13'] = [eng(/if \(\$script:StoppedPid -and -not \$Stop -and -not \$DryRun -and -not \$Status -and -not \$VerifyOnly -and -not \$Preflight\)/)];
PROBES['G-14'] = [eng(/端口 \$Port 已有监听者/)];
PROBES['G-15'] = [{ file: ENGINE, inFunction: 'Invoke-RescueLaunch', lacks: /while \(|for \(\$attempt/, note: 'exactly one rescue attempt' }];
PROBES['G-16'] = [{ file: ENGINE, inFunction: 'Invoke-RescueLaunch', has: /catch/ }];
PROBES['G-17'] = [eng(/\$vNm = Join-Path \$vProfile 'node_modules'/)];
PROBES['G-18'] = [eng(/EPERM\|EACCES\|拒绝访问\|Access is denied\|cannot resolve profile bundle/)];
PROBES['G-19'] = [{ file: ENGINE, inFunction: 'Stop-DshInstance', has: /\(Get-SystemTool 'taskkill'\)/g, min: 2 }, { file: ENGINE, inFunction: 'Stop-DshInstance', has: /rc2/ }];
PROBES['G-20'] = [{ file: ENGINE, inFunction: 'Test-StopPermission', has: /已消失|\$true/, note: 'a vanished target counts as terminable, not as a permission error' }];
PROBES['G-21'] = [{ file: ENGINE, note: 'an elevation probe that itself fails degrades to unknown instead of blocking', fn: (ctx) => {
    const text = ctx.text(ENGINE);
    const start = text.search(/^function Test-Elevation\b/m);
    assert.ok(start >= 0, 'Test-Elevation is missing');
    const rest = text.slice(start);
    const next = rest.search(/\nfunction /);
    const region = next < 0 ? rest : rest.slice(0, next);
    assert.ok(/catch \{[\s\S]{0,160}ok = \$false/.test(region), 'the catch branch must return ok=$false (unknown)');
} }];

// ------------------------------------------------------------------ §6 deep verification
PROBES['V-01'] = [eng(/"dsh-verify\." \+ \[guid\]::NewGuid/), { file: ENGINE, inFunction: 'Get-FreePort', has: /TcpListener/ }];
PROBES['V-02'] = [{ file: ENGINE, inFunction: 'Test-DeepVerify', has: /Get-ChildItem[\s\S]{0,200}Copy-Item/ }];
PROBES['V-03'] = [{ file: ENGINE, inFunction: 'Copy-TreeWithLinks', has: /ReparsePoint/ }, { file: ENGINE, inFunction: 'Copy-TreeWithLinks', has: /continue/ }];
PROBES['V-04'] = [{ file: ENGINE, inFunction: 'Test-DeepVerify', has: /New-Item -ItemType Directory -Force -Path \$vNm/ }, { file: ENGINE, inFunction: 'Test-DeepVerify', has: /ItemType Junction/ }];
PROBES['V-05'] = [{ file: ENGINE, inFunction: 'Test-DeepVerify', has: /@\*/ }];
PROBES['V-06'] = [eng(/\$env2 = @\{ DSH_HOME = \$v; DSH_UC_PROFILE_NODE_MODULES = \$vNm \}/)];
PROBES['V-07'] = [{ file: ENGINE, note: 'the verify instance is started with the profile alias; --profile would make it hang as an orphan', fn: (ctx) => {
    const text = ctx.text(ENGINE);
    const argv = /\$vArgs = @\(([^)]*)\)/.exec(text);
    assert.ok(argv, 'the verify argv line is missing');
    assert.ok(argv[1].includes("'web'"), 'the profile alias is passed positionally');
    assert.ok(!argv[1].includes('--profile'), 'the verify argv must not pass --profile');
} }];
PROBES['V-08'] = [{ file: ENGINE, inFunction: 'Test-DeepVerify', has: /Start-Process -FilePath[\s\S]{0,300}-WindowStyle Hidden[\s\S]{0,300}-Environment/ }];
PROBES['V-09'] = [{ file: ENGINE, inFunction: 'Test-HttpServing', has: /401|\b200\b/ }];
PROBES['V-10'] = [{ file: ENGINE, inFunction: 'Test-DeepVerify', has: /logdir/ }];
PROBES['V-11'] = [{ file: ENGINE, inFunction: 'Test-DeepVerify', has: /Process exited|已退出/ }, { file: ENGINE, inFunction: 'Test-DeepVerify', has: /404/ }];
PROBES['V-12'] = [{ file: ENGINE, inFunction: 'Remove-VerifyInstance', has: /\[ref\]\$Progress/ }, { file: ENGINE, inFunction: 'Remove-VerifyInstance', has: /15/ }];
PROBES['V-13'] = [{ file: ENGINE, inFunction: 'Invoke-DeepVerifyWithRetry', has: /Test-DeepVerify/g, count: 2, note: 'at most one retry' }];
PROBES['V-14'] = [eng(/if \(\$VerifyOnly -or \$Preflight\) \{[\s\S]{0,500}Test-SymlinkPrivilege[\s\S]{0,500}Invoke-DeepVerifyWithRetry/)];
PROBES['V-15'] = [eng(/if \(\$VerifyOnly -or \$Preflight\) \{/, { count: 1 })];

// ------------------------------------------------------------------ §7 port discovery
PROBES['D-01'] = [eng(/& \(Get-SystemTool 'netstat'\) -ano -p TCP/, { count: 1, note: 'the one authoritative scan' }), eng(/function Get-SystemTool/, { count: 1, note: 'absolute-path resolution lives in one place' })];
PROBES['D-02'] = [eng(/@\(\$pids \| Sort-Object -Unique\)/)];
PROBES['D-03'] = [{ file: ENGINE, inFunction: 'Get-HostCandidate', fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'Get-HostCandidate');
    for (const key of ['pid', 'name', 'port', 'isNode', 'start', 'ws_mb', 'handles', 'source']) {
        assert.ok(new RegExp(`^\\s+${key}\\s*=`, 'm').test(body), `candidate field missing: ${key}`);
    }
} }];
PROBES['D-04'] = [eng(/\$proc\.ProcessName -match '\^\(node\|dsh\|bun\)\$'/)];
PROBES['D-05'] = [
    { file: ENGINE, inFunction: 'Get-HostCandidate', has: /Get-PortOwner \$Port/, note: 'the port listener stays the authority (R4)' },
    { file: ENGINE, inFunction: 'Get-HostCandidate', has: /\$cmd -match/, note: 'the command line only refines isNode when the dsh web host is the Electron CLI shim' },
];
PROBES['D-06'] = [{ file: ENGINE, inFunction: 'Test-HostAlive', has: /Get-PortOwner/ }];
PROBES['D-07'] = [{ file: ENGINE, inFunction: 'Get-CimAvailable', has: /CimInstance|Win32_Process/ }, eng(/CIM 不可用（沙箱\/权限）→ 以端口监听者为权威/)];
PROBES['D-08'] = [eng(/\$hop -lt 6/), eng(/port-owner-mismatch/)];
PROBES['D-09'] = [{ file: ENGINE, inFunction: 'Test-PortBindable', has: /TcpListener/ }, { file: ENGINE, inFunction: 'Test-PortBindable', has: /finally/ }];
PROBES['D-12'] = [
    { file: ENGINE, note: 'one authoritative netstat scan: Get-NetstatListenerRows owns the literal', fn: (ctx) => {
        const text = ctx.text(ENGINE);
        const hits = text.match(/-ano -p TCP/g) ?? [];
        assert.equal(hits.length, 1, `netstat -ano -p TCP must appear exactly once, found ${hits.length}`);
        const start = text.search(/^function Get-NetstatListenerRows\b/m);
        assert.ok(start >= 0, 'Get-NetstatListenerRows is missing');
        const body = ctx.functionBody(ENGINE, 'Get-NetstatListenerRows');
        assert.ok(/-ano -p TCP/.test(body), 'the scan must live inside Get-NetstatListenerRows');
    } },
    { file: ENGINE, inFunction: 'Get-ListeningPorts', has: /\$Rows/, note: 'accepts a pre-scanned row set instead of scanning again' },
    { file: ENGINE, inFunction: 'Get-NetstatListenerRows', has: /\$script:NetstatStamp/, note: 'process-local cache with an explicit Refresh' },
];
PROBES['D-13'] = [
    { file: ENGINE, inFunction: 'Get-ProcessIndex', has: /Get-CimInstance Win32_Process/ },
    { file: ENGINE, inFunction: 'Get-DesktopInstances', has: /Get-ProcessIndex/ },
    { file: ENGINE, inFunction: 'Get-DesktopInstances', has: /ContainsKey/, note: 'missing pid is skipped instead of iterating a hashtable as an object' },
];
PROBES['D-14'] = [
    { file: ENGINE, inFunction: 'Resolve-HostPort', has: /200 \{ 0 \} 401 \{ 1 \} 303 \{ 2 \}/, note: '200 > 401 > 303 > other' },
    { file: ENGINE, inFunction: 'Resolve-HostPort', has: /status -gt 0/, note: 'retry only when the port answered with a status code' },
    { file: ENGINE, inFunction: 'Resolve-HostPort', has: /stage = 'skipped'/, note: 'a known auxiliary port is not probed' },
    { file: ENGINE, inFunction: 'Resolve-HostPort', has: /stage = 'unprobed'/, note: 'an unobserved port is not reported as observed' },
    // 探测走原始 TCP：不走系统代理是结构性的（没有 HttpWebRequest/HttpClient，就没有代理解析），
    // 连接预算与请求预算分开则体现在 ConnectAsync(...).Wait(预算) 与 ReadTimeout 两处。
    { file: ENGINE, inFunction: 'Get-HttpStatusCodeDetail', has: /ConnectAsync\(\$Host_, \[int\]\$Port\)\.Wait\(\$maxWait\)/, note: 'connect budget is separate from the request budget' },
    { file: ENGINE, inFunction: 'Get-HttpStatusCodeDetail', has: /\$ns\.ReadTimeout = /, note: 'the read budget is explicit, not inherited' },
    { file: ENGINE, inFunction: 'Get-HttpStatusCodeDetail', has: /Connection: close/, note: 'no keep-alive: every probe is a fresh connection' },
];
PROBES['D-15'] = [
    { file: ENGINE, inFunction: 'Add-Phase', has: /\$script:PhasesOn/, note: 'no timing overhead outside -Json/-ResultFile' },
    { file: ENGINE, inFunction: 'Get-ResultEnvelope', has: /phases/, note: 'the envelope carries the phases key' },
];
PROBES['D-10'] = [{ file: ENGINE, inFunction: 'Get-ResidualChildren', has: /Get-Process -Name node/ }];
PROBES['D-11'] = [{ file: ENGINE, inFunction: 'Remove-OrphanDshChildren', has: /deepseek-ai\|codegraph/ }, { file: ENGINE, inFunction: 'Remove-OrphanDshChildren', has: /if \(\$ppid -gt 0 -and \(Get-Process -Id \$ppid/ }];

// ------------------------------------------------------------------ §8 scheduled task
PROBES['T-01'] = [{ file: ENGINE, inFunction: 'Get-RestartTaskEngine', has: /Get-Command pwsh/ }, { file: ENGINE, inFunction: 'Get-RestartTaskEngine', has: /WindowsPowerShell\\v1\.0\\powershell\.exe/ }];
PROBES['T-02'] = [eng(/-ViaTaskInner 的验证型重启需要 pwsh 7\.4\+/)];
PROBES['T-03'] = [{ file: ENGINE, fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'New-RestartTaskXml');
    const template = ctx.text(TASK_XML);
    const tags = (value) => new Set([...value.matchAll(/<([A-Za-z][A-Za-z0-9]*)[ >/]/g)].map((match) => match[1]));
    const generated = tags(body);
    const fixture = tags(template);
    for (const tag of ['RegistrationInfo', 'Triggers', 'Principals', 'Principal', 'Settings', 'Actions', 'Exec']) {
        assert.ok(fixture.has(tag), `task template is missing <${tag}>`);
        assert.ok(generated.has(tag), `New-RestartTaskXml is missing <${tag}>`);
    }
} }];
PROBES['T-04'] = [eng(/<LogonType>InteractiveToken<\/LogonType>/), eng(/<RunLevel>HighestAvailable<\/RunLevel>/), eng(/ConvertTo-XmlText \(\$env:USERDOMAIN \+ '\\' \+ \$env:USERNAME\)/)];
PROBES['T-05'] = [eng(/PT15M/), eng(/IgnoreNew/), eng(/MultipleInstancesPolicy>IgnoreNew/), eng(/ExecutionTimeLimit>PT15M/), eng(/<Priority>7<\/Priority>|Priority = 7|'7'/) ];
PROBES['T-06'] = [eng(/DisallowStartIfOnBatteries/, { note: 'task template covers the battery/idle policy' }), xml(/<DisallowStartIfOnBatteries>false<\/DisallowStartIfOnBatteries>/), xml(/<StopIfGoingOnBatteries>false<\/StopIfGoingOnBatteries>/), xml(/<RunOnlyIfIdle>false<\/RunOnlyIfIdle>/)];
PROBES['T-07'] = [{ file: ENGINE, inFunction: 'New-RestartTaskXml', fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'New-RestartTaskXml');
    for (const flag of ['-NoProfile', '-NonInteractive', '-ExecutionPolicy Bypass', '-File', '-ViaTaskInner', '-Profile', '-Port', '-DshHome', '-StateDir']) {
        assert.ok(body.includes(flag), `task arguments are missing ${flag}`);
    }
} }, xml(/-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%REPO%\\scripts\\dsh-restart\.ps1" -ViaTaskInner -Profile %PROFILE% -Port %PORT% -DshHome "%USERPROFILE%\\\.dsh" -StateDir "%LOCALAPPDATA%\\dsh-restart"/)];
PROBES['T-08'] = [eng(/ConvertTo-XmlText \$env:USERPROFILE/), xml(/<WorkingDirectory>%USERPROFILE%<\/WorkingDirectory>/)];
PROBES['T-09'] = [{ file: ENGINE, inFunction: 'ConvertTo-XmlText', fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'ConvertTo-XmlText');
    assert.ok(/Replace\('&', '&amp;'\)/.test(body), 'escapes &');
    assert.ok(/Replace\('<', '&lt;'\)/.test(body), 'escapes <');
    assert.ok(/Replace\('>', '&gt;'\)/.test(body), 'escapes >');
    assert.ok(!/SecurityElement\.Escape\(/.test(body), 'does not call SecurityElement.Escape (it would rewrite quotes)');
} }];
PROBES['T-10'] = [{ file: TASK_XML, note: 'the template must stay a placeholder fixture: no machine paths, names or host names', fn: (ctx) => {
    const text = ctx.text(TASK_XML);
    // Generic: a literal drive-letter path is a real installation location;
    // every path in the template must be %VAR%-based.
    assert.equal(countMatches(text, DRIVE_PATH_RE), 0, 'the template contains a literal drive-letter path');
    const leaks = scanForLeaks(text, redactionTerms());
    assert.deepEqual(leaks.map((hit) => `line ${hit.line}: ${hit.category}`), [], 'the template contains a machine identifier');
    for (const placeholder of ['%TASK_NAME%', '%PROFILE%', '%PORT%', '%REPO%', '%USERPROFILE%']) {
        assert.ok(text.includes(placeholder), `task template is missing placeholder ${placeholder}`);
    }
} }];
PROBES['T-11'] = [eng(/UnicodeEncoding\(\$false, \$true\)/)];
PROBES['T-12'] = [eng(/\(Get-SystemTool 'schtasks'\) \/Create \/TN \$TaskName \/XML \$path \/F/)];
PROBES['T-13'] = [{ file: ENGINE, inFunction: 'Invoke-ViaTask', has: /\/Run \/TN \$TaskName/ }];
PROBES['T-14'] = [eng(/\(Get-SystemTool 'schtasks'\) \/Delete \/TN \$TaskName \/F/)];
PROBES['T-15'] = [{ file: ENGINE, inFunction: 'Get-TaskRegistered', has: /\/Query \/TN \$TaskName/ }];
PROBES['T-16'] = [eng(/if \(\$ViaTask\) \{[\s\S]{0,600}Write-Terminal 'via-task-dispatched' 0/)];
PROBES['T-17'] = [{ file: INSTALL, has: /dsh-restart-win\.cmd/ }, { file: INSTALL, fn: (ctx) => {
    const text = ctx.text(INSTALL);
    assert.ok(/ASCII/i.test(text), 'the shim is documented as ASCII-only (cmd.exe reads it in the OEM code page)');
} }];

// ------------------------------------------------------------------ §9 pending notice
PROBES['N-01'] = [{ file: ENGINE, inFunction: 'Write-PendingNotice', has: /if \(-not \$SessionId\)/ }];
PROBES['N-02'] = [{ file: ENGINE, inFunction: 'Get-NewestSessionId', has: /session\*\.jsonl\*/ }, { file: ENGINE, inFunction: 'Get-NewestSessionId', has: /LastWriteTime/ }];
PROBES['N-03'] = [{ file: ENGINE, inFunction: 'Normalize-SessionId', has: /session-/ }];
PROBES['N-04'] = [{ file: ENGINE, inFunction: 'Write-PendingNotice', has: /join-path|Join-Path \$dir 'pending-notice\.json'/ }, { file: ENGINE, inFunction: 'Write-PendingNotice', has: /sessionId = \$SessionId; reason = \$Why; when = Get-NowIso/ }, { file: ENGINE, inFunction: 'Write-PendingNotice', has: /New-Utf8NoBom/ }];
PROBES['N-05'] = [eng(/if \(-not \$Start\) \{[\s\S]{0,200}Write-PendingNotice/)];
PROBES['N-06'] = [{ file: ENGINE, inFunction: 'Write-PendingNotice', has: /Add-Step 'notice' .*'warn'/ }];
PROBES['N-07'] = [tls(/writePendingNotice/), tls(/writeLaunchRequest/), run(/restartDelayMs|delayMs/), cfg(/restartDelayMs: 1500/)];

// ------------------------------------------------------------------ §10 status view
PROBES['ST-01'] = [{ file: ENGINE, inFunction: 'Show-Status', fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'Show-Status');
    for (const key of ['version', 'dshHome', 'stateDir', 'profile', 'port', 'url']) {
        assert.ok(new RegExp(`^\\s+${key}\\s+=`, 'm').test(body), `status field missing: ${key}`);
    }
} }];
PROBES['ST-02'] = [eng(/launchUrl\s+= \$stUrl/), eng(/launchUrlState = \$auth\.State/), eng(/launchUrlDetail = \$auth\.Detail/), eng(/'ok'\|'stale'\|'unknown'/)];
PROBES['ST-03'] = [eng(/http\s+= \$probe\.status/), eng(/serving\s+= \$probe\.serving/)];
PROBES['ST-04'] = [eng(/cimOk\s+= \$cim/)];
PROBES['ST-05'] = [eng(/instances\s+= @\(\$instances\)/)];
PROBES['ST-06'] = [eng(/nodeChildren = @\(\$children\)/)];
PROBES['ST-07'] = [eng(/bootRecord = \$rec/)];
PROBES['ST-08'] = [eng(/lastRestart = \$last/)];
PROBES['ST-09'] = [eng(/marker\s+= \$\(try \{ Get-Content \(Join-Path \$DshHome '\.smart-restart\\marker\.json'\)/)];
PROBES['ST-10'] = [eng(/DSH_HOME\s+:/), eng(/状态目录\s+:/), eng(/目标\s+:/), eng(/HTTP\s+:/), eng(/访问地址\s+:/), eng(/进程发现\s+:/), eng(/启动档案\s+:/), eng(/最近一次重启/)];
PROBES['ST-11'] = [{ file: ENGINE, inFunction: 'Show-Status', has: /\/Query \/TN \$TaskName/ }, { file: ENGINE, inFunction: 'Show-Status', has: /Where-Object \{ \$_ -isnot \[System\.Management\.Automation\.ErrorRecord\] \}/, note: 'schtasks stderr must not abort -Status on 5.1' }, { file: ENGINE, inFunction: 'Show-Status', lacks: /'DSH Restart'/ }];
PROBES['ST-12'] = [{ file: ENGINE, inFunction: 'Show-Status', has: /profiles\\\$Profile\\node_modules\\dsh-smart-restart/ }, { file: ENGINE, inFunction: 'Show-Status', lacks: /profiles\\web\\/ }];
PROBES['ST-13'] = [eng(/已提升（Full）/), eng(/未提升（Default）/), eng(/'未知'/)];
PROBES['ST-14'] = [eng(/\$script:Extra\['status'\]/)];
for (const key of ['version', 'dshHome', 'stateDir', 'profile', 'port', 'url', 'launchUrl', 'launchUrlState', 'launchUrlDetail', 'http', 'serving', 'cimOk', 'instances', 'nodeChildren', 'bootRecord', 'lastRestart', 'marker']) {
    PROBES['ST-14'].push({ file: ENGINE, inFunction: 'Show-Status', has: new RegExp(`^\\s+${key}\\s+=`, 'm'), note: `status.${key} is preserved verbatim` });
}

// ------------------------------------------------------------------ §11 dev tooling
PROBES['B-01'] = [chk(/EF BB BF|BOM/), chk(/LF/), chk(/Parser\]::ParseFile/), chk(/pwsh7/), chk(/ps51/)];
PROBES['B-02'] = [{ file: ENGINE, fn: (ctx) => {
    assert.ok(!existsSync(join(ROOT, 'pack.ps1')), 'pack.ps1 must not be carried into the plugin repo');
    assert.ok(!existsSync(join(ROOT, 'bin/pack.ps1')), 'bin/pack.ps1 must not be carried into the plugin repo');
    assert.ok(ctx.text(CHECK_ENCODING).length > 0, 'check-encoding.ps1 carries the checks');
} }];
PROBES['B-03'] = [{ file: 'test/parity.mjs', has: /read\(/ }, {
    note: 'the smoke cases are parameterised by an idle port (no production instance needed)',
    fn: () => {
        assert.ok(existsSync(join(ROOT, 'test/parity.mjs')), 'test/parity.mjs exists');
        assert.ok(/scripts\/dsh-restart\.ps1/.test(readFileSync(join(ROOT, MATRIX), 'utf8')), 'the matrix documents the engine path the smoke cases use');
    },
}];
PROBES['B-04'] = [{ file: ENGINE, fn: () => {
    assert.ok(existsSync(join(ROOT, 'scripts/audit-profile.ps1')), 'scripts/audit-profile.ps1 does not exist (matrix B-04 points at it)');
} }];
PROBES['B-05'] = [chk(/ParseFile/), chk(/pwsh7/), chk(/ps51/)];

// ------------------------------------------------------------------ §12 undocumented behaviour
PROBES['U-01'] = [{ file: ENGINE, inFunction: 'Get-RegistryEnvironmentBlock', has: /Machine|machine/ }, { file: ENGINE, inFunction: 'Get-RegistryEnvironmentBlock', has: /User|user/ }, { file: ENGINE, inFunction: 'Get-RegistryEnvironmentBlock', has: /Expand-EnvValue/ }];
PROBES['U-02'] = [{ file: ENGINE, inFunction: 'Sync-ProcessEnvironment', has: /WindowsIdentity\]::GetCurrent\(\)\.Name/ }];
PROBES['U-03'] = [{ file: ENGINE, inFunction: 'Show-Status', lacks: /"DSH Restart"|'DSH Restart'/ }, { file: ENGINE, inFunction: 'Show-Status', has: /\$TaskName/ }];
PROBES['U-04'] = [{
    note: 'CONTRACT §3.8: -BindHost must not participate in the launch command',
    fn: (ctx) => {
        const text = ctx.text(ENGINE);
        const launch = /DEFAULT_LAUNCH\['args'\]\s*=\s*(.+)$/m.exec(text);
        assert.ok(launch, 'DEFAULT_LAUNCH args not found');
        assert.ok(!/\$BindHost/.test(launch[1]), `launch args consume $BindHost: ${launch[1].trim()}`);
    },
}];
PROBES['U-05'] = [{
    note: 'README exit-code table must list 0-12 (the old README was missing 11 and 12)',
    fn: () => {
        const text = read(README);
        assert.ok(text !== null, 'README.md is missing');
        for (const code of [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]) {
            assert.ok(new RegExp(`\\b${code}\\b`).test(text), `README exit-code table is missing ${code}`);
        }
    },
}];
PROBES['U-06'] = [{
    note: 'CONTRACT §3.3: 13 fixed envelope fields, status nested verbatim',
    fn: (ctx) => {
        const body = ctx.functionBody(ENGINE, 'Get-ResultEnvelope');
        for (const key of ['ok', 'result', 'exitCode', 'version', 'steps', 'warnings', 'targetPid', 'newPid', 'hostUrl', 'error', 'durationMs', 'stateDir', 'logPath']) {
            assert.ok(new RegExp(`^\\s+${key}\\s+=`, 'm').test(body), `envelope field missing: ${key}`);
        }
    },
}];
PROBES['U-07'] = [eng(/if \(\$Stop\) \{[\s\S]{0,3000}= Test-ConfigOperationGate/)];
PROBES['U-08'] = [{ file: ENGINE, inFunction: 'Get-ResidualChildren', fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'Get-ResidualChildren');
    assert.ok(/Get-Process -Name node/.test(body), 'iterates node processes');
    assert.ok(!/ParentProcessId/.test(body), 'the name means "all other node processes", not "children"');
} }];
PROBES['U-09'] = [
    eng(/\$instances = @\(Get-DshInstances\)/, { note: 'empty array must not unwrap to $null' }),
    eng(/\$children = @\(if \(\$script:HostKind -eq 'desktop'\)/),
    eng(/if \(\$tailProp -and \$tailProp\.Value\)/),
    eng(/@\(\$pids \| Sort-Object -Unique\)/),
];
PROBES['U-10'] = [eng(/return \('Local\\dsh-restart-p' \+ \$Port\)/)];
PROBES['U-11'] = [eng(/if \(\$VerifyOnly -or \$Preflight\) \{/, { count: 1, note: '-Preflight and -VerifyOnly share one branch' })];
PROBES['U-12'] = [{ file: ENGINE, inFunction: 'Write-Terminal', lacks: /Move-Item|Rotate/ }];
PROBES['U-13'] = [eng(/url\s+= "http:\/\/\$\{BindHost\}:\$Port\/"/), eng(/launchUrl\s+= \$stUrl/)];
PROBES['U-14'] = [eng(/New-Utf8NoBom \(Join-Path \$dir 'pending-notice\.json'\)/)];
PROBES['U-15'] = [eng(/\[System\.IO\.FileShare\]::ReadWrite/), eng(/Get-AppendedText|Select-String -LiteralPath \$LogPath/)];

// ------------------------------------------------------------------ §14 machine facts / 反硬编码
// 这一节记录的是「本机实测驱动出来的去硬编码改动」：安装位置不靠猜、系统工具不靠 PATH。
const INSTALL_SCRIPT = 'scripts/dsh-plugin-install.ps1';
const CONFIG_SCRIPT = 'scripts/dsh-config.ps1';

// 注意（2026-11-22）：markdown 表里已有的 X-07/X-08/X-09 行（`task-unregistered` 等终态词）
// 在 test/parity.mjs 里一直没有对应 probe，扫描器把它们报成 9 条「no behavioural probe」。
// 这里补上矩阵「验证方式」列承诺的那三条断言 —— 缺的那部分照原文补，不借机改语义。
PROBES['X-01'] = [eng(/Write-Terminal 'restarted-ok' 0/)];
PROBES['X-02'] = [eng(/Write-Terminal 'status' 0/)];
PROBES['X-03'] = [eng(/Write-Terminal 'verify-only-ok' 0/)];
PROBES['X-04'] = [eng(/Write-Terminal 'dry-run' 0/g, { min: 2 })];
PROBES['X-05'] = [eng(/Write-Terminal 'stopped' 0/g, { min: 2 })];
PROBES['X-06'] = [eng(/'task-registered' \} else \{ 'task-register-failed' \}\)/)];

PROBES['X-07'] = [eng(/Write-Terminal 'task-unregistered' \$\(if \(\$LASTEXITCODE -eq 0\) \{ 0 \} else \{ 1 \}\)/),
    eng(/exit \$script:ExitCode/, { note: 'the process exit code must follow the envelope' })];
PROBES['X-08'] = [eng(/Write-Terminal 'via-task-dispatched' 0/)];
PROBES['X-09'] = [eng(/Write-Terminal 'recorded' 0/)];

PROBES['MP-01'] = [{
    note: 'no hardcoded install location: the exe is discovered from registry/shortcuts, never a literal path',
    fn: (ctx) => {
        const engine = ctx.text(ENGINE);
        assert.ok(/function Get-DesktopInstallPaths/.test(engine), 'Get-DesktopInstallPaths is missing');
        const body = ctx.functionBody(ENGINE, 'Get-DesktopInstallPaths');
        assert.ok(/Uninstall/.test(body), 'the uninstall registry key is not consulted');
        assert.ok(/App Paths/.test(body), 'App Paths is not consulted');
        assert.ok(/\.lnk/.test(body), 'start-menu/desktop shortcuts are not consulted');
        assert.ok(!/Test-Path -LiteralPath '[A-Za-z]:[\\/]/.test(body), 'a literal drive path is used as a candidate');
    },
}];

PROBES['MP-02'] = [{
    note: 'the machine config file is the first candidate, and its absence is not fatal',
    fn: (ctx) => {
        const body = ctx.functionBody(ENGINE, 'Resolve-DesktopAppPath');
        assert.ok(/Get-MachineConfig/.test(body), 'machine.json is not consulted');
        assert.ok(body.indexOf('machine-config') < body.indexOf('running-instance'), 'machine.json must win over the running instance');
        const getter = ctx.functionBody(ENGINE, 'Get-MachineConfig');
        assert.ok(/return \$null/.test(getter), 'a missing/broken config must degrade, not throw');
    },
}];

PROBES['MP-03'] = [{
    note: 'system tools resolve to absolute paths (a bare name depends on the caller PATH)',
    fn: (ctx) => {
        const engine = ctx.text(ENGINE);
        for (const tool of ['netstat', 'taskkill', 'schtasks', 'robocopy']) {
            assert.ok(new RegExp(`Get-SystemTool '${tool}'`).test(engine), `${tool} is still invoked by bare name`);
        }
        const body = ctx.functionBody(ENGINE, 'Get-SystemTool');
        assert.ok(/System32/.test(body), 'Get-SystemTool does not prefer System32');
    },
}];

PROBES['MP-04'] = [{
    note: 'the status envelope publishes the installation facts external tools need',
    fn: (ctx) => {
        const body = ctx.functionBody(ENGINE, 'Show-Status');
        for (const key of ['desktopApp', 'desktopAppSource', 'runtimeDir', 'pnpm', 'nodeExe']) {
            assert.ok(new RegExp(`${key}\\s*=`).test(body), `status.${key} is missing`);
        }
    },
}];

PROBES['MP-05'] = [{
    note: 'the plugin-install script resolves every machine fact through the engine and never hardcodes a path',
    fn: () => {
        const text = read(INSTALL_SCRIPT);
        assert.ok(text !== null, 'scripts/dsh-plugin-install.ps1 is missing');
        assert.ok(/-Status/.test(text), 'the repair script does not ask the engine for facts');
        assert.ok(!/[A-Za-z]:\\deepseek/i.test(text), 'the repair script still hardcodes an install location');
        const resolved = /function Resolve-Engine[\s\S]*?\n}/.exec(text);
        assert.ok(resolved, 'Resolve-Engine body not found');
        assert.ok(/\.ps1/.test(resolved[0]), 'Resolve-Engine must resolve the .ps1 engine');
    },
}];

PROBES['MP-07'] = [{
    note: 'the repair script is wired into the development workflow: a read-only notice probe and the documented switch',
    fn: () => {
        const probe = read('scripts/probe-plugin-install.ps1');
        assert.ok(probe !== null, 'scripts/probe-plugin-install.ps1 is missing');
        assert.ok(/dsh-plugin-install\.ps1/.test(probe), 'the probe does not target the install script');
        assert.ok(/Write-PendingNoticeSafe/.test(probe), 'the probe does not exercise the notice writer');
        const zh = read(README_ZH);
        assert.ok(zh !== null, 'README.zh.md is missing');
        assert.ok(/dsh-plugin-install\.ps1/.test(zh), 'README.zh.md does not document the install script');
        assert.ok(/dsh-config\.ps1/.test(zh), 'README.zh.md does not document the machine-config script');
        assert.ok(/machine\.json/.test(zh), 'README.zh.md does not document machine.json');
    },
}];

PROBES['MP-06'] = [{
    note: 'dsh-config writes the probe result; the engine reads it back',
    fn: () => {
        const text = read(CONFIG_SCRIPT);
        assert.ok(text !== null, 'scripts/dsh-config.ps1 is missing');
        assert.ok(/machine\.json/.test(text), 'dsh-config does not write machine.json');
        assert.ok(/desktopApp/.test(text) && /runtimeDir/.test(text), 'dsh-config does not record the install facts');
        assert.ok(!/[A-Za-z]:\\deepseek/i.test(text), 'dsh-config hardcodes an install location');
    },
}];

// ------------------------------------------------------------------ §13 must change
PROBES['M-01'] = [{
    note: 'no machine-specific absolute path may survive in scripts/** (values come from the local term list / environment, never from this file)',
    fn: () => {
        const files = [ENGINE, CHECK_ENCODING, TASK_XML, INSTALL];
        const terms = redactionTerms();
        const pathShapes = new Set(['machine-term', 'windows-user-profile', 'posix-home', 'absolute-path']);
        const hits = files.flatMap((file) => scanFileHits(file, terms))
            .filter((hit) => pathShapes.has(hit.category))
            .map((hit) => `${hit.file}:${hit.line}: hit ${hit.category}`);
        assert.deepEqual(hits, [], hits.join('; '));
        for (const file of files) {
            const text = read(file);
            assert.ok(text !== null, `${file} is missing`);
            // Every path in these deliverables is %VAR%-based; a literal
            // drive-letter path would be an installation location. (One segment
            // is required so a regex literal such as `b:\s` is not a match.)
            const driveHits = [...text.matchAll(new RegExp(DRIVE_PATH_RE.source, 'g'))]
                .map((match) => `${file}:${text.slice(0, match.index).split('\n').length}`);
            assert.deepEqual(driveHits, [], `literal drive-letter path at ${driveHits.join(', ')}`);
        }
    },
}];
PROBES['M-02'] = [{
    note: 'no hardcoded port numbers in comments (the port is a parameter now)',
    fn: (ctx) => {
        // The neighbour port is derived, never written here, so this file stays
        // free of the machine-specific literals it scans for.
        const ports = [String(DEFAULTS.port), String(DEFAULTS.port + 1)];
        const portRe = new RegExp(`\\b(?:${ports.join('|')})\\b`);
        const offenders = ctx.text(ENGINE).split(/\r?\n/)
            .map((line, index) => ({ line, index: index + 1 }))
            .filter(({ line }) => /^\s*#/.test(line) && portRe.test(line));
        assert.deepEqual(offenders.map((entry) => entry.index), [], `comment lines still hardcode a port: ${offenders.map((entry) => entry.index).join(', ')}`);
    },
}];
PROBES['M-03'] = [{ file: ENGINE, inFunction: 'Show-Status', lacks: /"DSH Restart"|'DSH Restart'/ }];
PROBES['M-04'] = [{ file: TASK_XML, note: 'the task template carries placeholders instead of this machine\'s values', fn: (ctx) => {
    const text = ctx.text(TASK_XML);
    const leaks = scanForLeaks(text, redactionTerms());
    assert.deepEqual(leaks.map((hit) => `line ${hit.line}: ${hit.category}`), [], 'the template leaks a machine identifier');
    assert.equal(countMatches(text, DRIVE_PATH_RE), 0, 'the template contains a literal drive-letter path');
    assert.ok(/%REPO%|%TASK_NAME%/.test(text), 'the template is placeholder-based');
} }];
PROBES['M-05'] = [eng(/package\.json/), eng(/'1\.0\.0-win'/, { count: 0 })];
PROBES['M-06'] = [{
    note: 'no real token may appear in tracked files',
    fn: () => {
        const files = [ENGINE, CHECK_ENCODING, TASK_XML, INSTALL, TOOLS, CONFIG, RUNNER, PATHS, CLI, PACKAGE, CORDIS, 'test/selftest.mjs', 'test/parity.mjs'];
        const terms = redactionTerms();
        for (const file of files) {
            const text = read(file);
            if (text === null) continue;
            // Only concrete credential shapes count here: source code may
            // legitimately contain a *pattern* that parses a token.
            const credentialShapes = new Set(['github-token', 'api-key', 'bearer-token']);
            const hits = scanForLeaks(text, terms).filter((hit) => credentialShapes.has(hit.category));
            assert.deepEqual(hits.map((hit) => `${file}:${hit.line}: ${hit.category}`), [], `${file} contains a credential-shaped value`);
            for (const match of text.matchAll(/token=([A-Za-z0-9_-]{16,})/g)) {
                const allowed = terms.allow.some((value) => match[0].includes(value));
                assert.ok(allowed, `${file}:${text.slice(0, match.index).split('\n').length}: hit token-shaped value`);
            }
        }
    },
}];
PROBES['M-07'] = [{
    note: 'session ids in the repository are placeholders only',
    fn: () => {
        const files = [MATRIX, 'test/selftest.mjs', 'test/parity.mjs'];
        for (const file of files) {
            const text = read(file);
            if (text === null) continue;
            for (const match of text.matchAll(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi)) {
                const line = text.slice(0, match.index).split('\n').length;
                assert.equal(match[0], '00000000-0000-0000-0000-000000000000', `${file}:${line}: hit a real-looking session id`);
            }
        }
    },
}];
PROBES['M-08'] = [{
    note: 'the four operations write-ups stay out of the repository',
    fn: () => {
        for (const file of ['重启操作卡.md', '目录选择器修复记录.md', 'SAFE-MODE-排查记录.md', 'MCP接入记录.md']) {
            assert.ok(!existsSync(join(ROOT, file)), `${file} must not be carried into the repo`);
        }
    },
}];
PROBES['M-09'] = [{
    note: 'pack.ps1 is replaced by check-encoding + CI',
    fn: () => {
        assert.ok(!existsSync(join(ROOT, 'pack.ps1')));
        assert.ok(!existsSync(join(ROOT, 'bin/pack.ps1')));
        assert.ok(existsSync(join(ROOT, CI)), `${CI} is missing`);
        const ci = read(CI);
        assert.ok(/check-encoding\.ps1/.test(ci), 'CI runs check-encoding.ps1');
    },
}];
PROBES['M-10'] = [eng(/DSH_UC_PROFILE_NODE_MODULES/), eng(/NPM_CONFIG_LEGACY_PEER_DEPS/), eng(/\$env:DSH_HOME = \$DshHome/, { note: 'injected at process scope only' })];
PROBES['M-11'] = [{ file: ENGINE, inFunction: 'Get-DshEntry', note: 'the three candidates and their order are the old engine\'s real shape (the matrix was corrected: no npm-prefix probe exists)', fn: (ctx) => {
    const body = ctx.functionBody(ENGINE, 'Get-DshEntry');
    const candidates = [
        "Join-Path $env:APPDATA 'npm\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js'",
        "Join-Path $env:ProgramFiles 'nodejs\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js'",
    ];
    let previous = -1;
    for (const candidate of candidates) {
        const at = body.indexOf(candidate);
        assert.ok(at > previous, `candidate missing or reordered: ${candidate}`);
        previous = at;
    }
    assert.ok(/Get-Command dsh/.test(body), 'the PATH-resolved dsh candidate is present');
    assert.ok(!/npm prefix/.test(body), 'no npm-prefix candidate: it never existed in the old engine');
} }];
PROBES['M-12'] = [{
    note: 'the nine defaults must match the pre-plugin behaviour exactly',
    fn: () => {
        assert.deepEqual(
            {
                profile: DEFAULTS.profile,
                port: DEFAULTS.port,
                bindHost: DEFAULTS.bindHost,
                taskName: DEFAULTS.taskName,
                stateDir: DEFAULTS.stateDir,
                readySec: DEFAULTS.readySec,
                verifyReadySec: DEFAULTS.verifyReadySec,
                graceSec: DEFAULTS.graceSec,
                portFreeSec: DEFAULTS.portFreeSec,
            },
            {
                profile: 'web',
                port: 3080,
                bindHost: '127.0.0.1',
                taskName: 'DSH Restart',
                stateDir: '',
                readySec: 90,
                verifyReadySec: 150,
                graceSec: 3,
                portFreeSec: 30,
            },
        );
    },
}];
PROBES['M-13'] = [eng(/\[string\]\$ResultFile = ''/), eng(/\[switch\]\$NoWait/), run(/'-ResultFile', resultFile/), run(/if \(noWait\) args\.push\('-NoWait'\)/)];
PROBES['M-14'] = [{ file: PACKAGE, fn: (ctx) => {
    const pkg = JSON.parse(ctx.text(PACKAGE));
    assert.equal(pkg.name, '@brainzombie/dsh-restart-win');
    assert.equal(pkg.bin['dsh-restart-win'], 'bin/dsh-restart-win.mjs');
    assert.equal(pkg.publishConfig.access, 'public');
    assert.equal(pkg.private, undefined, 'the package must be publishable');
} }, { file: CORDIS, has: /id: dsh-restart-win/ }, { file: TOOLS, fn: () => {
    for (const name of ['win_restart', 'win_restart_status', 'win_restart_preflight', 'win_restart_result']) {
        assert.ok(Object.values(TOOL_NAMES).includes(name), `tool ${name} is missing`);
    }
    for (const name of Object.values(TOOL_NAMES)) assert.ok(!/smart_restart/.test(name));
} }];

// --------------------------------------------------------------------------
// Scanner self-check and ad-hoc scan mode
// --------------------------------------------------------------------------

/**
 * Prove the scanner still catches what it is for, on this machine, without
 * ever printing the matched text:
 *
 *   - an injected Windows profile path is found (`C:\Users\<name>\…`);
 *   - an injected POSIX home path is found (`/home/<name>/…`);
 *   - a local machine term is found when the term list exists;
 *   - an empty scope returns zero hits instead of throwing.
 *
 * The injected names are fixed literals that are deliberately *not* in
 * `PLACEHOLDER_NAMES`: a value taken from the environment (e.g. `USERNAME`)
 * would be absent on a CI runner and fall back to something the scanner
 * correctly ignores as a placeholder, which would make this check fail for the
 * wrong reason.
 *
 * @returns {string} one-line summary
 */
function scannerSelfCheck() {
    const terms = redactionTerms();

    const windowsPath = ['C:', 'Users', 'k7x-not-a-placeholder', 'Documents'].join('\\');
    const windowsHits = scanForLeaks(`prefix ${windowsPath} suffix`, terms);
    assert.ok(
        windowsHits.some((hit) => hit.category === 'windows-user-profile'),
        `the scanner did not report category windows-user-profile for an injected Windows profile path (got: ${windowsHits.map((hit) => hit.category).join(', ') || 'no hits'})`,
    );

    const posixPath = ['', 'home', 'k7x-not-a-placeholder', 'docs'].join('/');
    const posixHits = scanForLeaks(`prefix ${posixPath} suffix`, terms);
    assert.ok(
        posixHits.some((hit) => hit.category === 'posix-home'),
        `the scanner did not report category posix-home for an injected POSIX home path (got: ${posixHits.map((hit) => hit.category).join(', ') || 'no hits'})`,
    );

    let termNote = 'machine terms: 0 (no local list and an empty environment)';
    if (terms.terms.length > 0) {
        const injectedTerm = scanForLeaks(`prefix ${terms.terms[0]} suffix`, terms);
        assert.ok(
            injectedTerm.some((hit) => hit.category === 'machine-term'),
            `the scanner did not report category machine-term for a term from ${terms.source}`,
        );
        termNote = `machine terms: ${terms.terms.length} from ${terms.source}`;
    }

    const empty = scanForLeaks('clean text with no identifiers at all', { terms: [], shapes: [], allow: [], source: 'none' });
    assert.deepEqual(empty, [], 'an empty scope produced a hit');

    return `scan-selfcheck: ok (injected windows-user-profile + posix-home detected; ${termNote}; empty scope: 0 hits, no crash)`;
}

/**
 * Scan files or directories for privacy leaks. Output is `path:line: category`
 * only — never the matched text, which may itself be a secret.
 *
 * @param {string} target
 * @returns {{ scanned: number, hits: string[] }}
 */
function scanTarget(target) {
    const terms = redactionTerms();
    const hits = [];
    let scanned = 0;
    const visit = (path) => {
        let stat;
        try {
            stat = statSync(path, { throwIfNoEntry: false });
        } catch {
            return;
        }
        if (!stat) return;
        if (stat.isDirectory()) {
            const base = path.split(/[\\/]/).filter(Boolean).pop() ?? '';
            if (['.git', 'node_modules', '.local'].includes(base)) return;
            let entries = [];
            try {
                entries = readdirSync(path);
            } catch {
                return;
            }
            for (const entry of entries) visit(join(path, entry));
            return;
        }
        if (!stat.isFile()) return;
        scanned += 1;
        let text;
        try {
            const bytes = readFileSync(path);
            const utf16le = bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe;
            text = (utf16le ? bytes.toString('utf16le') : bytes.toString('utf8')).replace(/^\uFEFF/, '');
        } catch {
            return;
        }
        for (const hit of scanForLeaks(text, terms)) {
            // Code may legitimately contain a credential *pattern* (a parser);
            // the local REGEX: entries describe data shapes (logs, docs, results).
            const code = /\.(?:ps1|js|mjs|ts)$/i.test(path);
            if (code && hit.category === 'local-term-regex') continue;
            hits.push(`${path.split(/[\\/]/).filter(Boolean).slice(-3).join('/')}:${hit.line}: hit ${hit.category}`);
        }
    };
    visit(join(ROOT, target));
    return { scanned, hits };
}

/** @param {string} path @returns {string[]} */

/**
 * Prove the harness is not vacuous: a fixture matrix with each defect class
 * must produce a failure. A green run over a broken matrix would be worse than
 * a red one, so this check runs before the real matrix.
 *
 * @returns {string} one-line summary
 */
function harnessSelfTest() {
    const header = [
        '| 能力ID | 能力 | 旧实现位置 | 插件目标位置 | 可配置化处理 | 验证方式 |',
        '|---|---|---|---|---|---|',
    ];
    const good = '| P-01 | `[string]$Profile` | bin/x.ps1:1 | scripts/dsh-restart.ps1@param | 不变 | parity:P-01 |';
    const cases = [
        { name: 'well-formed row', rows: [good], expect: null },
        { name: 'duplicate id', rows: [good, good], expect: 'duplicate capability id' },
        { name: 'empty evidence', rows: ['| P-02 | x | bin/x.ps1:1 | scripts/dsh-restart.ps1@param | 不变 | |'], expect: 'empty 验证方式 cell' },
        { name: 'empty old position', rows: ['| P-02 | x | | scripts/dsh-restart.ps1@param | 不变 | parity:P-02 |'], expect: 'empty 旧实现位置 cell' },
        { name: 'dangling anchor file', rows: ['| P-02 | x | bin/x.ps1:1 | lib/definitely-missing.js | 不变 | parity:P-02 |'], expect: 'anchor file does not exist' },
        { name: 'unknown parity reference', rows: ['| P-02 | x | bin/x.ps1:1 | scripts/dsh-restart.ps1@param | 不变 | parity:Q-99 |'], expect: 'unknown capability id' },
        { name: 'gitignored target', rows: ['| P-02 | x | bin/x.ps1:1 | .local/evidence/x.md | — | 人工：x |'], expect: 'gitignored workspace' },
        { name: 'no probe', rows: ['| Z-99 | x | bin/x.ps1:1 | scripts/dsh-restart.ps1@param | 不变 | parity:Z-99 |'], expect: 'no behavioural probe' },
    ];
    const failures = [];
    for (const testCase of cases) {
        const result = runSuite([...header, ...testCase.rows].join('\n'));
        const messages = result.rows.flatMap((row) => row.failures).join(' | ');
        if (testCase.expect === null) {
            if (result.rows.some((row) => row.failures.length > 0)) failures.push(`${testCase.name}: expected to pass, got ${messages}`);
        } else if (!messages.includes(testCase.expect)) {
            failures.push(`${testCase.name}: expected "${testCase.expect}", got "${messages}"`);
        }
    }
    assert.deepEqual(failures, [], failures.join('; '));
    return `harness-selfcheck: ok (${cases.length - 1} defect classes rejected, 1 valid row accepted)`;
}

// --------------------------------------------------------------------------
// Release scope
//
// `git ls-files` alone is empty before the first commit, so a scan over it
// would report "0 hits" for a repository full of files — a false green that is
// worse than a red. The release scope is therefore tracked + untracked but not
// ignored, and it is asserted to be non-trivial before anything is scanned.
// --------------------------------------------------------------------------

/**
 * @param {string} [root]
 * @returns {{ ok: boolean, files: string[], detail: string }}
 */
function gitReleaseFiles(root = ROOT) {
    try {
        const output = execFileSync(
            'git',
            ['ls-files', '--cached', '--others', '--exclude-standard'],
            { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, windowsHide: true },
        );
        const files = output.split('\n').map((line) => line.trim()).filter(Boolean);
        return { ok: true, files, detail: 'git ls-files --cached --others --exclude-standard' };
    } catch (error) {
        const detail = String(error?.stderr ?? error?.message ?? error).split('\n')[0];
        return { ok: false, files: [], detail };
    }
}

/**
 * A scan over an empty or unrepresentative set proves nothing.
 *
 * @param {string[]} files
 * @returns {string[]} problems
 */
function releaseScopeProblems(files) {
    const problems = [];
    if (files.length < 10) problems.push(`only ${files.length} file(s) in scope`);
    const extensions = new Set(files.map((file) => (file.match(/\.[A-Za-z0-9]+$/) ?? [''])[0].toLowerCase()));
    if (!['.js', '.mjs', '.ps1', '.md'].some((extension) => extensions.has(extension))) {
        problems.push('scope contains no .js/.mjs/.ps1/.md file');
    }
    return problems;
}

// --------------------------------------------------------------------------
// Runner
// --------------------------------------------------------------------------

/**
 * @typedef {{
 *   id: string, line: number, section: string,
 *   anchors: number, probes: number,
 *   failures: string[]
 * }} RowResult
 */

/**
 * @param {{ id: string, line: number, section: string, cells: string[] }} row
 * @param {string} matrixText
 * @returns {RowResult}
 */
function runRow(row, matrixText) {
    const failures = [];
    let anchors = 0;
    let probeCount = 0;
    const ctx = {
        text: (file) => {
            const value = read(file);
            if (value === null) throw new Error(`probe target does not exist: ${file}`);
            return value;
        },
        functionBody: (file, name) => {
            const body = functionBody(ctx.text(file), name);
            if (body === null) throw new Error(`function ${name} not found in ${file}`);
            return body;
        },
    };

    // 1. table shape
    if (row.cells.length !== 6) failures.push(`table row has ${row.cells.length} columns, expected 6`);
    for (const [index, name] of ['能力ID', '能力', '旧实现位置', '插件目标位置', '可配置化处理', '验证方式'].entries()) {
        if (!row.cells[index]) failures.push(`empty ${name} cell`);
    }

    // 2. old implementation position: file:line, or an explicit marker
    const oldCell = row.cells[2] ?? '';
    if (oldCell && !/\.(ps1|md|xml|cmd|json):\d/.test(oldCell) && !/本机|无旧实现/.test(oldCell)) {
        failures.push(`旧实现位置 has no file:line and no explicit 本机/无旧实现 marker: ${oldCell}`);
    }

    // 3. anchors
    let anchorList = [];
    try {
        anchorList = targetAnchors(row);
    } catch (error) {
        failures.push(error.message);
    }
    // A target column must point at something that ships. A gitignored path
    // (local workspace, dependencies, runtime output) can never be a target:
    // it would make the parity claim unverifiable for anyone else.
    const targetCell = row.cells[3] ?? '';
    const ignored = [
        { pattern: /\.local\//, name: '.local/ (gitignored workspace)' },
        { pattern: /node_modules\//, name: 'node_modules/ (dependency)' },
        { pattern: /\*\.log\b|\.log\b/, name: 'a runtime log' },
        { pattern: /dsh-verify\./, name: 'a temporary verification directory' },
        { pattern: /(^|[\s`(（])runs\//, name: 'a runtime runs/ directory' },
    ];
    for (const rule of ignored) {
        if (rule.pattern.test(targetCell)) failures.push(`插件目标位置 points at ${rule.name}: ${targetCell}`);
    }
    for (const anchor of anchorList) {
        anchors += 1;
        const problem = checkAnchor(anchor);
        if (problem) failures.push(problem);
    }
    for (const name of declaredParams(row)) {
        const block = paramBlock(ctx.text(ENGINE));
        if (!new RegExp(`\\$${escapeRe(name)}\\b`).test(block)) failures.push(`param $${name} is not declared in ${ENGINE}`);
    }

    // 4. behaviour probes
    const probes = PROBES[row.id] ?? [];
    if (probes.length === 0) failures.push('no behavioural probe registered for this capability id');
    for (const probe of probes) {
        probeCount += 1;
        try {
            let text = probe.file ? ctx.text(probe.file) : null;
            if (probe.inFunction) text = ctx.functionBody(probe.file, probe.inFunction);
            if (probe.fn) {
                probe.fn(ctx);
                continue;
            }
            if (probe.has !== undefined) {
                const matches = countMatches(text, probe.has);
                const label = `${String(probe.has)}${probe.note ? ` — ${probe.note}` : ''}`;
                if (probe.count !== undefined) {
                    if (matches !== probe.count) throw new Error(`expected exactly ${probe.count} match(es) for ${label}, found ${matches}`);
                } else if (probe.min !== undefined) {
                    if (matches < probe.min) throw new Error(`expected at least ${probe.min} match(es) for ${label}, found ${matches}`);
                } else if (matches === 0) {
                    throw new Error(`expected a match for ${label}`);
                }
                if (probe.max !== undefined && matches > probe.max) {
                    throw new Error(`expected at most ${probe.max} match(es) for ${label}, found ${matches}`);
                }
            }
            if (probe.lacks !== undefined) {
                const matches = countMatches(text, probe.lacks);
                if (matches > 0) throw new Error(`expected no match for ${String(probe.lacks)}, found ${matches}${probe.note ? ` — ${probe.note}` : ''}`);
            }
            if (probe.before) {
                const [first, second] = probe.before;
                const a = text.search(typeof first === 'string' ? new RegExp(escapeRe(first)) : first);
                const b = text.search(typeof second === 'string' ? new RegExp(escapeRe(second)) : second);
                if (a < 0) throw new Error(`ordering probe: ${String(first)} not found`);
                if (b < 0) throw new Error(`ordering probe: ${String(second)} not found`);
                if (!(a < b)) throw new Error(`ordering probe: expected ${String(first)} before ${String(second)}${probe.note ? ` — ${probe.note}` : ''}`);
            }
        } catch (error) {
            failures.push(`${probe.note ? `${probe.note}: ` : ''}${error.message}`);
        }
    }

    // 5. evidence column
    const verification = row.cells[5] ?? '';
    if (verification) {
        const referenced = [...verification.matchAll(/parity:([A-Z]{1,2}-\d{2})/g)].map((match) => match[1]);
        // `见 X-01 / Y-02` forwards the evidence to another row of the matrix.
        const forwarded = [...verification.matchAll(/见\s*((?:[A-Z]{1,2}-\d{2}[\s/、,，]*)+)/g)]
            .flatMap((match) => [...match[1].matchAll(/[A-Z]{1,2}-\d{2}/g)].map((id) => id[0]));
        // Manual/local evidence is recognised by its prefix or by a concrete
        // command in backticks; anything else must name a parity assertion.
        const manual = /本机[:：]|人工[:：]|扫描词表|词表扫描|零命中/.test(verification)
            || /`[^`]*(?:grep|git ls-files|pwsh|powershell|node|dsh |schtasks|npm )[^`]*`/.test(verification);
        if (referenced.length === 0 && forwarded.length === 0 && !manual) {
            failures.push(`验证方式 is neither parity:<ID>, 见 <ID>, nor 本机/人工 evidence: ${verification}`);
        }
        for (const id of [...referenced, ...forwarded]) {
            if (id !== row.id && !matrixText.includes(`| ${id} |`)) {
                failures.push(`验证方式 references unknown capability id ${id}`);
            }
        }
    }
    return { id: row.id, line: row.line, section: row.section, anchors, probes: probeCount, failures };
}

/**
 * @param {{ text: string }} options
 * @returns {{ rows: RowResult[] }}
 */
function runSuite(matrixText) {
    const rows = parseMatrix(matrixText);
    const seen = new Set();
    const results = [];
    for (const row of rows) {
        if (seen.has(row.id)) results.push({ id: row.id, line: row.line, section: row.section, anchors: 0, probes: 0, failures: [`duplicate capability id ${row.id}`] });
        seen.add(row.id);
        results.push(runRow(row, matrixText));
    }
    return { rows: results };
}

// --------------------------------------------------------------------------
// Entry point
// --------------------------------------------------------------------------

const argv = process.argv.slice(2);
const jsonMode = argv.includes('--json');
const summaryOnly = argv.includes('--summary');
const only = argv.find((value) => value.startsWith('--only='))?.slice('--only='.length).split(',').filter(Boolean);
const scan = argv.find((value) => value.startsWith('--scan='))?.slice('--scan='.length).split(',').filter(Boolean);

// Ad-hoc privacy scan: `--scan=docs,lib,scripts` or `--scan=repo`.
// `repo` scans exactly what would be published (tracked + untracked, not
// ignored) and refuses to report a green on an empty scope.
if (scan) {
    console.log(scannerSelfCheck());
    const terms = redactionTerms();
    const release = gitReleaseFiles();
    const scopeProblems = release.ok ? releaseScopeProblems(release.files) : [`git scope unavailable: ${release.detail}`];
    console.log(`scan: scope=[${scan.join(', ')}], term source=${terms.source}, ${terms.terms.length} term(s), ${terms.shapes.length} shape rule(s)`);
    let scanned = 0;
    const hits = [];
    if (scan.includes('repo')) {
        console.log(`scan: release scope: ${release.files.length} file(s) — ${release.detail}`);
        for (const problem of scopeProblems) console.error(`scan: SCOPE PROBLEM: ${problem}`);
        for (const file of release.files) {
            const result = scanTarget(file);
            scanned += result.scanned;
            hits.push(...result.hits);
        }
    }
    for (const target of scan.filter((value) => value !== 'repo')) {
        const result = scanTarget(target);
        scanned += result.scanned;
        hits.push(...result.hits);
    }
    for (const hit of hits) console.log(`  ${hit}`);
    console.log(`scan: ${scanned} file(s) scanned, ${hits.length} hit(s)`);
    const failed = hits.length > 0 || scopeProblems.length > 0;
    if (failed && scopeProblems.length > 0) console.error('scan: FAILED — the scan scope is not trustworthy, a green here would be meaningless');
    process.exit(failed ? 1 : 0);
}

const matrixText = read(MATRIX);
if (matrixText === null) {
    console.error(`parity: ${MATRIX} is missing`);
    process.exit(1);
}
if (!jsonMode) {
    console.log(harnessSelfTest());
    console.log(scannerSelfCheck());
}
const release = gitReleaseFiles();
const scopeProblems = release.ok ? releaseScopeProblems(release.files) : [`git scope unavailable: ${release.detail}`];
if (!jsonMode) {
    console.log(`release-scope: ${release.files.length} file(s) — ${release.detail}`);
    for (const problem of scopeProblems) console.error(`release-scope: SCOPE PROBLEM: ${problem}`);
}
const { rows } = runSuite(matrixText);
const selected = only ? rows.filter((row) => only.includes(row.id)) : rows;
const failed = selected.filter((row) => row.failures.length > 0);

if (jsonMode) {
    const sections = {};
    for (const row of selected) {
        sections[row.section] ??= { rows: 0, failed: 0 };
        sections[row.section].rows += 1;
        if (row.failures.length > 0) sections[row.section].failed += 1;
    }
    console.log(JSON.stringify({
        matrix: MATRIX,
        rows: selected.length,
        failed: failed.length,
        sections,
        failures: failed.map((row) => ({ id: row.id, line: row.line, failures: row.failures })),
    }, null, 2));
} else {
    const sections = new Map();
    for (const row of selected) {
        if (!sections.has(row.section)) sections.set(row.section, []);
        sections.get(row.section).push(row);
    }
    if (!summaryOnly) {
        for (const [section, sectionRows] of sections) {
            for (const row of sectionRows) {
                const status = row.failures.length === 0 ? 'ok  ' : 'FAIL';
                console.log(`${status} ${row.id}  ${row.anchors} anchor(s), ${row.probes} probe(s)`);
            }
            const bad = sectionRows.filter((row) => row.failures.length > 0).length;
            console.log(`--- ${section}: ${sectionRows.length - bad}/${sectionRows.length} rows ok`);
        }
    }
    for (const row of failed) {
        console.error(`\nFAIL ${row.id} (${MATRIX}:${row.line})`);
        for (const message of row.failures) console.error(`     - ${message}`);
    }
    console.log(`\nparity: ${selected.length - failed.length}/${selected.length} rows asserted, ${failed.length} failing`);
    for (const [section, sectionRows] of sections) {
        const bad = sectionRows.filter((row) => row.failures.length > 0).length;
        if (bad > 0) console.log(` - ${section}: ${bad} failing`);
    }
}

if (failed.length > 0 || scopeProblems.length > 0) process.exit(1);
