#!/usr/bin/env node
/**
 * Self test for @brainzombie/dsh-restart-win.
 *
 * Runs on plain Node: no DSH install, no session history, and — for most of the
 * suite — no PowerShell. The two integration checks that do need a PowerShell
 * host create a **fake** engine script that only echoes its bound parameters, so
 * the real restart engine is never involved.
 *
 * What this proves:
 *   - CONTRACT §4 defaults and fail-closed validation, including injection
 *     attempts on profile / port / paths / reason / session;
 *   - the exact argv array the engine receives (a fake `-File` target, no shell
 *     string anywhere);
 *   - detached execution: delay, launch record, `-ResultFile` readback and the
 *     ok / failed / running / unknown state machine;
 *   - the four tool definitions load and behave in a host-free process.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
    ACTIONS,
    ConfigError,
    DEFAULTS,
    HOST_KINDS,
    TOOL_FLAGS,
    assertActionRequirements,
    normalizeConfig,
    normalizeSessionId,
    resolveInvocation,
} from '../lib/config.js';
import { parseLaunchRequest, settleNotice, waitForEngineRecord, writeHandoff, writeNoticeFile } from '../lib/delayed-spawn.mjs';
import { loadHostModule, hostModuleCandidates } from '../lib/host.js';
import { ROUTE, createApi, isSameOrigin } from '../lib/api.js';
import {
    engineScriptPath,
    findExecutable,
    isFile,
    launcherScriptPath,
    resolveDshHome,
    resolvePwsh,
    resolveStateDir,
} from '../lib/paths.js';
import {
    ACTION_SWITCHES,
    DETACHED_ACTIONS,
    INJECT_HOST_ENV_KEY,
    buildArgv,
    buildScriptArgs,
    engineEnv,
    evaluateResultFile,
    extractJsonObject,
    isProcessAlive,
    newRunId,
    readRunState,
    RUN_ID_RE,
    runFilePaths,
    runForeground,
    spawnLauncher,
    writeJsonAtomic,
    writeLaunchRequest,
} from '../lib/runner.js';
import { createToolDefinitions, TOOL_NAMES, pendingNoticePath, writePendingNotice } from '../lib/tools.js';
import { createInstallToolDefinitions, INSTALL_ACTIONS } from '../lib/install-tools.js';
import * as pluginEntry from '../lib/index.js';

const ROOT = mkdtempSync(join(tmpdir(), 'dsh-restart-win-selftest-'));
const cases = [];

// The supervisor prefers the shell handoff (`explorer.exe <vbs>`) so the engine
// survives the `taskkill /T` it runs on the host. These tests drive the
// supervisor directly and expect the engine to be its own child, so they pin
// the in-tree path; the handoff's wait-for-record logic has its own unit test.
process.env.DSH_RESTART_HANDOFF = '0';

/**
 * The platform whose *semantics* the suite is exercising.
 *
 * `process.platform` by default; `DSH_RESTART_TEST_PLATFORM=linux` lets a
 * Windows machine (and CI) verify the Linux branch of the suite. Tests that
 * depend on Windows semantics skip themselves with an explicit reason instead
 * of being dropped: a skipped test is visible, a missing one is not.
 */
const PLATFORM = process.env.DSH_RESTART_TEST_PLATFORM || process.platform;

/** @param {string} name @param {() => void | Promise<void>} fn */
function test(name, fn) {
    cases.push({ name, fn });
}

/** @param {string} name @param {string} reason */
function skip(name, reason) {
    cases.push({ name, fn: () => 'skip', reason });
}

/**
 * Register a test only when the platform semantics it exercises apply.
 *
 * The skip is decided at registration time, so the case count stays honest: a
 * platform-gated test is exactly one case, either run or visibly skipped.
 *
 * @param {boolean} condition true to run the test
 * @param {string} name @param {string} reason @param {() => void | Promise<void>} fn
 */
function testUnless(condition, name, reason, fn) {
    if (condition) test(name, fn);
    else skip(name, reason);
}

/** @param {string} name @returns {string} */
function tempDir(name) {
    const dir = join(ROOT, name);
    mkdirSync(dir, { recursive: true });
    return dir;
}

/** @param {() => boolean} predicate @param {number} timeoutMs */
async function waitFor(predicate, timeoutMs = 15000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (predicate()) return true;
        await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    }
    return false;
}

/**
 * The supervisor settles the resume notice and writes its terminal record right
 * after the engine exits — a hair after the engine writes its result file. Wait
 * for that record before asserting on post-run artifacts.
 *
 * @param {string} stateDir
 * @param {string} runId
 * @param {number} [timeoutMs]
 */
async function waitForLaunchFinished(stateDir, runId, timeoutMs = 30000) {
    return waitFor(() => {
        try {
            const doc = JSON.parse(readFileSync(join(stateDir, 'runs', `${runId}.launch.json`), 'utf8'));
            return doc.phase === 'finished';
        } catch {
            return false;
        }
    }, timeoutMs);
}

// --------------------------------------------------------------------------
// CONTRACT §4: configuration
// --------------------------------------------------------------------------

test('defaults match CONTRACT §4 exactly', () => {
    assert.deepEqual(DEFAULTS, {
        profile: 'web',
        hostKind: 'auto',
        port: 3080,
        bindHost: '127.0.0.1',
        dshHome: '',
        stateDir: '',
        taskName: 'DSH Restart',
        pwshPath: '',
        readySec: 90,
        verifyReadySec: 150,
        graceSec: 3,
        portFreeSec: 30,
        restartDelayMs: 1500,
        toolTimeoutMs: 30000,
        verifyTimeoutMs: 600000,
        installTimeoutMs: 900000,
        trustedHosts: [],
        injectHostEnv: true,
        tools: TOOL_FLAGS,
    });
    assert.deepEqual(TOOL_FLAGS, { restart: true, status: true, preflight: true, result: true, install: true });
    assert.ok(Object.isFrozen(DEFAULTS));
});

test('normalizeConfig fills defaults and freezes the result', () => {
    const config = normalizeConfig({});
    assert.equal(config.profile, 'web');
    assert.equal(config.port, 3080);
    assert.equal(config.restartDelayMs, 1500);
    assert.equal(config.tools.result, true);
    assert.ok(Object.isFrozen(config));
    assert.ok(Object.isFrozen(config.tools));
});

test('hostKind: defaults to auto, accepts web/desktop, rejects the rest', () => {
    assert.equal(normalizeConfig({}).hostKind, 'auto');
    assert.equal(normalizeConfig({ hostKind: 'web' }).hostKind, 'web');
    assert.equal(normalizeConfig({ hostKind: 'desktop' }).hostKind, 'desktop');
    assert.deepEqual([...HOST_KINDS], ['auto', 'web', 'desktop']);
    assert.throws(() => normalizeConfig({ hostKind: 'electron' }), (error) => {
        assert.ok(error instanceof ConfigError);
        assert.equal(error.field, 'hostKind');
        assert.match(error.message, /auto, web, desktop/);
        return true;
    });
});

test('hostKind: a per-call override reaches the engine argv', () => {
    const config = normalizeConfig({});
    const invocation = resolveInvocation(config, { hostKind: 'desktop' });
    assert.equal(invocation.hostKind, 'desktop');
    const args = buildScriptArgs({ scriptPath: 'C:\\fake\\engine.ps1', action: 'status', invocation, platform: 'win32' });
    assert.equal(args[args.indexOf('-HostKind') + 1], 'desktop');
    assert.throws(() => resolveInvocation(config, { hostKind: 'bogus' }), /hostKind/);
});

test('normalizeConfig accepts explicit overrides', () => {
    const config = normalizeConfig({
        profile: 'dev-2',
        port: 4123,
        bindHost: 'localhost',
        taskName: 'DSH Restart Dev',
        readySec: 10,
        verifyReadySec: 20,
        graceSec: 0,
        portFreeSec: 5,
        restartDelayMs: 0,
        toolTimeoutMs: 5000,
        verifyTimeoutMs: 60000,
        tools: { restart: false, status: true },
    });
    assert.equal(config.profile, 'dev-2');
    assert.equal(config.port, 4123);
    assert.equal(config.bindHost, 'localhost');
    assert.equal(config.taskName, 'DSH Restart Dev');
    assert.equal(config.tools.restart, false);
    assert.equal(config.tools.result, true);
});

test('normalizeConfig rejects an unknown configuration key', () => {
    assert.throws(() => normalizeConfig({ prot: 3080 }), (error) => error instanceof ConfigError && error.message.includes('prot'));
});

test('normalizeConfig rejects profile injection attempts', () => {
    for (const profile of ['web; calc', 'web -Port 1', '../web', 'web\\x', 'web\n']) {
        assert.throws(
            () => normalizeConfig({ profile }),
            (error) => error instanceof ConfigError && error.message.includes('profile'),
            `profile ${JSON.stringify(profile)} must be rejected`,
        );
    }
});

test('normalizeConfig rejects invalid ports', () => {
    for (const port of [0, 65536, -1, 3080.5, '3080', '3080; calc']) {
        assert.throws(() => normalizeConfig({ port }), (error) => error instanceof ConfigError && error.field === 'port');
    }
});

test('normalizeConfig rejects bindHost injection attempts', () => {
    for (const bindHost of ['127.0.0.1; calc', '127.0.0.1 && echo', '999.1.1.1', 'host name', 'host"x', '[not-ipv6]', '']) {
        assert.throws(
            () => normalizeConfig({ bindHost }),
            (error) => error instanceof ConfigError && error.field === 'bindHost',
            `bindHost ${JSON.stringify(bindHost)} must be rejected`,
        );
    }
});

test('normalizeConfig rejects relative and unsafe paths', () => {
    for (const dshHome of ['relative\\path', '.\\x', 'C:\\bad"path', 'C:\\bad|path', 'C:\\bad\r\npath']) {
        assert.throws(
            () => normalizeConfig({ dshHome }),
            (error) => error instanceof ConfigError && error.field === 'dshHome',
            `dshHome ${JSON.stringify(dshHome)} must be rejected`,
        );
    }
    assert.throws(() => normalizeConfig({ stateDir: 'state' }), (error) => error.field === 'stateDir');
});

test('normalizeConfig rejects a task name that could break schtasks', () => {
    for (const taskName of ['DSH\\Restart', 'DSH Restart"', '-DSH', '', 'DSH/Restart']) {
        assert.throws(
            () => normalizeConfig({ taskName }),
            (error) => error instanceof ConfigError && error.field === 'taskName',
            `taskName ${JSON.stringify(taskName)} must be rejected`,
        );
    }
});

testUnless(
    PLATFORM === 'win32',
    'normalizeConfig rejects non-executable pwshPath values',
    'windows-only: pwshPath must be an absolute .exe path (Windows executable policy)',
    () => {
        assert.throws(() => normalizeConfig({ pwshPath: 'C:\\apps\\pwsh' }), (error) => error.field === 'pwshPath');
        assert.throws(() => normalizeConfig({ pwshPath: 'pwsh.exe' }), (error) => error.field === 'pwshPath');
    },
);

test('injectHostEnv defaults to true and is validated as a boolean', () => {
    assert.equal(normalizeConfig({}).injectHostEnv, true);
    assert.equal(normalizeConfig({ injectHostEnv: false }).injectHostEnv, false);
    for (const value of ['0', 'false', 0, 1, 'yes']) {
        assert.throws(
            () => normalizeConfig({ injectHostEnv: value }),
            (error) => error instanceof ConfigError && error.field === 'injectHostEnv',
            `injectHostEnv=${JSON.stringify(value)} must be rejected`,
        );
    }
});

test('normalizeConfig rejects out-of-range timing values', () => {
    for (const [key, value] of [
        ['readySec', 4],
        ['readySec', 3601],
        ['verifyReadySec', '150'],
        ['graceSec', -1],
        ['portFreeSec', 0],
        ['restartDelayMs', 600001],
        ['toolTimeoutMs', 999],
        ['verifyTimeoutMs', 3600001],
    ]) {
        assert.throws(() => normalizeConfig({ [key]: value }), (error) => error instanceof ConfigError, `${key}=${value}`);
    }
});

test('normalizeConfig rejects unknown tool switches and non-boolean values', () => {
    assert.throws(() => normalizeConfig({ tools: { flash: true } }), (error) => error.field === 'tools.flash');
    assert.throws(() => normalizeConfig({ tools: { restart: 'yes' } }), (error) => error.field === 'tools.restart');
});

test('normalizeConfig fails closed on an unset %VAR% placeholder', () => {
    assert.throws(
        () => normalizeConfig({ dshHome: '%DSH_RESTART_WIN_SURELY_UNSET%\\home' }),
        (error) => error instanceof ConfigError && error.message.includes('environment variable'),
    );
});

test('normalizeConfig expands %VAR% and ~', () => {
    process.env.DSH_RESTART_WIN_SELFTEST_VAR = 'C:\\expanded';
    try {
        assert.equal(normalizeConfig({ dshHome: '%DSH_RESTART_WIN_SELFTEST_VAR%\\home' }).dshHome, 'C:\\expanded\\home');
    } finally {
        delete process.env.DSH_RESTART_WIN_SELFTEST_VAR;
    }
    const home = normalizeConfig({ dshHome: '~\\.dsh-alt' }).dshHome;
    assert.ok(!home.startsWith('~'), '~ must be expanded');
    assert.ok(home.endsWith('\\.dsh-alt') || home.endsWith('/.dsh-alt'));
});

// --------------------------------------------------------------------------
// Per-call arguments
// --------------------------------------------------------------------------

test('resolveInvocation inherits config and applies per-call overrides', () => {
    const config = normalizeConfig({ port: 4100, readySec: 30 });
    const invocation = resolveInvocation(config, { port: 5000, waitIdleSec: 12, fast: true, reason: 'unit test' });
    assert.equal(invocation.port, 5000);
    assert.equal(invocation.readySec, 30);
    assert.equal(invocation.waitIdleSec, 12);
    assert.equal(invocation.fast, true);
    assert.equal(invocation.reason, 'unit test');
    assert.equal(invocation.delayMs, 1500);
    assert.equal(invocation.recordCommand, '');
});

test('resolveInvocation rejects an unknown per-call option', () => {
    assert.throws(
        () => resolveInvocation(normalizeConfig({}), { prot: 1 }),
        (error) => error instanceof ConfigError && error.message.includes('prot'),
    );
});

test('resolveInvocation rejects reason and session injection attempts', () => {
    for (const reason of ['line1\r\n-Port 1', 'nul\u0000byte', 'x'.repeat(501)]) {
        assert.throws(() => resolveInvocation(normalizeConfig({}), { reason }), (error) => error.field === 'reason');
    }
    assert.throws(() => resolveInvocation(normalizeConfig({}), { session: 'a b' }), (error) => error.field === 'session');
    assert.throws(() => resolveInvocation(normalizeConfig({}), { session: '-x' }), (error) => error.field === 'session');
});

test('resolveInvocation rejects a path-shaped recordWorkingDirectory', () => {
    assert.throws(
        () => resolveInvocation(normalizeConfig({}), { recordWorkingDirectory: 'C:\\x" & calc' }),
        (error) => error.field === 'recordWorkingDirectory',
    );
});

test('normalizeSessionId strips the session- prefix and keeps a bare id', () => {
    assert.equal(normalizeSessionId('session-4a1b2c3d'), '4a1b2c3d');
    assert.equal(normalizeSessionId('4a1b2c3d'), '4a1b2c3d');
    assert.equal(normalizeSessionId(''), '');
    assert.equal(normalizeSessionId(undefined), '');
});

test('assertActionRequirements enforces record input and known actions', () => {
    const invocation = resolveInvocation(normalizeConfig({}), {});
    assert.throws(() => assertActionRequirements('record', invocation), (error) => error.field === 'recordCommand');
    assert.throws(() => assertActionRequirements('explode', invocation), (error) => error.field === 'action');
    const withCommand = resolveInvocation(normalizeConfig({}), { recordCommand: 'pnpm dsh web' });
    assert.doesNotThrow(() => assertActionRequirements('record', withCommand));
});

test('every accepted action is covered by a legacy switch or is the default restart', () => {
    assert.deepEqual([...ACTIONS].sort(), Object.keys(ACTION_SWITCHES).sort());
    assert.equal(ACTION_SWITCHES.restart, null);
    assert.deepEqual([...DETACHED_ACTIONS].sort(), ['preflight', 'restart', 'start', 'stop', 'verify_only']);
    for (const action of ACTIONS) {
        assert.ok(ACTION_SWITCHES[action] === null || ACTION_SWITCHES[action].startsWith('-'), action);
    }
});

// --------------------------------------------------------------------------
// Paths
// --------------------------------------------------------------------------

testUnless(
    PLATFORM === 'win32',
    'dshHome resolves from config, then $DSH_HOME, then the user profile',
    'windows-only: joins a Windows profile path with backslash separators',
    () => {
        const env = { USERPROFILE: 'C:\\Users\\example', DSH_HOME: 'D:\\dsh' };
        assert.equal(resolveDshHome({ dshHome: '' }, env), 'D:\\dsh');
        assert.equal(resolveDshHome({ dshHome: 'E:\\custom' }, env), 'E:\\custom');
        assert.equal(resolveDshHome({ dshHome: '' }, { USERPROFILE: 'C:\\Users\\example' }), 'C:\\Users\\example\\.dsh');
    },
);

testUnless(
    PLATFORM === 'win32',
    'stateDir defaults to %LOCALAPPDATA%\\dsh-restart',
    'windows-only: %LOCALAPPDATA% fallback with backslash separators',
    () => {
        const env = { LOCALAPPDATA: 'C:\\Users\\example\\AppData\\Local' };
        assert.equal(resolveStateDir({ stateDir: '' }, env), 'C:\\Users\\example\\AppData\\Local\\dsh-restart');
        assert.equal(resolveStateDir({ stateDir: 'E:\\state' }, env), 'E:\\state');
    },
);

test('engine and launcher paths are derived from the package, not hardcoded', () => {
    assert.ok(engineScriptPath().endsWith(join('scripts', 'dsh-restart.ps1')));
    assert.ok(launcherScriptPath().endsWith(join('lib', 'delayed-spawn.mjs')));
    assert.ok(isFile(launcherScriptPath()), 'the launcher file must exist');
});

test('detached: the handoff script fails silently instead of showing a dialog', () => {
    const dir = tempDir('handoff-script');
    const runId = '20261115-000000-abcdef';
    const handoff = writeHandoff(
        {
            runId,
            runDir: dir,
            execPath: 'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
            args: ['-File', 'C:\\path with space\\engine.ps1', '-Json'],
            notice: null,
            engineEnv: null,
        },
        join(dir, `${runId}.launch.json`),
        null,
    );
    assert.equal(handoff.ok, true, 'the handoff script must be written');
    const head = readFileSync(handoff.vbsPath).subarray(0, 2);
    assert.deepEqual([...head], [0xff, 0xfe], 'the script must start with a UTF-16LE BOM or WScript decodes it as ANSI');
    const text = readFileSync(handoff.vbsPath, 'utf16le').replace(/^\uFEFF/, '');
    assert.match(text, /^On Error Resume Next\r\n/, 'WScript must not raise a modal dialog');
    assert.match(text, /pwsh\.exe/, 'the command line must be present');
    assert.ok(text.includes('sh.Run "'), 'the script must call WScript.Shell.Run');
    assert.ok(
        text.includes('"C:\\path with space\\engine.ps1"'),
        `arguments with spaces stay quoted; got: ${text.split('\r\n')[2] ?? ''}`,
    );
});

test('detached: the supervisor waits for the engine launch record after a handoff', async () => {
    const dir = tempDir('handoff-record');
    const file = join(dir, 'launch.json');
    writeFileSync(file, JSON.stringify({ phase: 'handoff', enginePid: null, error: null }));
    assert.equal(await waitForEngineRecord(file, 300), false, 'a handoff record alone must time out');

    const pending = waitForEngineRecord(file, 5000);
    await new Promise((resolve) => setTimeout(resolve, 200));
    writeFileSync(file, JSON.stringify({ phase: 'engine-running', enginePid: 1234, via: 'handoff' }));
    assert.equal(await pending, true, 'the engine record must end the wait');
});

test('findExecutable scans PATH for a real executable', () => {
    const dir = tempDir('path-probe');
    const name = process.platform === 'win32' ? 'fake-tool.exe' : 'fake-tool';
    writeFileSync(join(dir, name), '');
    const found = findExecutable(process.platform === 'win32' ? 'fake-tool' : 'fake-tool', {
        env: { PATH: `${dir}${process.platform === 'win32' ? ';' : ':'}${process.env.PATH ?? ''}` },
        platform: process.platform,
    });
    assert.ok(found && found.endsWith(name), `expected to find ${name}`);
});

test('resolvePwsh honors pwshPath and rejects a missing one', () => {
    const dir = tempDir('pwsh-probe');
    const fake = join(dir, 'fake-pwsh.exe');
    writeFileSync(fake, '');
    assert.deepEqual(resolvePwsh({ pwshPath: fake }, { env: {}, platform: 'win32' }), { path: fake, source: 'config' });
    assert.throws(
        () => resolvePwsh({ pwshPath: join(dir, 'missing-pwsh.exe') }, { env: {}, platform: 'win32' }),
        /pwshPath does not exist/,
    );
});

test('resolvePwsh prefers pwsh and falls back to powershell.exe', () => {
    const dir = tempDir('pwsh-order');
    writeFileSync(join(dir, 'powershell.exe'), '');
    const fallback = resolvePwsh({ pwshPath: '' }, { env: { PATH: dir }, platform: 'win32' });
    assert.equal(fallback.source, 'powershell');
    assert.ok(fallback.path.endsWith('powershell.exe'));

    writeFileSync(join(dir, 'pwsh.exe'), '');
    const preferred = resolvePwsh({ pwshPath: '' }, { env: { PATH: dir }, platform: 'win32' });
    assert.equal(preferred.source, 'pwsh');
    assert.ok(preferred.path.endsWith('pwsh.exe'));
});

{
    const env = process.env;
    const probe = process.platform === 'win32'
        ? findExecutable('pwsh', { env, platform: process.platform }) ?? findExecutable('powershell', { env, platform: process.platform })
        : findExecutable('pwsh', { env, platform: process.platform });
    if (probe) {
        test('resolvePwsh finds a real PowerShell on this machine', () => {
            const resolved = resolvePwsh({ pwshPath: '' }, { env, platform: process.platform });
            assert.ok(isFile(resolved.path));
            assert.ok(['pwsh', 'powershell'].includes(resolved.source));
        });
    } else {
        skip('resolvePwsh finds a real PowerShell on this machine', 'no PowerShell on PATH');
    }
}

test('host loader: a pnpm store entry outranks the global CLI tree', () => {
    const dshHome = tempDir('host-home');
    const store = join(dshHome, 'profiles', 'web', 'node_modules', '.pnpm');
    const entry = '@deepseek-ai+dsh-tools@1.2.3';
    mkdirSync(join(store, entry, 'node_modules', '@deepseek-ai', 'dsh-tools', 'lib'), { recursive: true });
    writeFileSync(join(store, entry, 'node_modules', '@deepseek-ai', 'dsh-tools', 'lib', 'index.js'), 'export const x = 1;\n');
    const candidates = hostModuleCandidates('@deepseek-ai/dsh-tools', {
        env: { DSH_HOME: dshHome, USERPROFILE: 'C:\\Users\\example' },
        profile: 'web',
    });
    const storeIndex = candidates.findIndex((candidate) => candidate.includes('dsh-tools@1.2.3'));
    assert.ok(storeIndex > 0, 'the pnpm store entry must be a candidate');
    const globalIndex = candidates.findIndex((candidate) => candidate.includes('AppData/Roaming/npm'));
    assert.ok(globalIndex === -1 || storeIndex < globalIndex, 'the profile store must win over the global CLI tree');
});

test('panel API: status / action / result / history go through the tool definitions', async () => {
    const stateDir = tempDir('panel-api');
    writeFileSync(join(stateDir, 'restart-history.jsonl'), [
        JSON.stringify({ ts: '2026-01-01T00:00:00.000Z', result: 'restarted-ok', rc: 0, host_kind: 'desktop', resolved_port: 4123, new_pid: 99, main_pid: 42 }),
        JSON.stringify({ ts: '2026-01-02T00:00:00.000Z', result: 'aborted', rc: 1, host_kind: 'desktop', resolved_port: 5000, new_pid: null, main_pid: 43 }),
        '',
    ].join('\n'));
    const calls = [];
    const tools = [
        { name: 'win_restart_status', execute: async () => { calls.push(['status']); return { ok: true, state: 'ok', status: { hostKind: 'desktop', port: 4123 } }; } },
        { name: 'win_restart', execute: async (args) => { calls.push(['restart', args]); return { ok: true, state: 'running', runId: 'r-1', action: args.action }; } },
        { name: 'win_restart_result', execute: async (args) => { calls.push(['result', args]); return { ok: true, state: 'ok', runId: args.runId }; } },
    ];
    const api = createApi({ config: normalizeConfig({ profile: 'desktop' }), paths: { stateDir, dshHome: stateDir }, tools, version: '9.9.9' });
    const base = 'http://127.0.0.1' + ROUTE;

    const status = await api.dispatch({ method: 'GET', url: new URL(base + '/api/status'), body: {} });
    assert.equal(status.status.port, 4123);
    assert.deepEqual(calls[0], ['status']);

    const meta = await api.dispatch({ method: 'GET', url: new URL(base + '/api/meta'), body: {} });
    assert.equal(meta.version, '9.9.9');
    assert.equal(meta.hostKind, 'auto');

    const started = await api.dispatch({ method: 'POST', url: new URL(base + '/api/action'), body: { action: 'restart' } });
    assert.equal(started.runId, 'r-1');
    assert.equal(calls[1][1].action, 'restart');

    const result = await api.dispatch({ method: 'GET', url: new URL(base + '/api/result?runId=r-1&waitMs=1000'), body: {} });
    assert.equal(result.runId, 'r-1');
    assert.equal(calls[2][1].waitMs, 1000);

    const history = await api.dispatch({ method: 'GET', url: new URL(base + '/api/history?limit=2'), body: {} });
    assert.equal(history.entries.length, 2);
    assert.equal(history.entries[0].result, 'aborted', 'newest first');
    assert.equal(history.entries[1].port, 4123);

    await assert.rejects(
        () => api.dispatch({ method: 'POST', url: new URL(base + '/api/action'), body: { action: 'record' } }),
        (error) => error.status === 400,
    );
    await assert.rejects(
        () => api.dispatch({ method: 'GET', url: new URL(base + '/api/nope'), body: {} }),
        (error) => error.status === 404,
    );
});

test('panel API: same-origin guard accepts the app origins and rejects the web', () => {
    const loopback = '127.0.0.1:4123';
    assert.equal(isSameOrigin({ method: 'GET', headers: { host: loopback } }), true);
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: loopback } }), true);
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: loopback, origin: 'http://127.0.0.1:4123' } }), true);
    // The desktop shell renders from dsh-app://, so its fetches carry an opaque origin.
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: loopback, origin: 'null' } }), true);
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: loopback, origin: 'dsh-app://dsh' } }), true);
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: loopback, origin: 'https://evil.example' } }), false);
    assert.equal(isSameOrigin({ method: 'POST', headers: {} }), false, 'no Host header is never same-origin');
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: 'evil.example', origin: 'https://evil.example' } }), false);
});

test('panel API: same-origin guard honours trusted hosts for reverse-proxied origins', () => {
    const tailnet = 'desktop-demo.tail0demo.ts.net';
    const trusted = ['desktop-demo.tail0demo.ts.net'];
    const wildcard = ['*.ts.net'];
    const req = (origin) => ({ method: 'POST', headers: { host: tailnet, origin } });
    // The Host is no longer loopback, so without a trusted entry every call is refused.
    assert.equal(isSameOrigin(req(`https://${tailnet}`)), false);
    assert.equal(isSameOrigin(req(`https://${tailnet}`), trusted), true);
    assert.equal(isSameOrigin(req(`https://${tailnet}`), wildcard), true);
    assert.equal(isSameOrigin({ method: 'GET', headers: { host: tailnet } }, trusted), true);
    // A Host with an explicit port still matches on the hostname.
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: `${tailnet}:443`, origin: `https://${tailnet}` } }, trusted), true);
    // Trusting the tailnet name must not trust a look-alike or another origin.
    assert.equal(isSameOrigin(req('https://evil.ts.net.example'), trusted), false);
    assert.equal(isSameOrigin(req('https://evil.example'), trusted), false);
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: 'evil.ts.net', origin: 'https://evil.ts.net' } }, wildcard), true);
    assert.equal(isSameOrigin({ method: 'POST', headers: { host: 'ts.net', origin: 'https://ts.net' } }, wildcard), false, 'wildcard needs a label before the suffix');
    // A proxy may forward the original authority; match it when the browser sends it as Origin.
    assert.equal(
        isSameOrigin({ method: 'POST', headers: { host: tailnet, origin: `https://${tailnet}`, 'x-forwarded-host': tailnet } }, trusted),
        true,
    );
});

test('client bundle: registers a sidebar tab and survives a host-free load', () => {
    const root = dirname(dirname(fileURLToPath(import.meta.url)));
    const source = readFileSync(join(root, 'client.js'), 'utf8');
    let loaded = null;
    const fakeWindow = { __ModuleLoader__: { load: (module) => { loaded = module; } } };
    const fakeStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };
    new Function('window', 'localStorage', 'fetch', 'navigator', source)(fakeWindow, fakeStorage, () => Promise.resolve({ json: () => Promise.resolve({}) }), { clipboard: { writeText: () => {} } });
    assert.equal(loaded.id, '@brainzombie/dsh-restart-win', 'the bundle id must be the package name');
    const fakeReact = {
        createElement: () => ({}),
        useState: (value) => [value, () => {}],
        useEffect: () => {},
        useCallback: (fn) => fn,
        useRef: (value) => ({ current: value }),
        Component: class { constructor(props) { this.props = props } },
    };
    const moduleExports = loaded.factory((name) => (name === 'react' ? fakeReact : {}));
    assert.ok(moduleExports.inject.includes('slots'));
    assert.ok(moduleExports.inject.includes('sidebarRightTabs'));
    const seen = [];
    const ctx = {
        effect: (fn) => { seen.push(fn()); },
        sidebarRightTabs: { register: (def) => { seen.push(def); return () => {}; } },
        slots: {
            inject: (name, fn) => { seen.push(name); return fn(); },
            register: (key) => { seen.push(key); return () => {}; },
        },
    };
    moduleExports.apply(ctx);
    assert.ok(seen.some((entry) => entry && entry.id === 'dsh-restart-win'), 'tab definition registered');
    assert.ok(seen.includes('sidebar.right.pane.tab'));
    assert.ok(seen.includes('sidebar.right.pane.tab.title'));
});

test('manifest: the client half is declared for the host', () => {
    const root = dirname(dirname(fileURLToPath(import.meta.url)));
    const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
    assert.equal(pkg.exports['./client'], './client.js');
    assert.ok(pkg.files.includes('client.js'));
    assert.equal(pkg.dsh.client.platform, 'web');
    assert.deepEqual(pkg.dsh.client.inject, ['@deepseek-ai/dsh-client-ui-layout', '@deepseek-ai/dsh-client-ui-sidebar']);
});

test('host loader: an unresolvable host package reports every candidate', async () => {
    await assert.rejects(
        () => loadHostModule('@dsh-restart-win-selftest/no-such-package', { env: { DSH_HOME: tempDir('host-empty') } }),
        /cannot resolve host package .*no-such-package/s,
    );
});

// --------------------------------------------------------------------------
// argv
// --------------------------------------------------------------------------

test('argv: restart with a fake -File target, no shell string anywhere', () => {
    const invocation = resolveInvocation(normalizeConfig({}), {
        fast: true,
        forceUnverified: true,
        waitIdleSec: 5,
        session: 'session-abc123',
        reason: 'unit-test',
    });
    const scriptPath = 'C:\\fake\\engine.ps1';
    const args = buildScriptArgs({ scriptPath, action: 'restart', invocation, platform: 'win32' });
    assert.deepEqual(args, [
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', scriptPath,
        '-Json',
        '-Profile', 'web',
        '-HostKind', 'auto',
        '-Port', '3080',
        '-BindHost', '127.0.0.1',
        '-TaskName', 'DSH Restart',
        '-ReadySec', '90',
        '-VerifyReadySec', '150',
        '-GraceSec', '3',
        '-PortFreeSec', '30',
        '-WaitIdleSec', '5',
        '-IdleMaxSec', '300',
        '-Session', 'abc123',
        '-Reason', 'unit-test',
        '-Fast',
        '-ForceUnverified',
    ]);
    assert.ok(args.every((element) => typeof element === 'string'));
    assert.ok(!args.some((element) => element.includes(' -Port ')), 'flags must be separate argv elements');
    assert.equal(args[args.indexOf('-Port') + 1], '3080', 'the port must be one discrete token');
});

test('argv: every action maps to exactly one legacy switch', () => {
    const invocation = resolveInvocation(normalizeConfig({}), {});
    for (const [action, expected] of Object.entries(ACTION_SWITCHES)) {
        const args = buildScriptArgs({ scriptPath: 'C:\\fake\\engine.ps1', action, invocation, platform: 'win32' });
        const switches = args.filter((element) => ['-Start', '-Stop', '-Status', '-DryRun', '-Record', '-RegisterTask', '-UnregisterTask', '-Preflight', '-VerifyOnly'].includes(element));
        assert.deepEqual(switches, expected === null ? [] : [expected], `action ${action}`);
        assert.ok(args.includes('-Json'), `action ${action} must request JSON`);
    }
});

test('argv: detached runs pass -ResultFile and -NoWait, foreground runs do not', () => {
    const invocation = resolveInvocation(normalizeConfig({}), { forceUnverified: true, viaTask: true, tryCtrlC: true });
    const detached = buildScriptArgs({
        scriptPath: 'C:\\fake\\engine.ps1',
        action: 'stop',
        invocation,
        resultFile: 'C:\\state\\runs\\20260101-000000-abcdef.result.json',
        noWait: true,
        platform: 'win32',
    });
    assert.ok(detached.includes('-Stop'));
    assert.ok(detached.includes('-ResultFile'));
    assert.equal(detached[detached.indexOf('-ResultFile') + 1], 'C:\\state\\runs\\20260101-000000-abcdef.result.json');
    assert.ok(detached.includes('-NoWait'));
    assert.ok(detached.includes('-ForceUnverified'));
    assert.ok(detached.includes('-ViaTask'));
    assert.ok(detached.includes('-TryCtrlC'));

    const foreground = buildScriptArgs({ scriptPath: 'C:\\fake\\engine.ps1', action: 'status', invocation, platform: 'win32' });
    assert.ok(!foreground.includes('-ResultFile'));
    assert.ok(!foreground.includes('-NoWait'));
});

test('argv: empty dshHome/stateDir are omitted so the engine keeps its own defaults', () => {
    const invocation = resolveInvocation(normalizeConfig({}), {});
    const args = buildScriptArgs({ scriptPath: 'C:\\fake\\engine.ps1', action: 'restart', invocation, platform: 'win32' });
    assert.ok(!args.includes('-DshHome'));
    assert.ok(!args.includes('-StateDir'));
    const explicit = resolveInvocation(normalizeConfig({ dshHome: 'D:\\dsh', stateDir: 'E:\\state' }), {});
    const explicitArgs = buildScriptArgs({ scriptPath: 'C:\\fake\\engine.ps1', action: 'restart', invocation: explicit, platform: 'win32' });
    assert.equal(explicitArgs[explicitArgs.indexOf('-DshHome') + 1], 'D:\\dsh');
    assert.equal(explicitArgs[explicitArgs.indexOf('-StateDir') + 1], 'E:\\state');
});

test('argv: record passes the launch command only for action=record', () => {
    const invocation = resolveInvocation(normalizeConfig({}), {
        recordCommand: 'pnpm dsh web --port 3080',
        recordWorkingDirectory: 'C:\\work',
    });
    const recordArgs = buildScriptArgs({ scriptPath: 'C:\\fake\\engine.ps1', action: 'record', invocation, platform: 'win32' });
    assert.ok(recordArgs.includes('-Record'));
    assert.equal(recordArgs[recordArgs.indexOf('-RecordCommand') + 1], 'pnpm dsh web --port 3080');
    assert.equal(recordArgs[recordArgs.indexOf('-RecordWorkingDirectory') + 1], 'C:\\work');
    const restartArgs = buildScriptArgs({ scriptPath: 'C:\\fake\\engine.ps1', action: 'restart', invocation, platform: 'win32' });
    assert.ok(!restartArgs.includes('-RecordCommand'));
});

test('argv: buildArgv prepends exactly one executable', () => {
    const invocation = resolveInvocation(normalizeConfig({}), {});
    const argv = buildArgv({
        execPath: 'C:\\fake\\pwsh.exe',
        scriptPath: 'C:\\fake\\engine.ps1',
        action: 'status',
        invocation,
        platform: 'win32',
    });
    assert.equal(argv[0], 'C:\\fake\\pwsh.exe');
    assert.equal(argv.filter((element) => element === 'C:\\fake\\pwsh.exe').length, 1);
    assert.equal(argv[argv.indexOf('-File') + 1], 'C:\\fake\\engine.ps1');
});

test('argv: unknown action and empty script path are rejected', () => {
    const invocation = resolveInvocation(normalizeConfig({}), {});
    assert.throws(() => buildScriptArgs({ scriptPath: 'C:\\fake.ps1', action: 'explode', invocation }), (error) => error instanceof ConfigError);
    assert.throws(() => buildScriptArgs({ scriptPath: '', action: 'restart', invocation }), (error) => error instanceof ConfigError);
});

test('engineEnv sets DSH_RESTART_INJECT_HOST_ENV=0 only when disabled', () => {
    assert.equal(INJECT_HOST_ENV_KEY, 'DSH_RESTART_INJECT_HOST_ENV');
    const base = { PATH: 'C:\\bin' };
    assert.equal(engineEnv(base, true), base, 'the default must leave the environment object untouched');
    assert.equal(engineEnv(base).DSH_RESTART_INJECT_HOST_ENV, undefined);
    const disabled = engineEnv(base, false);
    assert.equal(disabled.DSH_RESTART_INJECT_HOST_ENV, '0');
    assert.equal(disabled.PATH, 'C:\\bin');
    assert.equal(base.DSH_RESTART_INJECT_HOST_ENV, undefined, 'the input env must not be mutated');
});

// --------------------------------------------------------------------------
// Run records and the three-state result reader
// --------------------------------------------------------------------------

test('newRunId is filesystem-safe and matches the reader contract', () => {
    const runId = newRunId();
    assert.match(runId, RUN_ID_RE);
    assert.notEqual(runId, newRunId());
    assert.ok(!runId.includes('/') && !runId.includes('\\'));
});

test('extractJsonObject: plain, polluted and garbage stdout', () => {
    assert.deepEqual(extractJsonObject('{"ok":true}'), { ok: true });
    assert.deepEqual(extractJsonObject('Write-Host "starting"\n{"ok":true,"result":"status"}\n'), { ok: true, result: 'status' });
    assert.deepEqual(extractJsonObject('{"note":"}{"}\n{"ok":true}'), { ok: true });
    assert.equal(extractJsonObject('not json at all'), null);
    assert.equal(extractJsonObject(''), null);
    assert.equal(extractJsonObject('[1,2,3]'), null);
});

test('readRunState: unknown when there is no run record', () => {
    const stateDir = tempDir('runs-unknown');
    const state = readRunState({ stateDir, runId: '20260101-000000-abcdef' });
    assert.equal(state.state, 'unknown');
    assert.equal(state.ok, false);
    assert.match(String(state.error), /no run record/);
});

test('readRunState: invalid run ids never touch the filesystem', () => {
    const state = readRunState({ stateDir: tempDir('runs-bad-id'), runId: '..\\..\\windows\\system32' });
    assert.equal(state.state, 'unknown');
    assert.equal(state.resultFile, '');
});

test('readRunState: running while the launcher or the engine is alive', () => {
    const stateDir = tempDir('runs-running');
    const runId = '20260101-000000-abcdef';
    const files = runFilePaths(stateDir, runId);
    mkdirSync(files.dir, { recursive: true });
    writeJsonAtomic(files.pendingFile, {
        runId,
        action: 'restart',
        startedAt: new Date().toISOString(),
        launcherPid: 111,
    });
    assert.equal(readRunState({ stateDir, runId }, { isAlive: (pid) => pid === 111 }).state, 'running');

    writeJsonAtomic(files.launchFile, { enginePid: 222, error: null });
    const engineAlive = readRunState({ stateDir, runId }, { isAlive: (pid) => pid === 222 });
    assert.equal(engineAlive.state, 'running');
    assert.equal(engineAlive.ok, true);

    const missing = readRunState({ stateDir, runId }, { isAlive: () => false });
    assert.equal(missing.state, 'failed');
    assert.match(String(missing.error), /engine process exited/);
});

test('readRunState: failed when the launcher died before starting the engine', () => {
    const stateDir = tempDir('runs-launcher-died');
    const runId = '20260101-000000-abcdef';
    const files = runFilePaths(stateDir, runId);
    mkdirSync(files.dir, { recursive: true });
    writeJsonAtomic(files.pendingFile, {
        runId,
        action: 'preflight',
        startedAt: new Date(Date.now() - 60000).toISOString(),
        launcherPid: 111,
    });
    const state = readRunState({ stateDir, runId }, { isAlive: () => false });
    assert.equal(state.state, 'failed');
    assert.match(String(state.error), /launcher exited/);
});

test('readRunState: supervisor records decide the verdict, never a silent hang', () => {
    const stateDir = tempDir('runs-supervisor');
    const runId = '20260101-000000-abcdef';
    const files = runFilePaths(stateDir, runId);
    mkdirSync(files.dir, { recursive: true });
    writeJsonAtomic(files.pendingFile, {
        runId,
        action: 'restart',
        startedAt: new Date().toISOString(),
        launcherPid: 111,
    });

    // The supervisor's first record: waiting out restartDelayMs, no engine yet.
    writeJsonAtomic(files.launchFile, { phase: 'delayed', enginePid: null, error: null, delayMs: 1500 });
    assert.equal(readRunState({ stateDir, runId }, { isAlive: (pid) => pid === 111 }).state, 'running');
    const diedInDelay = readRunState({ stateDir, runId }, { isAlive: () => false, now: Date.now() + 60000 });
    assert.equal(diedInDelay.state, 'failed');
    assert.match(String(diedInDelay.error), /before starting the engine/);

    // The supervisor died after spawning the engine and left an error record.
    writeJsonAtomic(files.launchFile, { phase: 'finished', enginePid: 222, error: 'supervisor received SIGTERM', engineExitCode: null });
    const interrupted = readRunState({ stateDir, runId }, { isAlive: () => false });
    assert.equal(interrupted.state, 'failed');
    assert.match(String(interrupted.error), /SIGTERM/);

    // The engine finished without writing a result: the recorded exit code is
    // reported instead of a generic "still running".
    writeJsonAtomic(files.launchFile, { phase: 'finished', enginePid: 222, error: null, engineExitCode: 2 });
    const finished = readRunState({ stateDir, runId }, { isAlive: () => false });
    assert.equal(finished.state, 'failed');
    assert.match(String(finished.error), /exited with code 2/);
});

test('readRunState: ok, failed and unreadable result files', () => {
    const stateDir = tempDir('runs-result');
    const runId = '20260101-000000-abcdef';
    const files = runFilePaths(stateDir, runId);
    mkdirSync(files.dir, { recursive: true });
    writeJsonAtomic(files.pendingFile, {
        runId,
        action: 'restart',
        startedAt: new Date().toISOString(),
        launcherPid: 111,
    });

    writeJsonAtomic(files.resultFile, { ok: true, exitCode: 0, result: 'restarted-ok', steps: [] });
    const ok = readRunState({ stateDir, runId }, { isAlive: () => false });
    assert.equal(ok.state, 'ok');
    assert.equal(ok.ok, true);
    assert.equal(ok.summary, 'restarted-ok');
    assert.equal(ok.exitCode, 0);
    assert.equal(ok.envelope.result, 'restarted-ok');

    writeJsonAtomic(files.resultFile, { ok: false, exitCode: 4, result: 'verify-failed', error: 'deep verify failed' });
    const failed = readRunState({ stateDir, runId }, { isAlive: () => false });
    assert.equal(failed.state, 'failed');
    assert.equal(failed.exitCode, 4);
    assert.equal(failed.summary, 'verify-failed');
    assert.equal(failed.error, 'deep verify failed');

    writeFileSync(files.resultFile, 'not json');
    const unreadable = readRunState({ stateDir, runId }, { isAlive: () => false });
    assert.equal(unreadable.state, 'failed');
    assert.match(String(unreadable.error), /unreadable/);
});

test('evaluateResultFile reports a missing file without inventing a state', () => {
    const evaluated = evaluateResultFile(join(tempDir('runs-eval'), 'nothing.result.json'));
    assert.equal(evaluated.exists, false);
    assert.equal(evaluated.exitCode, null);
});

test('isProcessAlive accepts the current process and rejects nonsense', () => {
    assert.equal(isProcessAlive(process.pid), true);
    assert.equal(isProcessAlive(0), false);
    assert.equal(isProcessAlive(-1), false);
    assert.equal(isProcessAlive('not-a-pid'), false);
});

// --------------------------------------------------------------------------
// Pending notice and launch request
// --------------------------------------------------------------------------

test('pending notice: same location and shape as the engine writes', () => {
    const dshHome = tempDir('notice-home');
    const result = writePendingNotice({ dshHome, sessionId: 'abc123', reason: 'unit test' });
    assert.equal(result.written, true);
    assert.equal(result.path, join(dshHome, '.smart-restart', 'pending-notice.json'));
    const bytes = readFileSync(result.path);
    assert.equal(bytes[0], 0x7b, 'the notice must be UTF-8 without a BOM');
    const parsed = JSON.parse(bytes.toString('utf8'));
    assert.equal(parsed.sessionId, 'abc123');
    assert.equal(parsed.reason, 'unit test');
    assert.match(parsed.when, /^\d{4}-\d{2}-\d{2}T/);
    assert.deepEqual(Object.keys(parsed).sort(), ['reason', 'sessionId', 'when']);
});

test('pending notice: no session id means no file (boot falls back to primary)', () => {
    const dshHome = tempDir('notice-home-empty');
    const result = writePendingNotice({ dshHome, sessionId: '', reason: 'x' });
    assert.equal(result.written, false);
    assert.throws(() => readFileSync(join(dshHome, '.smart-restart', 'pending-notice.json')), /ENOENT/);
});

test('launch request: strict validation of the detached hand-off', () => {
    const request = {
        delayMs: 1500,
        runId: '20260101-000000-abcdef',
        runDir: join(ROOT, 'runs'),
        execPath: 'C:\\fake\\pwsh.exe',
        args: ['-NoProfile', '-File', 'C:\\fake\\engine.ps1', '-Json'],
        cwd: '',
    };
    assert.deepEqual(parseLaunchRequest(request).args, request.args);
    assert.equal(parseLaunchRequest(request).notice, null);
    const withNotice = parseLaunchRequest({
        ...request,
        notice: { path: 'C:\\home\\.smart-restart\\pending-notice.json', sessionId: 'abc123', reason: 'unit test' },
    });
    assert.deepEqual(withNotice.notice, {
        path: 'C:\\home\\.smart-restart\\pending-notice.json',
        sessionId: 'abc123',
        reason: 'unit test',
    });
    assert.throws(() => parseLaunchRequest({ ...request, delayMs: -1 }), /delayMs/);
    assert.throws(() => parseLaunchRequest({ ...request, delayMs: 600001 }), /delayMs/);
    assert.throws(() => parseLaunchRequest({ ...request, runId: '../evil' }), /runId/);
    assert.throws(() => parseLaunchRequest({ ...request, args: [] }), /args/);
    assert.throws(() => parseLaunchRequest({ ...request, args: [1] }), /argument/);
    assert.throws(() => parseLaunchRequest({ ...request, execPath: '' }), /execPath/);
    assert.throws(() => parseLaunchRequest({ ...request, notice: { path: '', sessionId: 'a', reason: '' } }), /notice\.path/);
    assert.throws(() => parseLaunchRequest({ ...request, notice: { path: 'x', sessionId: '', reason: '' } }), /notice\.sessionId/);
});

test('resume notice: ownership is decided by exact bytes', () => {
    const dir = tempDir('notice-bytes');
    const file = join(dir, 'pending-notice.json');

    // 1) The supervisor's own bytes survive -> the engine never committed a
    //    shutdown, so the notice is stale and must be removed.
    const written = writeNoticeFile(file, { sessionId: 'abc123', reason: 'restart [run r1]', when: '2026-01-01T00:00:00.000Z' });
    assert.equal(readFileSync(file, 'utf8'), written);
    assert.equal(settleNotice(file, written), 'deleted-stale');
    assert.throws(() => readFileSync(file), /ENOENT/);

    // 2) The engine overwrote it with its own notice -> keep the engine's.
    const mine = writeNoticeFile(file, { sessionId: 'abc123', reason: 'restart [run r2]', when: '2026-01-01T00:00:00.000Z' });
    writeFileSync(file, `${JSON.stringify({ sessionId: 'abc123', reason: 'engine notice', when: '2026-01-01T00:00:01.000Z' }, null, 2)}\n`);
    assert.equal(settleNotice(file, mine), 'kept-engine-notice');
    assert.ok(readFileSync(file, 'utf8').includes('engine notice'));

    // 3) A consumed or never-written file is not touched.
    assert.equal(settleNotice(file, null), 'not-written');
    assert.equal(settleNotice(join(dir, 'missing.json'), mine), 'absent');
});

test('resume notice: the supervisor tags its write with the run id', () => {
    const dir = tempDir('notice-runid');
    const file = join(dir, 'pending-notice.json');
    const written = writeNoticeFile(file, { sessionId: 'abc123', reason: 'restart [run 20260101-000000-abcdef]', when: 'x' });
    assert.ok(written.includes('[run 20260101-000000-abcdef]'));
    const parsed = JSON.parse(readFileSync(file, 'utf8'));
    assert.equal(parsed.sessionId, 'abc123');
    assert.match(parsed.reason, /\[run 20260101-000000-abcdef\]$/);
});

// --------------------------------------------------------------------------
// Tool definitions (host-free)
// --------------------------------------------------------------------------

const fakePwsh = join(tempDir('fake-pwsh'), 'fake-pwsh.exe');
writeFileSync(fakePwsh, '');

function toolFixture(overrides = {}, configOverrides = {}) {
    const config = normalizeConfig({ pwshPath: fakePwsh, ...configOverrides });
    const paths = {
        dshHome: tempDir('tool-home'),
        stateDir: tempDir('tool-state'),
        engineScript: join(ROOT, 'fake-engine.ps1'),
        launcherScript: launcherScriptPath(),
        ...overrides,
    };
    const definitions = createToolDefinitions({ defineTool: (definition) => definition, config, paths });
    return { config, paths, definitions, byName: new Map(definitions.map((definition) => [definition.name, definition])) };
}

test('tools: four definitions, fixed output schemas, working renderers', () => {
    const { definitions, byName } = toolFixture();
    assert.deepEqual(definitions.map((definition) => definition.name), [
        TOOL_NAMES.restart,
        TOOL_NAMES.status,
        TOOL_NAMES.preflight,
        TOOL_NAMES.result,
    ]);
    for (const definition of definitions) {
        assert.equal(typeof definition.description, 'string');
        assert.equal(typeof definition.execute, 'function');
        assert.equal(typeof definition.timeoutMs, 'number');
        const schema = definition.output.schema;
        assert.equal(schema.type, 'object', `${definition.name} output root`);
        assert.equal(schema.additionalProperties, false, `${definition.name} output must be closed`);
        const requiredKeys = Object.entries(schema.properties)
            .filter(([, node]) => node.required === true)
            .map(([key]) => key);
        assert.ok(requiredKeys.includes('ok'), `${definition.name} must require ok`);
        for (const [key, node] of Object.entries(schema.properties)) {
            assert.ok(node.type !== undefined || node.oneOf !== undefined, `${definition.name}.${key} must declare a type or oneOf`);
        }
        assert.equal(typeof definition.output.render, 'function');
    }
    const restartRender = byName.get(TOOL_NAMES.restart).output.render({}, {
        ok: true, action: 'restart', started: true, state: 'running',
        runId: '20260101-000000-abcdef', resultFile: 'C:\\state\\runs\\x.result.json',
        exitCode: null, summary: null, error: null, delayMs: 1500, detail: null,
    });
    assert.equal(restartRender[0].type, 'text');
    assert.match(restartRender[0].text, /1500 ms/);
    const statusRender = byName.get(TOOL_NAMES.status).output.render({}, {
        ok: true, state: 'ok', status: { http: 'ok', serving: true, instances: [{ pid: 4242 }] },
        hostUrl: 'http://127.0.0.1:3080/', error: null,
    });
    assert.equal(statusRender[0].type, 'text');
    assert.match(statusRender[0].text, /pid 4242/);
    const resultRender = byName.get(TOOL_NAMES.result).output.render({}, {
        ok: true, state: 'ok', runId: '20260101-000000-abcdef', action: 'restart',
        summary: 'restarted-ok', exitCode: 0, error: null, ageMs: 1000,
    });
    assert.match(resultRender[0].text, /restarted-ok/);
});

test('tools: config switches decide which tools exist', () => {
    const { definitions } = toolFixture({}, { tools: { restart: false, status: false, result: false } });
    assert.deepEqual(definitions.map((definition) => definition.name), [TOOL_NAMES.preflight]);
});

test('tools: dry-run and invalid combinations fail closed before anything spawns', async () => {
    const { byName } = toolFixture();
    const restart = byName.get(TOOL_NAMES.restart);
    const dryRunStop = await restart.execute({ action: 'stop', dryRun: true }, {});
    assert.equal(dryRunStop.ok, false);
    assert.equal(dryRunStop.state, 'failed');
    assert.match(dryRunStop.error, /dryRun/);

    const recordWithoutCommand = await restart.execute({ action: 'record' }, {});
    assert.equal(recordWithoutCommand.ok, false);
    assert.match(recordWithoutCommand.error, /recordCommand/);

    const unknownOption = await restart.execute({ action: 'restart', prot: 1 }, {});
    assert.equal(unknownOption.ok, false);
    assert.match(unknownOption.error, /prot/);
});

test('tools: a missing PowerShell fails the call, not the plugin', async () => {
    const missingPwsh = join(ROOT, 'definitely-missing-pwsh.exe');
    const { byName } = toolFixture({}, { pwshPath: missingPwsh });
    const status = await byName.get(TOOL_NAMES.status).execute({}, {});
    assert.equal(status.ok, false);
    assert.equal(status.state, 'failed');
    assert.match(String(status.error), /pwshPath does not exist/);
});

testUnless(
    PLATFORM === 'win32',
    'tools: a missing engine script is reported, never silently skipped',
    'windows-only: the tool reports a missing pwsh executable before the engine check, so the assertion only holds on Windows',
    async () => {
        const { byName } = toolFixture({ engineScript: join(ROOT, 'no-such-engine.ps1') });
        const preflight = await byName.get(TOOL_NAMES.preflight).execute({ mode: 'preflight' }, {});
        assert.equal(preflight.ok, false);
        assert.equal(preflight.state, 'failed');
        assert.match(String(preflight.error), /engine script is missing/);
    },
);

test('tools: win_restart_result rejects a resultFile outside stateDir', async () => {
    const stateDir = tempDir('result-outside-state');
    const { byName } = toolFixture({}, { stateDir });
    const result = await byName.get(TOOL_NAMES.result).execute(
        { resultFile: join(ROOT, 'outside.json') },
        {},
    );
    assert.equal(result.state, 'unknown');
    assert.match(String(result.error), /inside stateDir/);
});

testUnless(
    PLATFORM === 'win32',
    'tools: win_restart_result reads a finished run from stateDir',
    'windows-only: run file paths use Windows separators, so the result lookup cannot succeed off-Windows',
    async () => {
        const stateDir = tempDir('result-tool-state');
        const runId = '20260101-000000-abcdef';
        const files = runFilePaths(stateDir, runId);
        mkdirSync(files.dir, { recursive: true });
        writeJsonAtomic(files.pendingFile, { runId, action: 'restart', startedAt: new Date().toISOString() });
        writeJsonAtomic(files.resultFile, { ok: true, exitCode: 0, result: 'restarted-ok' });
        const { byName } = toolFixture({}, { stateDir });
        const result = await byName.get(TOOL_NAMES.result).execute({ runId }, {});
        assert.equal(result.state, 'ok');
        assert.equal(result.ok, true);
        assert.equal(result.summary, 'restarted-ok');
        assert.equal(result.runId, runId);
    },
);

// --------------------------------------------------------------------------
// Plugin entry point
// --------------------------------------------------------------------------

test('host integration: the real defineTool compiles every tool definition', async () => {
    let hostModule;
    try {
        hostModule = await loadHostModule('@deepseek-ai/dsh-tools', { profile: 'web' });
    } catch {
        return 'skip';
    }
    const { defineTool, validateJsonSchemaValue } = hostModule;
    if (typeof defineTool !== 'function') return 'skip';
    assert.equal(typeof validateJsonSchemaValue, 'function');
    const config = normalizeConfig({ pwshPath: fakePwsh });
    const paths = {
        dshHome: tempDir('host-tool-home'),
        stateDir: tempDir('host-tool-state'),
        engineScript: join(ROOT, 'definitely-missing-engine.ps1'),
        launcherScript: launcherScriptPath(),
    };
    const definitions = createToolDefinitions({ defineTool, config, paths });
    assert.equal(definitions.length, 4);
    for (const definition of definitions) {
        // defineTool compiles the author DSL into raw JSON Schema: required
        // becomes an array at the object root, and a `json` node becomes
        // annotation-only (no `type`).
        assert.ok(Array.isArray(definition.output.schema.required), `${definition.name} must compile to a required array`);
        assert.ok(definition.output.schema.required.includes('ok'));
        for (const [key, node] of Object.entries(definition.output.schema.properties)) {
            assert.ok(!('required' in node), `${definition.name}.${key} must not carry an inline required flag after compilation`);
        }
    }

    /** Every returned key must be declared, every required key must be present. */
    const assertOutputShape = (definition, value) => {
        const schema = definition.output.schema;
        for (const key of Object.keys(value)) {
            assert.ok(Object.hasOwn(schema.properties, key), `${definition.name} returned undeclared key "${key}"`);
        }
        for (const key of schema.required) {
            assert.ok(Object.hasOwn(value, key), `${definition.name} is missing required key "${key}"`);
        }
        const violations = validateJsonSchemaValue(schema, value, '');
        assert.deepEqual(violations, [], `${definition.name} value violates its output schema: ${violations.join('; ')}`);
        const rendered = definition.output.render({}, value);
        assert.ok(Array.isArray(rendered) && rendered.length > 0, `${definition.name} render must return content`);
        for (const block of rendered) assert.equal(block.type, 'text');
    };

    const byName = new Map(definitions.map((definition) => [definition.name, definition]));
    assertOutputShape(byName.get(TOOL_NAMES.restart), await byName.get(TOOL_NAMES.restart).execute({ action: 'stop', dryRun: true }, {}));
    assertOutputShape(byName.get(TOOL_NAMES.status), await byName.get(TOOL_NAMES.status).execute({}, {}));
    assertOutputShape(byName.get(TOOL_NAMES.preflight), await byName.get(TOOL_NAMES.preflight).execute({ mode: 'preflight' }, {}));
    assertOutputShape(byName.get(TOOL_NAMES.result), await byName.get(TOOL_NAMES.result).execute({ runId: '20260101-000000-abcdef' }, {}));
});

test('host integration: apply registers the restart tools plus install_plugin and disposes them on unload', async () => {
    const registered = [];
    const disposed = [];
    let unload;
    const ctx = {
        tools: {
            register(definition) {
                registered.push(definition);
                return () => { disposed.push(definition.name); };
            },
        },
        effect(callback) {
            unload = callback();
        },
    };
    try {
        await pluginEntry.apply(ctx, { pwshPath: fakePwsh });
    } catch (error) {
        if (/cannot resolve host package/.test(String(error?.message))) return 'skip';
        throw error;
    }
    assert.deepEqual(registered.map((definition) => definition.name), [
        TOOL_NAMES.restart,
        TOOL_NAMES.status,
        TOOL_NAMES.preflight,
        TOOL_NAMES.result,
        'install_plugin',
    ]);
    assert.equal(typeof unload, 'function');
    unload();
    assert.equal(disposed.length, 5);
});

test('host integration: a webServer mounts the panel API, a host without one still gets the tools', async () => {
    const routes = [];
    const tools = [];
    const withServer = {
        tools: { register(definition) { tools.push(definition); return () => {}; } },
        webServer: {
            register(route) {
                routes.push(route);
                return () => {};
            },
        },
        effect() {},
    };
    try {
        await pluginEntry.apply(withServer, { pwshPath: fakePwsh });
    } catch (error) {
        if (/cannot resolve host package/.test(String(error?.message))) return 'skip';
        throw error;
    }
    assert.equal(tools.length, 5, 'the restart tools plus install_plugin must register with a web server present');
    assert.equal(routes.length, 1, 'the panel API must mount exactly once');
    assert.equal(routes[0].kind, 'prefix');
    assert.match(String(routes[0].path), /dsh-restart-win/);
    assert.equal(typeof routes[0].handler, 'function');

    // No webServer (headless host): the panel is impossible, the tools are not.
    const headlessTools = [];
    const headless = {
        tools: { register(definition) { headlessTools.push(definition); return () => {}; } },
        effect() {},
    };
    await pluginEntry.apply(headless, { pwshPath: fakePwsh });
    assert.equal(headlessTools.length, 5, 'a headless host must still get the restart tools and install_plugin');
});

test('host integration: the panel waits for webServer through ctx.inject', async () => {
    // Real cordis resolves a service only for plugins that asked for it, and
    // `inject` (the module export) makes the whole plugin wait. The panel must
    // therefore be mounted from a child fiber, so a host without a web server
    // still runs `apply`.
    const tools = [];
    const routes = [];
    const deferred = [];
    const ctx = {
        tools: { register(definition) { tools.push(definition); return () => {}; } },
        inject(deps, callback) {
            deferred.push({ deps, callback });
            return { then() {} };
        },
        effect() {},
    };
    try {
        await pluginEntry.apply(ctx, { pwshPath: fakePwsh });
    } catch (error) {
        if (/cannot resolve host package/.test(String(error?.message))) return 'skip';
        throw error;
    }
    assert.equal(tools.length, 5, 'tools register before any web server exists');
    assert.equal(routes.length, 0, 'nothing is mounted until the service appears');
    assert.equal(deferred.length, 1, 'exactly one deferred injection is requested');
    assert.deepEqual(deferred[0].deps, ['webServer']);

    deferred[0].callback({
        webServer: { register(route) { routes.push(route); return () => {}; } },
    });
    assert.equal(routes.length, 1, 'the panel mounts once the web server appears');
    assert.equal(routes[0].kind, 'prefix');
    assert.match(String(routes[0].path), /dsh-restart-win/);
});

test('plugin entry: name, inject and module-level load without the host', () => {
    assert.equal(pluginEntry.name, 'dsh-restart-win');
    // Only `tools` is a hard requirement: a host without a web server (headless)
    // must still get the four tools, just no panel.
    assert.deepEqual(pluginEntry.inject, ['tools']);
    assert.equal(typeof pluginEntry.apply, 'function');
    const source = readFileSync(new URL('../lib/tools.js', import.meta.url), 'utf8');
    assert.ok(!source.includes("from '@deepseek-ai/"), 'lib/tools.js must not import the host package');
});

test('plugin entry: apply rejects invalid config before resolving the host', async () => {
    const ctx = { tools: { register: () => () => {} } };
    await assert.rejects(() => pluginEntry.apply(ctx, { port: 0 }), (error) => error instanceof ConfigError && error.field === 'port');
    await assert.rejects(() => pluginEntry.apply(ctx, { prot: 1 }), (error) => error instanceof ConfigError && error.message.includes('prot'));
});

// --------------------------------------------------------------------------
// install_plugin (host-free)
// --------------------------------------------------------------------------

// `ROOT` above is a throw-away temp directory; the real package lives here.
const PACKAGE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const INSTALL_SCRIPT_PATH = join(PACKAGE_ROOT, 'scripts', 'dsh-plugin-install.ps1');

test('install_plugin: the safe channel is a first-class action set, not a passthrough', () => {
    assert.deepEqual([...INSTALL_ACTIONS], ['status', 'plan', 'install', 'repair_scope', 'check_shadowed']);
    const definitions = createInstallToolDefinitions({
        defineTool: (definition) => definition,
        config: normalizeConfig({ pwshPath: fakePwsh }),
        paths: { installScript: INSTALL_SCRIPT_PATH },
    });
    assert.equal(definitions.length, 1);
    const [tool] = definitions;
    assert.equal(tool.name, 'install_plugin');
    assert.deepEqual(tool.parameters.action.enum, [...INSTALL_ACTIONS]);
    assert.equal(tool.parameters.action.required, true);
    // The whole reason this tool exists must be in the text the model reads.
    assert.match(tool.description, /plugin_manager/);
    assert.match(tool.description, /pnpm/);
    assert.match(tool.description, /-OnDemand|stop the host|stops/i);
});

test('install_plugin: refused without a spec, and a spec cannot look like a switch', async () => {
    const definitions = createInstallToolDefinitions({
        defineTool: (definition) => definition,
        config: normalizeConfig({ pwshPath: fakePwsh }),
        paths: { installScript: INSTALL_SCRIPT_PATH },
    });
    const [tool] = definitions;
    const bare = await tool.execute({ action: 'install' }, {});
    assert.equal(bare.ok, false);
    assert.match(String(bare.error), /spec is required/);
    const dashed = await tool.execute({ action: 'install', spec: '-RepairScope' }, {});
    assert.equal(dashed.ok, false);
    assert.match(String(dashed.error), /must not start with/);
    const unknown = await tool.execute({ action: 'add' }, {});
    assert.equal(unknown.ok, false);
    assert.match(String(unknown.error), /unknown action/);
    // Every refusal still satisfies the declared output shape.
    for (const value of [bare, dashed, unknown]) {
        assert.equal(value.state, 'failed');
        assert.equal(value.action === undefined, false);
    }
});

test('install_plugin: an unnamed profile falls back instead of becoming the string "undefined"', async () => {
    // Regression: `String(config.profile)` on an unset profile produced the
    // literal "undefined", so the engine looked for `<DSH_HOME>/profiles/undefined`
    // and the call failed on a path that cannot exist. A default must be a name.
    const definitions = createInstallToolDefinitions({
        defineTool: (definition) => definition,
        config: normalizeConfig({ pwshPath: fakePwsh }),
        paths: { installScript: INSTALL_SCRIPT_PATH },
    });
    const [tool] = definitions;
    // A profile that is not a directory name is refused before anything runs.
    const invalid = await tool.execute({ action: 'status', profile: '../evil' }, {});
    assert.equal(invalid.ok, false);
    assert.match(String(invalid.error), /invalid profile/);
    const empty = await tool.execute({ action: 'status', profile: '' }, {});
    assert.equal(empty.ok, false);
});

test('install_plugin: a missing script is reported, not thrown', async () => {
    const definitions = createInstallToolDefinitions({
        defineTool: (definition) => definition,
        config: normalizeConfig({ pwshPath: fakePwsh }),
        paths: { installScript: join(PACKAGE_ROOT, 'scripts', 'does-not-exist.ps1') },
    });
    const [tool] = definitions;
    const result = await tool.execute({ action: 'status' }, {});
    assert.equal(result.ok, false);
    assert.match(String(result.error), /install script is missing/);
});

test('install_plugin: tools.install=false removes the tool entirely', () => {
    const definitions = createInstallToolDefinitions({
        defineTool: (definition) => definition,
        config: normalizeConfig({ pwshPath: fakePwsh, tools: { install: false } }),
        paths: { installScript: INSTALL_SCRIPT_PATH },
    });
    assert.deepEqual(definitions, []);
});

test('install_plugin: the script it drives exists and carries -OnDemand', () => {
    const script = readFileSync(INSTALL_SCRIPT_PATH, 'utf8');
    assert.match(script, /\[switch\]\$OnDemand/);
    // -OnDemand must actually skip the gate and both engine calls; a switch that
    // is declared but never read would silently do the unsafe thing.
    assert.match(script, /if \(\$OnDemand\) \{[\s\S]{0,200}跳过闸门/);
    assert.match(script, /if \(-not \$OnDemand\) \{[\s\S]{0,200}& \$script:Engine -Stop/);
    assert.match(script, /if \(-not \$OnDemand\) \{[\s\S]{0,200}& \$script:Engine -Start/);
});

// --------------------------------------------------------------------------
// Repository contract (package.json / cordis.patch.yml / privacy)
// --------------------------------------------------------------------------

test('package.json carries the publish contract and is not private', () => {
    const manifest = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
    assert.equal(manifest.name, '@brainzombie/dsh-restart-win');
    assert.equal(manifest.type, 'module');
    assert.equal(manifest.main, 'lib/index.js');
    assert.equal(manifest.license, 'MIT');
    assert.equal(manifest.private, undefined);
    assert.deepEqual(manifest.publishConfig, { access: 'public' });
    assert.equal(manifest.repository.url, 'git+https://github.com/BrainZombie/dsh-restart-win.git');
    assert.equal(manifest.homepage, 'https://github.com/BrainZombie/dsh-restart-win#readme');
    assert.equal(manifest.bugs.url, 'https://github.com/BrainZombie/dsh-restart-win/issues');
    assert.equal(manifest.dsh.bundle.patch, './cordis.patch.yml');
    assert.equal(typeof manifest.dsh.compatibility.dsh, 'string');
    assert.equal(
        manifest.scripts.test,
        'node test/selftest.mjs && node test/parity.mjs && node test/integration.mjs',
    );
    assert.ok(manifest.engines.node);
    assert.ok(manifest.files.includes('lib'));
    assert.ok(manifest.files.includes('scripts'));
    // The migration guide ships with the package (the README links to it, which
    // offline/mirror readers cannot follow); the development-only parity matrix
    // must not bloat the tarball.
    assert.ok(manifest.files.includes('docs/migration.md'), 'docs/migration.md must ship with the package');
    assert.ok(!manifest.files.includes('docs'), 'the whole docs/ directory must not be published');
    assert.ok(!manifest.files.some((entry) => entry.includes('parity-matrix')), 'parity-matrix.md is development-only');
});

test('cordis.patch.yml inserts the row with every CONTRACT §4 default', () => {
    const text = readFileSync(new URL('../cordis.patch.yml', import.meta.url), 'utf8');
    assert.match(text, /^\s*-\s*id:\s*dsh-restart-win\s*$/m);
    assert.match(text, /^\s*name:\s*'@brainzombie\/dsh-restart-win'\s*$/m);
    const scalars = {};
    let inConfig = false;
    for (const line of text.split(/\r?\n/)) {
        if (/^\s*config:\s*$/.test(line)) {
            inConfig = true;
            continue;
        }
        if (!inConfig) continue;
        if (/^\s*-\s/.test(line)) break;
        const match = line.match(/^ {8}([A-Za-z][A-Za-z0-9]*):\s*(.*)$/);
        if (match) scalars[match[1]] = match[2].replace(/^'(.*)'$/, '$1').replace(/^"(.*)"$/, '$1');
    }
    for (const [key, value] of Object.entries(DEFAULTS)) {
        if (key === 'tools' || Array.isArray(value)) continue;
        assert.ok(Object.hasOwn(scalars, key), `cordis.patch.yml is missing ${key}`);
        assert.equal(scalars[key], String(value), `cordis.patch.yml has the wrong default for ${key}`);
    }
    assert.match(text, /^ {8}trustedHosts: \[\]$/m, 'trustedHosts must default to an empty list');
    for (const tool of Object.keys(TOOL_FLAGS)) {
        assert.match(text, new RegExp(`^ {10}${tool}: true$`, 'm'), `tools.${tool} must default to true`);
    }
});

test('repository files contain no machine-specific identifiers', () => {
    // The needles are the machine's own values, read from the environment at run
    // time — never written into a file. A tracked file that echoed any of them
    // would fail here before it could be published.
    const packageRootPath = fileURLToPath(new URL('..', import.meta.url));
    const machineValues = [
        process.env.USERPROFILE,
        process.env.USERNAME ? `C:\\Users\\${process.env.USERNAME}` : '',
        process.env.COMPUTERNAME,
        process.env.HOSTNAME,
        process.env.DSH_HOME,
        dirname(dirname(packageRootPath)),
    ];
    const needles = [...new Set(machineValues)]
        .filter((value) => typeof value === 'string' && value.trim().length >= 6)
        .map((value) => value.trim().toLowerCase());
    assert.ok(needles.length > 0, 'expected at least one machine-derived needle');
    const files = [
        new URL('../package.json', import.meta.url),
        new URL('../cordis.patch.yml', import.meta.url),
        new URL('./selftest.mjs', import.meta.url),
        ...readdirSync(new URL('../lib', import.meta.url)).map((name) => new URL(`../lib/${name}`, import.meta.url)),
        ...readdirSync(new URL('../bin', import.meta.url)).map((name) => new URL(`../bin/${name}`, import.meta.url)),
    ];
    for (const file of files) {
        const text = readFileSync(file, 'utf8').toLowerCase();
        for (const needle of needles) {
            assert.ok(!text.includes(needle), `${file.pathname} contains the machine value "${needle}"`);
        }
    }
});

// --------------------------------------------------------------------------
// PowerShell integration with a fake engine (never the real engine)
// --------------------------------------------------------------------------

const FAKE_ENGINE = [
    'param(',
    "  [string]$Profile = 'web',",
    '  [int]$Port = 3080,',
    "  [string]$BindHost = '127.0.0.1',",
    "  [string]$DshHome = '',",
    "  [string]$StateDir = '',",
    "  [string]$TaskName = '',",
    '  [int]$ReadySec = 0,',
    '  [int]$VerifyReadySec = 0,',
    '  [int]$GraceSec = 0,',
    '  [int]$PortFreeSec = 0,',
    '  [int]$WaitIdleSec = 0,',
    '  [int]$IdleMaxSec = 0,',
    "  [string]$Session = '',",
    "  [string]$Reason = '',",
    "  [string]$RecordCommand = '',",
    "  [string]$RecordWorkingDirectory = '',",
    "  [string]$VerifyTempRoot = '',",
    "  [string]$ResultFile = '',",
    '  [switch]$Status,',
    '  [switch]$DryRun,',
    '  [switch]$Start,',
    '  [switch]$Stop,',
    '  [switch]$Fast,',
    '  [switch]$ForceUnverified,',
    '  [switch]$VerifyOnly,',
    '  [switch]$Preflight,',
    '  [switch]$Record,',
    '  [switch]$RegisterTask,',
    '  [switch]$UnregisterTask,',
    '  [switch]$TryCtrlC,',
    '  [switch]$ViaTask,',
    '  [switch]$DoNotTouchDshHome,',
    '  [switch]$CleanupOrphans,',
    '  [switch]$Json,',
    '  [switch]$NoWait',
    ')',
    '$bound = @($PSBoundParameters.Keys)',
    '$payload = [ordered]@{',
    "  ok = $true; result = $(if ($Status) { 'status' } else { 'restarted-ok' }); exitCode = 0; version = 'fake-1.0.0'",
    "  steps = @(); warnings = @(); targetPid = $null; newPid = $null; hostUrl = $null; error = $null",
    "  durationMs = 0; stateDir = $StateDir; logPath = ''",
    "  status = [ordered]@{ http = 'ok'; serving = $true; instances = @(@{ pid = 4242; name = 'node' }); launchUrl = 'http://127.0.0.1:3080/?token=fake'; injectHostEnv = [string]$env:DSH_RESTART_INJECT_HOST_ENV }",
    '  fake = [ordered]@{ bound = $bound; profile = $Profile; port = $Port; bindHost = $BindHost; taskName = $TaskName; fast = [bool]$Fast; noWait = [bool]$NoWait; session = $Session; reason = $Reason; waitIdleSec = $WaitIdleSec; injectHostEnv = [string]$env:DSH_RESTART_INJECT_HOST_ENV }',
    '}',
    'if ($ResultFile) { [System.IO.File]::WriteAllText($ResultFile, ($payload | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false))) }',
    "if ($env:FAKE_ENGINE_WRITE_NOTICE -eq '1' -and $Session -and $DshHome) {",
    "  $noticeDir = Join-Path $DshHome '.smart-restart'",
    '  New-Item -ItemType Directory -Force -Path $noticeDir | Out-Null',
    "  $doc = [ordered]@{ sessionId = $Session; reason = 'fake engine notice'; when = (Get-Date).ToString('o') }",
    '  [System.IO.File]::WriteAllText((Join-Path $noticeDir \'pending-notice.json\'), ($doc | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))',
    '}',
    '$payload | ConvertTo-Json -Depth 8 -Compress',
].join('\n');

const pwshForTests = (() => {
    try {
        return resolvePwsh({ pwshPath: '' }, { env: process.env, platform: process.platform });
    } catch {
        return null;
    }
})();

/** Every test in the block below needs a real Windows PowerShell host. */
const PWSH_INTEGRATION_TESTS = Object.freeze([
    'integration: the argv binds in a real PowerShell host',
    'integration: injectHostEnv is applied on the foreground path',
    'integration: injectHostEnv is applied on the detached supervisor path',
    'integration: the calling session id reaches the engine argv explicitly',
    'integration: win_restart returns immediately, then the detached run settles',
    'integration: an engine-written notice survives the supervisor cleanup',
    'integration: a detached run never writes engine stdout into the host stdio',
    'integration: detached launcher runs the engine and writes -ResultFile',
]);

if (PLATFORM !== 'win32') {
    // Running a .ps1 engine through a real PowerShell host is Windows-specific:
    // the argv, the exit codes and the fake engine's own cmdlets all assume it.
    for (const name of PWSH_INTEGRATION_TESTS) {
        skip(name, 'windows-only: runs the fake .ps1 engine through a real PowerShell host');
    }
} else if (!pwshForTests) {
    for (const name of PWSH_INTEGRATION_TESTS) skip(name, 'no PowerShell on PATH');
} else {
    const fakeEnginePath = join(ROOT, 'fake-engine.ps1');
    writeFileSync(fakeEnginePath, FAKE_ENGINE, 'utf8');

    test('integration: the argv binds in a real PowerShell host', async () => {
        const invocation = resolveInvocation(normalizeConfig({}), {
            fast: true,
            forceUnverified: true,
            waitIdleSec: 5,
            reason: 'selftest',
            session: 'session-selftest',
        });
        const args = buildScriptArgs({
            scriptPath: fakeEnginePath,
            action: 'restart',
            invocation,
            platform: process.platform,
        });
        const run = await runForeground({
            execPath: pwshForTests.path,
            args,
            timeoutMs: 60000,
            env: process.env,
        });
        assert.equal(run.exitCode, 0, `pwsh stderr: ${run.stderr}`);
        const envelope = extractJsonObject(run.stdout);
        assert.ok(envelope, `expected a JSON envelope, got: ${run.stdout}`);
        assert.equal(envelope.ok, true);
        assert.equal(envelope.fake.profile, 'web');
        assert.equal(envelope.fake.port, 3080);
        assert.equal(envelope.fake.taskName, 'DSH Restart');
        assert.equal(envelope.fake.fast, true);
        assert.equal(envelope.fake.waitIdleSec, 5);
        assert.equal(envelope.fake.session, 'selftest');
        assert.equal(envelope.fake.reason, 'selftest');
        assert.ok(envelope.fake.bound.includes('Json'));
        assert.ok(envelope.fake.bound.includes('ForceUnverified'));
        assert.ok(envelope.fake.bound.includes('WaitIdleSec'));
        assert.ok(envelope.status && envelope.status.serving === true);
    });

    test('integration: injectHostEnv is applied on the foreground path', async () => {
        const engineScript = join(ROOT, 'fake-engine.ps1');
        const disabledState = tempDir('env-fg-state-off');
        const disabledHome = tempDir('env-fg-home-off');
        const disabled = toolFixture(
            { stateDir: disabledState, dshHome: disabledHome, engineScript },
            { pwshPath: pwshForTests.path, stateDir: disabledState, dshHome: disabledHome, injectHostEnv: false },
        );
        const off = await disabled.byName.get(TOOL_NAMES.status).execute({}, {});
        assert.equal(off.ok, true, `status error: ${off.error}`);
        // The fake engine echoes the variable into its status object; passthrough
        // proves both the env and the untouched status projection.
        assert.equal(off.status.injectHostEnv, '0');

        const enabledState = tempDir('env-fg-state-on');
        const enabledHome = tempDir('env-fg-home-on');
        const enabled = toolFixture(
            { stateDir: enabledState, dshHome: enabledHome, engineScript },
            { pwshPath: pwshForTests.path, stateDir: enabledState, dshHome: enabledHome },
        );
        const on = await enabled.byName.get(TOOL_NAMES.status).execute({}, {});
        assert.equal(on.ok, true, `status error: ${on.error}`);
        assert.equal(on.status.injectHostEnv, '', 'the default must not inject the switch');
    });

    test('integration: injectHostEnv is applied on the detached supervisor path', async () => {
        const engineScript = join(ROOT, 'fake-engine.ps1');
        const runOnce = async (injectHostEnv) => {
            const tag = injectHostEnv ? 'on' : 'off';
            const stateDir = tempDir(`env-det-state-${tag}`);
            const dshHome = tempDir(`env-det-home-${tag}`);
            const { byName } = toolFixture(
                { stateDir, dshHome, engineScript },
                { pwshPath: pwshForTests.path, stateDir, dshHome, injectHostEnv, restartDelayMs: 0 },
            );
            const started = await byName.get(TOOL_NAMES.restart).execute({ action: 'start' }, {});
            assert.equal(started.ok, true, `start error: ${started.error}`);
            const request = JSON.parse(readFileSync(join(stateDir, 'runs', `${started.runId}.request.json`), 'utf8'));
            const settled = await waitFor(
                () => readRunState({ stateDir, runId: started.runId }).state !== 'running',
                30000,
            );
            assert.ok(settled, 'the detached run must settle within 30s');
            const state = readRunState({ stateDir, runId: started.runId });
            assert.equal(state.state, 'ok', `run error: ${state.error}`);
            return { request, state };
        };

        const off = await runOnce(false);
        assert.deepEqual(off.request.engineEnv, { [INJECT_HOST_ENV_KEY]: '0' });
        assert.equal(off.state.envelope.fake.injectHostEnv, '0');

        const on = await runOnce(true);
        assert.equal(on.request.engineEnv, null, 'the default must not record an env override');
        assert.equal(on.state.envelope.fake.injectHostEnv, '');
    });

    test('integration: the calling session id reaches the engine argv explicitly', async () => {
        const stateDir = tempDir('session-argv-state');
        const dshHome = tempDir('session-argv-home');
        const { byName } = toolFixture(
            { stateDir, dshHome, engineScript: join(ROOT, 'fake-engine.ps1') },
            { pwshPath: pwshForTests.path, stateDir, dshHome, restartDelayMs: 0 },
        );
        // No `session` argument: the id must come from the execution context.
        const started = await byName.get(TOOL_NAMES.restart).execute(
            { action: 'start' },
            { agent: { id: 'session-abc999' } },
        );
        assert.equal(started.ok, true, `start error: ${started.error}`);
        const request = JSON.parse(readFileSync(join(stateDir, 'runs', `${started.runId}.request.json`), 'utf8'));
        assert.equal(request.args[request.args.indexOf('-Session') + 1], 'abc999');
        assert.ok(await waitFor(() => readRunState({ stateDir, runId: started.runId }).state !== 'running', 30000));
    });

    test('integration: win_restart returns immediately, then the detached run settles', async () => {
        const stateDir = tempDir('tool-detached-state');
        const dshHome = tempDir('tool-detached-home');
        const engineScript = join(ROOT, 'fake-engine.ps1');
        const { byName } = toolFixture(
            { stateDir, dshHome, engineScript },
            { pwshPath: pwshForTests.path, stateDir, dshHome, restartDelayMs: 120 },
        );
        const startedAt = Date.now();
        const started = await byName.get(TOOL_NAMES.restart).execute(
            { action: 'restart', reason: 'detached-tool', session: 'session-tooltest' },
            {},
        );
        const callDurationMs = Date.now() - startedAt;
        assert.equal(started.ok, true, `start error: ${started.error}`);
        assert.equal(started.started, true);
        assert.equal(started.state, 'running');
        assert.match(String(started.runId), RUN_ID_RE);
        assert.ok(started.resultFile.endsWith(`${started.runId}.result.json`));
        assert.ok(callDurationMs < 5000, `the tool must not wait for the engine (took ${callDurationMs} ms)`);

        // A run record exists immediately, before the supervisor has done anything.
        const scheduled = JSON.parse(readFileSync(join(stateDir, 'runs', `${started.runId}.launch.json`), 'utf8'));
        assert.ok(
            ['scheduled', 'delayed', 'engine-running'].includes(scheduled.phase),
            `unexpected early phase: ${scheduled.phase}`,
        );
        assert.equal(scheduled.engineExitCode ?? null, null);

        // The resume notice must exist before anything was spawned.
        const noticeFile = pendingNoticePath(dshHome);
        const notice = JSON.parse(readFileSync(noticeFile, 'utf8'));
        assert.equal(notice.sessionId, 'tooltest');
        assert.ok(notice.reason.startsWith('detached-tool'), `notice reason: ${notice.reason}`);

        // The request file carries the exact engine argv: the calling session is
        // explicit (never left to the engine's environment fallback), plus the
        // detached-mode parameters.
        const request = JSON.parse(readFileSync(join(stateDir, 'runs', `${started.runId}.request.json`), 'utf8'));
        assert.equal(request.args[request.args.indexOf('-Session') + 1], 'tooltest');
        assert.equal(request.args[request.args.indexOf('-ResultFile') + 1], started.resultFile);
        assert.ok(request.args.includes('-NoWait'));
        assert.equal(request.notice.sessionId, 'tooltest');
        assert.equal(request.notice.path, noticeFile);

        const settled = await waitFor(
            () => readRunState({ stateDir, runId: started.runId }).state !== 'running',
            30000,
        );
        assert.ok(settled, 'the detached run must settle within 30s');
        const state = readRunState({ stateDir, runId: started.runId });
        assert.equal(state.state, 'ok', `run error: ${state.error}`);
        assert.equal(state.envelope.fake.noWait, true);
        assert.equal(state.envelope.fake.reason, 'detached-tool');
        assert.equal(state.envelope.fake.session, 'tooltest');

        // The fake engine never wrote a notice, so the supervisor's own bytes
        // were still there and must have been removed (stale notice gone).
        assert.ok(await waitForLaunchFinished(stateDir, started.runId), 'the supervisor must leave a terminal record');
        assert.throws(() => readFileSync(noticeFile), /ENOENT/);
        const launch = JSON.parse(readFileSync(join(stateDir, 'runs', `${started.runId}.launch.json`), 'utf8'));
        assert.equal(launch.phase, 'finished');
        assert.equal(launch.notice, 'deleted-stale');
        assert.equal(launch.engineExitCode, 0);

        const viaTool = await byName.get(TOOL_NAMES.result).execute({ runId: started.runId, stateDir }, {});
        assert.equal(viaTool.state, 'ok');
        assert.equal(viaTool.summary, 'restarted-ok');
    });

    test('integration: an engine-written notice survives the supervisor cleanup', async () => {
        const stateDir = tempDir('notice-kept-state');
        const dshHome = tempDir('notice-kept-home');
        const engineScript = join(ROOT, 'fake-engine.ps1');
        const { byName } = toolFixture(
            { stateDir, dshHome, engineScript },
            { pwshPath: pwshForTests.path, stateDir, dshHome, restartDelayMs: 0 },
        );
        process.env.FAKE_ENGINE_WRITE_NOTICE = '1';
        let started;
        try {
            started = await byName.get(TOOL_NAMES.restart).execute(
                { action: 'restart', reason: 'keep-notice', session: 'session-keep1' },
                {},
            );
        } finally {
            delete process.env.FAKE_ENGINE_WRITE_NOTICE;
        }
        assert.equal(started.ok, true, `start error: ${started.error}`);
        const settled = await waitFor(
            () => readRunState({ stateDir, runId: started.runId }).state !== 'running',
            30000,
        );
        assert.ok(settled, 'the detached run must settle within 30s');
        assert.ok(await waitForLaunchFinished(stateDir, started.runId), 'the supervisor must leave a terminal record');
        // The engine overwrote the supervisor's bytes: that notice is the one the
        // next boot must consume, so it has to survive.
        const notice = JSON.parse(readFileSync(pendingNoticePath(dshHome), 'utf8'));
        assert.equal(notice.reason, 'fake engine notice');
        assert.equal(notice.sessionId, 'keep1');
        const launch = JSON.parse(readFileSync(join(stateDir, 'runs', `${started.runId}.launch.json`), 'utf8'));
        assert.equal(launch.notice, 'kept-engine-notice');
    });

    test('integration: a detached run never writes engine stdout into the host stdio', () => {
        const packageRootPath = fileURLToPath(new URL('..', import.meta.url));
        const lib = (name) => pathToFileURL(join(packageRootPath, 'lib', name)).href;
        const probePath = join(ROOT, 'stdio-probe.mjs');
        writeFileSync(probePath, [
            "import { setTimeout as sleep } from 'node:timers/promises';",
            `import { normalizeConfig } from '${lib('config.js')}';`,
            `import { createToolDefinitions } from '${lib('tools.js')}';`,
            `import { launcherScriptPath } from '${lib('paths.js')}';`,
            `import { readRunState } from '${lib('runner.js')}';`,
            'const [stateDir, dshHome, pwshPath, engineScript] = process.argv.slice(2);',
            'const config = normalizeConfig({ pwshPath, stateDir, dshHome, restartDelayMs: 0 });',
            'const definitions = createToolDefinitions({',
            '    defineTool: (definition) => definition,',
            '    config,',
            '    paths: { stateDir, dshHome, engineScript, launcherScript: launcherScriptPath() },',
            '});',
            "const tool = definitions.find((definition) => definition.name === 'win_restart');",
            "const started = await tool.execute({ action: 'restart', reason: 'stdio-probe' }, {});",
            "if (!started.ok) { console.log('PROBE-FAILED ' + started.error); process.exit(3); }",
            'let state = readRunState({ stateDir, runId: started.runId });',
            "while (state.state === 'running') { await sleep(100); state = readRunState({ stateDir, runId: started.runId }); }",
            "console.log('PROBE-DONE ' + state.state);",
        ].join('\n'), 'utf8');
        const stateDir = tempDir('stdio-state');
        const dshHome = tempDir('stdio-home');
        const output = execFileSync(
            process.execPath,
            [probePath, stateDir, dshHome, pwshForTests.path, join(ROOT, 'fake-engine.ps1')],
            { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'pipe'] },
        );
        assert.match(output, /PROBE-DONE ok/, `probe output: ${output}`);
        assert.ok(!output.includes('restarted-ok'), 'the engine envelope must not reach the host stdout');
        assert.ok(!output.includes('"fake"'), 'the engine envelope must not reach the host stdout');
    });

    test('integration: detached launcher runs the engine and writes -ResultFile', async () => {
        const stateDir = tempDir('detached-state');
        const runId = newRunId();
        const files = runFilePaths(stateDir, runId);
        mkdirSync(files.dir, { recursive: true });
        const delayMs = 200;
        writeJsonAtomic(files.pendingFile, {
            runId,
            action: 'restart',
            startedAt: new Date().toISOString(),
            delayMs,
            resultFile: files.resultFile,
        });
        const invocation = resolveInvocation(normalizeConfig({}), { reason: 'detached-selftest' });
        const args = buildScriptArgs({
            scriptPath: fakeEnginePath,
            action: 'restart',
            invocation,
            resultFile: files.resultFile,
            noWait: true,
            platform: process.platform,
        });
        writeLaunchRequest(files.requestFile, {
            delayMs,
            runId,
            runDir: files.dir,
            execPath: pwshForTests.path,
            args,
        });
        const launchedAt = Date.now();
        const { pid } = spawnLauncher({
            nodePath: process.execPath,
            launcherPath: launcherScriptPath(),
            requestFile: files.requestFile,
            env: process.env,
        });
        assert.ok(pid === null || pid > 0);
        const finished = await waitFor(() => {
            const state = readRunState({ stateDir, runId });
            return state.state !== 'running';
        }, 30000);
        assert.ok(finished, 'the detached run must settle within 30s');
        const state = readRunState({ stateDir, runId });
        assert.equal(state.state, 'ok', `state error: ${state.error}`);
        assert.equal(state.envelope.fake.noWait, true);
        assert.equal(state.envelope.fake.reason, 'detached-selftest');
        assert.ok(Date.now() - launchedAt >= delayMs - 50, 'the launcher must honour the delay');
    });
}

// --------------------------------------------------------------------------
// Engine contract: the things a restart-time probe must NOT assume
// --------------------------------------------------------------------------

test('Show-Status never calls the interactive port probe (Test-HttpServing)', () => {
    /**
     * 2026-11-24 事故形状：-Status 对 web 形态直接调 Test-HttpServing，那是一个
     * Invoke-WebRequest 循环（带 6s 超时、多次重试）。宿主刚重启、端口已 LISTENING 但
     * 还没应答时，一次 -Status 就卡住整轮（面板与工具一起变慢），而且拿到的只是
     * 「暂时没应答」，不是「不服务」。只读动作一律走非交互探测：netstat 判 LISTENING、
     * 单次短超时取状态码，拿不到就如实报 0。
     */
    const source = readFileSync(join(fileURLToPath(new URL('..', import.meta.url)), 'scripts', 'dsh-restart.ps1'), 'utf8');
    const start = source.indexOf('function Show-Status');
    assert.ok(start > 0, 'Show-Status must exist in the engine');
    const end = source.indexOf('\nfunction ', start + 10);
    const body = source.slice(start, end === -1 ? source.length : end);
    assert.ok(body.length > 500, 'Show-Status body must be extracted, not empty');
    // 注释里提到这个名字是许可的（说明为什么不用它）；只有**调用**才是违规。
    const calls = body
        .split('\n')
        .filter((line) => !/^\s*#/.test(line))
        .join('\n');
    assert.equal(
        /\bTest-HttpServing\b/.test(calls),
        false,
        'Show-Status must stay non-interactive: no Test-HttpServing call (it retries and blocks)',
    );
});

// --------------------------------------------------------------------------
// Syntax check
// --------------------------------------------------------------------------

test('node --check passes for every JavaScript file in the package', () => {
    const root = fileURLToPath(new URL('..', import.meta.url));
    const files = [];
    for (const directory of ['lib', 'bin', 'test']) {
        for (const name of readdirSync(new URL(`../${directory}`, import.meta.url))) {
            if (name.endsWith('.js') || name.endsWith('.mjs')) files.push(join(directory, name));
        }
    }
    for (const relative of files) {
        execFileSync(process.execPath, ['--check', join(root, relative)], { stdio: 'pipe' });
    }
});

// --------------------------------------------------------------------------
// Runner
// --------------------------------------------------------------------------

let passed = 0;
const skipped = [];
const failures = [];
for (const testCase of cases) {
    try {
        const outcome = await testCase.fn();
        if (outcome === 'skip') {
            const reason = testCase.reason ?? 'requires a DSH host';
            skipped.push({ name: testCase.name, reason });
            console.log(`skip ${testCase.name} — ${reason}`);
            continue;
        }
        passed += 1;
        console.log(`ok   ${testCase.name}`);
    } catch (error) {
        failures.push({ name: testCase.name, error });
        console.error(`FAIL ${testCase.name}`);
        console.error(String(error?.stack ?? error).split('\n').map((line) => `     ${line}`).join('\n'));
    }
}

try {
    rmSync(ROOT, { recursive: true, force: true });
} catch {
    // A leftover temp directory must not turn a green run red.
}

console.log(`\n${passed} passed, ${failures.length} failed, ${skipped.length} skipped`);
if (failures.length > 0) {
    console.error('\nFailures:');
    for (const failure of failures) console.error(` - ${failure.name}`);
    process.exit(1);
}
