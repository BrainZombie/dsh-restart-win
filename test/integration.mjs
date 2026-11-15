#!/usr/bin/env node
/**
 * Integration tests for @brainzombie/dsh-restart-win.
 *
 * Scope (T4 item 2): the plugin layer, end to end, with the real process
 * boundaries — not unit stubs of the objects under test:
 *
 *   1. **argv** — a recording PowerShell *executable* stands in for pwsh. It
 *      writes the argv it actually received, so the assertion is against the
 *      bytes the OS delivered, not against the builder's return value.
 *   2. **detached run states** — the real launcher (`lib/delayed-spawn.mjs`)
 *      and the real state reader drive a run through `running` → `ok` and a
 *      second run through `failed`, reading only the files the contract
 *      defines (`*.pending.json`, `*.launch.json`, `*.result.json`).
 *   3. **config fail-closed** — invalid values raise `ConfigError` naming the
 *      field, and a rejected tool call never reaches a process.
 *   4. **output schema** — every returned value of every tool is validated with
 *      the host's own `validateJsonSchemaValue` when `@deepseek-ai/dsh-tools`
 *      is resolvable (otherwise that check is skipped, never faked green).
 *
 * The engine script path passed in argv is the real one; only the interpreter
 * is replaced, exactly as allowed by the task brief. `--with-engine` adds one
 * test that runs the real engine (`-Status -Json` against a temp state dir) for
 * machines that have PowerShell.
 */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// The supervisor's shell handoff needs explorer.exe/WScript; these tests drive it
// directly and assert on the child it spawns, so they pin the in-tree path.
process.env.DSH_RESTART_HANDOFF = '0';

import { ConfigError, DEFAULTS, normalizeConfig, resolveInvocation } from '../lib/config.js';
import { loadHostModule } from '../lib/host.js';
import { engineScriptPath, launcherScriptPath, resolvePwsh } from '../lib/paths.js';
import {
    buildScriptArgs,
    evaluateResultFile,
    extractJsonObject,
    newRunId,
    readRunState,
    runFilePaths,
    runForeground,
    spawnLauncher,
    writeJsonAtomic,
    writeLaunchRequest,
} from '../lib/runner.js';
import { createToolDefinitions, TOOL_NAMES } from '../lib/tools.js';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const TMP = mkdtempSync(join(tmpdir(), 'dsh-restart-win-integration-'));
const cases = [];

/**
 * The platform whose *semantics* this suite exercises.
 *
 * `process.platform` by default; `DSH_RESTART_TEST_PLATFORM=linux` lets a
 * Windows machine (and CI) verify the Linux branch. Tests that need Windows
 * semantics are registered as visible skips with a reason.
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
 * Register a test only when the platform semantics it exercises apply; else
 * register an explicit skip so the case count stays honest.
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
    const dir = join(TMP, name);
    mkdirSync(dir, { recursive: true });
    return dir;
}

/** @param {() => boolean} predicate @param {number} [timeoutMs] */
async function waitFor(predicate, timeoutMs = 20000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (predicate()) return true;
        await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
    }
    return false;
}

// --------------------------------------------------------------------------
// The recording PowerShell executable
//
// `runForeground` / the launcher spawn an executable with an argv array. This
// stub *is* that executable (run through node, which is how a JavaScript stub
// becomes spawnable on every platform): it records the argv it received and
// emulates the engine's documented result-file contract. The real
// `scripts/dsh-restart.ps1` path is still what travels in argv, so the argv
// assertion covers the production argument shape.
// --------------------------------------------------------------------------

const STUB = join(tempDir('stub'), 'recording-pwsh.mjs');
writeFileSync(STUB, `#!/usr/bin/env node
import { appendFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const out = process.env.STUB_OUT;
const behavior = process.env.STUB_BEHAVIOR || 'status';
writeFileSync(join(out, 'argv.json'), JSON.stringify(argv, null, 2));
appendFileSync(join(out, 'calls.log'), JSON.stringify(argv) + '\\n');

const fileIndex = argv.indexOf('-ResultFile');
const resultFile = fileIndex >= 0 ? argv[fileIndex + 1] : null;
const envelope = (ok, result, exitCode, extra = {}) => ({
    ok, result, exitCode,
    version: 'stub-0.0.0',
    steps: [],
    warnings: [],
    targetPid: null,
    newPid: null,
    hostUrl: null,
    error: ok ? null : (extra.error ?? null),
    durationMs: 12,
    stateDir: process.env.STUB_STATE || '',
    logPath: '',
    ...extra,
});
const emit = (value, exitCode) => {
    if (resultFile) writeFileSync(resultFile, JSON.stringify(value));
    process.stdout.write(JSON.stringify(value) + '\\n');
    process.exit(exitCode);
};

if (behavior === 'status') {
    emit(envelope(true, 'status', 0, {
        status: {
            version: 'stub-0.0.0',
            dshHome: 'C:\\\\stub\\\\.dsh',
            stateDir: process.env.STUB_STATE || '',
            profile: 'web',
            port: 3080,
            url: 'http://127.0.0.1:3080/',
            launchUrl: null,
            launchUrlState: 'unknown',
            launchUrlDetail: 'stub',
            http: '401',
            serving: true,
            cimOk: false,
            instances: [{ pid: 4242, name: 'node', port: 3080, isNode: true, start: 'stub', ws_mb: 1, handles: 1, source: 'port-listener' }],
            nodeChildren: [],
            bootRecord: null,
            lastRestart: null,
            marker: null,
        },
    }), 0);
} else if (behavior === 'ok') {
    emit(envelope(true, 'restarted-ok', 0), 0);
} else if (behavior === 'fail') {
    emit(envelope(false, 'verify-failed', 4, { error: 'the new combination did not come up' }), 4);
} else if (behavior === 'slow') {
    setTimeout(() => emit(envelope(true, 'verify-only-ok', 0), 0), Number(process.env.STUB_SLEEP_MS || 1200));
} else if (behavior === 'crash') {
    process.stderr.write('stub: engine never produced a result\\n');
    process.exit(9);
} else {
    process.stderr.write('stub: unknown behavior ' + behavior + '\\n');
    process.exit(64);
}
`, 'utf8');

/** @param {Record<string, string | undefined>} [overrides] */
function stubEnv(overrides = {}) {
    return { ...process.env, STUB_OUT: tempDir(`stub-out-${Math.random().toString(16).slice(2)}`), STUB_BEHAVIOR: 'status', ...overrides };
}

/**
 * The engine argv the plugin builds for one action, with the stub executable in
 * front. `args[0]` is the stub; the rest is exactly what the engine receives.
 *
 * @param {string} action
 * @param {ReturnType<typeof resolveInvocation>} invocation
 * @param {{ resultFile?: string, noWait?: boolean }} [extra]
 */
function stubArgs(action, invocation, extra = {}) {
    return [STUB, ...buildScriptArgs({
        scriptPath: engineScriptPath(),
        action,
        invocation,
        resultFile: extra.resultFile ?? '',
        noWait: extra.noWait ?? false,
        platform: PLATFORM,
    })];
}

/** @param {Record<string, unknown>} [overrides] */
function fixtureConfig(overrides = {}) {
    return normalizeConfig({ stateDir: tempDir('state-default'), ...overrides });
}

const PATHS = () => ({
    dshHome: tempDir('home-default'),
    stateDir: tempDir('state-tools'),
    engineScript: engineScriptPath(),
    launcherScript: launcherScriptPath(),
});

// --------------------------------------------------------------------------
// 1. argv
// --------------------------------------------------------------------------

test('argv: the OS delivers exactly the array the plugin built (restart)', async () => {
    const config = fixtureConfig();
    const invocation = resolveInvocation(config, { port: 4123, profile: 'web' });
    const env = stubEnv({ STUB_BEHAVIOR: 'status' });
    const args = stubArgs('status', invocation);
    const run = await runForeground({ execPath: process.execPath, args, timeoutMs: 10000, env });
    assert.equal(run.ok, true, `engine failed: ${run.stderr}`);
    const recorded = JSON.parse(readFileSync(join(env.STUB_OUT, 'argv.json'), 'utf8'));

    const prefix = PLATFORM === 'win32'
        ? ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass']
        : ['-NoLogo', '-NoProfile', '-NonInteractive'];
    const expected = [
        ...prefix,
        '-File', engineScriptPath(),
        '-Status', '-Json',
        '-Profile', 'web',
        '-HostKind', 'auto',
        '-Port', '4123',
        '-BindHost', '127.0.0.1',
        '-StateDir', invocation.stateDir,
        '-TaskName', 'DSH Restart',
        '-ReadySec', '90',
        '-VerifyReadySec', '150',
        '-GraceSec', '3',
        '-PortFreeSec', '30',
    ];
    assert.deepEqual(recorded, expected);
    // No shell ever saw this: one array element per token, no quoting artefacts.
    assert.ok(!recorded.some((value) => /["']/.test(value) && !value.includes(' ')), 'argv tokens must not be shell-quoted');
});

test('argv: a record action carries the recorded command and working directory', async () => {
    const config = fixtureConfig();
    const invocation = resolveInvocation(config, {
        recordCommand: 'dsh web --no-open --port {PORT}',
        recordWorkingDirectory: tempDir('record-cwd'),
    });
    const env = stubEnv({ STUB_BEHAVIOR: 'ok' });
    const args = stubArgs('record', invocation);
    const run = await runForeground({ execPath: process.execPath, args, timeoutMs: 10000, env });
    assert.equal(run.ok, true, run.stderr);
    const recorded = JSON.parse(readFileSync(join(env.STUB_OUT, 'argv.json'), 'utf8'));
    assert.ok(recorded.includes('-Record'));
    assert.equal(recorded[recorded.indexOf('-RecordCommand') + 1], 'dsh web --no-open --port {PORT}');
    assert.equal(recorded[recorded.indexOf('-RecordWorkingDirectory') + 1], invocation.recordWorkingDirectory);
});

test('argv: a detached action carries -ResultFile and -NoWait', () => {
    const config = fixtureConfig();
    const invocation = resolveInvocation(config, { delayMs: 0 });
    const resultFile = join(tempDir('detached-result'), 'run.result.json');
    const args = stubArgs('preflight', invocation, { resultFile, noWait: true });
    assert.ok(args.includes('-Preflight'));
    assert.equal(args[args.indexOf('-ResultFile') + 1], resultFile);
    assert.equal(args[args.length - 1], '-NoWait');
});

// --------------------------------------------------------------------------
// 2. runForeground failure modes
// --------------------------------------------------------------------------

test('foreground: a non-zero engine exit is reported, never thrown', async () => {
    const invocation = resolveInvocation(fixtureConfig(), {});
    const env = stubEnv({ STUB_BEHAVIOR: 'fail' });
    const run = await runForeground({ execPath: process.execPath, args: stubArgs('verify_only', invocation), timeoutMs: 10000, env });
    assert.equal(run.ok, false);
    assert.equal(run.exitCode, 4);
    const envelope = extractJsonObject(run.stdout);
    assert.equal(envelope.ok, false);
    assert.equal(envelope.result, 'verify-failed');
});

test('foreground: a missing result envelope is an explicit error', async () => {
    const invocation = resolveInvocation(fixtureConfig(), {});
    const env = stubEnv({ STUB_BEHAVIOR: 'crash' });
    const run = await runForeground({ execPath: process.execPath, args: stubArgs('verify_only', invocation), timeoutMs: 10000, env });
    assert.equal(run.ok, false);
    assert.equal(run.exitCode, 9);
    assert.equal(extractJsonObject(run.stdout), null);
    assert.match(run.stderr, /never produced a result/);
});

test('foreground: the timeout kills the process and says so', async () => {
    const invocation = resolveInvocation(fixtureConfig(), {});
    const env = stubEnv({ STUB_BEHAVIOR: 'slow', STUB_SLEEP_MS: '3000' });
    const startedAt = Date.now();
    const run = await runForeground({ execPath: process.execPath, args: stubArgs('verify_only', invocation), timeoutMs: 300, env });
    assert.equal(run.ok, false);
    assert.equal(run.timedOut, true);
    assert.ok(Date.now() - startedAt < 3000, 'the timeout must return before the child would have finished');
});

// --------------------------------------------------------------------------
// 3. detached run states: running → ok, and failed
// --------------------------------------------------------------------------

test('detached: the real launcher drives running → ok and the result file is authoritative', async () => {
    const stateDir = tempDir('detached-ok-state');
    const runId = newRunId();
    const files = runFilePaths(stateDir, runId);
    mkdirSync(files.dir, { recursive: true });
    const env = stubEnv({ STUB_BEHAVIOR: 'slow', STUB_SLEEP_MS: '900', STUB_STATE: stateDir });
    writeJsonAtomic(files.pendingFile, { runId, action: 'preflight', startedAt: new Date().toISOString(), launcherPid: null });
    writeLaunchRequest(files.requestFile, {
        delayMs: 0,
        runId,
        runDir: files.dir,
        execPath: process.execPath,
        args: stubArgs('preflight', resolveInvocation(fixtureConfig(), {}), { resultFile: files.resultFile }),
    });
    const { pid } = spawnLauncher({
        nodePath: process.execPath,
        launcherPath: launcherScriptPath(),
        requestFile: files.requestFile,
        env,
    });
    assert.ok(pid === null || pid > 0);

    const sawRunning = await waitFor(() => readRunState({ stateDir, runId }).state === 'running', 5000);
    assert.ok(sawRunning, 'the run must be observable as running before it settles');
    const settled = await waitFor(() => readRunState({ stateDir, runId }).state !== 'running', 15000);
    assert.ok(settled, 'the run must settle');
    const state = readRunState({ stateDir, runId });
    assert.equal(state.state, 'ok', state.error ?? '');
    assert.equal(state.action, 'preflight');
    assert.equal(state.exitCode, 0);
    assert.equal(state.summary, 'verify-only-ok');
    assert.equal(state.envelope.version, 'stub-0.0.0');
    assert.ok(state.finishedAt, 'the finish time comes from the result file mtime');
});

test('detached: an engine that reports failure settles as failed with its exit code', async () => {
    const stateDir = tempDir('detached-fail-state');
    const runId = newRunId();
    const files = runFilePaths(stateDir, runId);
    mkdirSync(files.dir, { recursive: true });
    const env = stubEnv({ STUB_BEHAVIOR: 'fail', STUB_STATE: stateDir });
    writeJsonAtomic(files.pendingFile, { runId, action: 'restart', startedAt: new Date().toISOString(), launcherPid: null });
    writeLaunchRequest(files.requestFile, {
        delayMs: 0,
        runId,
        runDir: files.dir,
        execPath: process.execPath,
        args: stubArgs('restart', resolveInvocation(fixtureConfig(), {}), { resultFile: files.resultFile }),
    });
    spawnLauncher({ nodePath: process.execPath, launcherPath: launcherScriptPath(), requestFile: files.requestFile, env });
    const settled = await waitFor(() => readRunState({ stateDir, runId }).state !== 'running', 15000);
    assert.ok(settled, 'the failing run must settle');
    const state = readRunState({ stateDir, runId });
    assert.equal(state.state, 'failed');
    assert.equal(state.exitCode, 4);
    assert.equal(state.summary, 'verify-failed');
    assert.equal(state.error, 'the new combination did not come up');
});

test('detached: an unknown run id is reported as unknown, not as a failure', () => {
    const state = readRunState({ stateDir: tempDir('detached-empty-state'), runId: newRunId() });
    assert.equal(state.state, 'unknown');
    assert.match(state.error, /no run record/);
});

test('detached: a launcher that cannot start the engine leaves a failed state with the reason', async () => {
    const stateDir = tempDir('detached-broken-state');
    const runId = newRunId();
    const files = runFilePaths(stateDir, runId);
    mkdirSync(files.dir, { recursive: true });
    writeJsonAtomic(files.pendingFile, { runId, action: 'preflight', startedAt: new Date().toISOString(), launcherPid: null });
    writeLaunchRequest(files.requestFile, {
        delayMs: 0,
        runId,
        runDir: files.dir,
        execPath: join(stateDir, 'definitely-missing-executable'),
        args: ['irrelevant'],
    });
    spawnLauncher({ nodePath: process.execPath, launcherPath: launcherScriptPath(), requestFile: files.requestFile });
    const settled = await waitFor(() => readRunState({ stateDir, runId }).state !== 'running', 15000);
    assert.ok(settled);
    const state = readRunState({ stateDir, runId });
    assert.equal(state.state, 'failed');
    assert.match(state.error, /ENOENT|supervisor|launcher/i);
    assert.match(state.error, /definitely-missing-executable/);
});

test('detached: evaluateResultFile distinguishes ok, failed and unreadable results', () => {
    const dir = tempDir('evaluate');
    const okFile = join(dir, 'ok.json');
    writeFileSync(okFile, JSON.stringify({ ok: true, result: 'status', exitCode: 0, version: 'x' }));
    assert.equal(evaluateResultFile(okFile).state, 'ok');

    const failedFile = join(dir, 'failed.json');
    writeFileSync(failedFile, JSON.stringify({ ok: false, result: 'verify-failed', exitCode: 4, error: 'nope' }));
    const failed = evaluateResultFile(failedFile);
    assert.equal(failed.state, 'failed');
    assert.equal(failed.exitCode, 4);

    const brokenFile = join(dir, 'broken.json');
    writeFileSync(brokenFile, '{not json');
    assert.equal(evaluateResultFile(brokenFile).state, 'failed');

    assert.equal(evaluateResultFile(join(dir, 'missing.json')).exists, false);
});

// --------------------------------------------------------------------------
// 4. config fail-closed
// --------------------------------------------------------------------------

test('config: every invalid value raises ConfigError with the offending field', () => {
    const invalid = [
        ['port', { port: 70000 }],
        ['port', { port: '8080' }],
        ['profile', { profile: 'bad profile' }],
        ['bindHost', { bindHost: '999.1.1.1' }],
        ['taskName', { taskName: 'bad/name' }],
        ['stateDir', { stateDir: 'relative\\path' }],
        ['dshHome', { dshHome: 'C:\\bad<path>' }],
        ['readySec', { readySec: 1 }],
        ['verifyReadySec', { verifyReadySec: 0 }],
        ['graceSec', { graceSec: -1 }],
        ['portFreeSec', { portFreeSec: 0 }],
        ['restartDelayMs', { restartDelayMs: -1 }],
        ['toolTimeoutMs', { toolTimeoutMs: 10 }],
        ['verifyTimeoutMs', { verifyTimeoutMs: 10 }],
        ['tools.scratch', { tools: { scratch: true } }],
        ['unknownKey', { unknownKey: 1 }],
    ];
    for (const [field, raw] of invalid) {
        assert.throws(() => normalizeConfig(raw), (error) => {
            assert.ok(error instanceof ConfigError, `${field}: expected ConfigError, got ${error?.name}`);
            assert.equal(error.field, field);
            return true;
        }, `${field} must be rejected`);
    }
});

test('config: per-call overrides are validated the same way and never fall back silently', () => {
    const config = normalizeConfig({});
    assert.throws(() => resolveInvocation(config, { port: 0 }), /port/);
    assert.throws(() => resolveInvocation(config, { session: 'bad session id' }), /session/);
    assert.throws(() => resolveInvocation(config, { reason: 'line\nbreak' }), /reason/);
    assert.throws(() => resolveInvocation(config, { waitIdleSec: 999999 }), /waitIdleSec/);
    assert.throws(() => resolveInvocation(config, { notACallKey: 1 }), /notACallKey/);
    // Defaults are only for absent keys: an explicit empty string is an error for
    // required fields, and an empty optional path keeps the configured value.
    assert.equal(resolveInvocation(config, { stateDir: '' }).stateDir, '');
    assert.equal(DEFAULTS.tools.restart, true);
});

test('config: a rejected tool call returns a failure object and spawns nothing', async () => {
    const out = tempDir('rejected-call-out');
    const config = normalizeConfig({ stateDir: tempDir('rejected-call-state') });
    const definitions = createToolDefinitions({
        defineTool: (definition) => definition,
        config,
        paths: PATHS(),
        env: { ...process.env, STUB_OUT: out },
        platform: PLATFORM,
    });
    const byName = new Map(definitions.map((definition) => [definition.name, definition]));
    for (const [tool, args] of [
        [TOOL_NAMES.status, { port: 70000 }],
        [TOOL_NAMES.restart, { action: 'explode' }],
        [TOOL_NAMES.restart, { action: 'record' }],
        [TOOL_NAMES.preflight, { port: 0 }],
    ]) {
        const value = await byName.get(tool).execute(args, {});
        assert.equal(value.ok, false, `${tool} must reject ${JSON.stringify(args)}`);
        assert.ok(typeof value.error === 'string' && value.error.length > 0);
        assert.match(value.error, /port|action|recordCommand/);
    }
    assert.equal(existsSync(join(out, 'argv.json')), false, 'a rejected call must not start a process');
});

// --------------------------------------------------------------------------
// 5. tool output schema (host validation when the host package is resolvable)
// --------------------------------------------------------------------------

/**
 * @param {string} file
 * @returns {string[]} schema violations; the shape rules every tool value must
 *   satisfy even without the host package (declared keys only, required keys
 *   present, enum members in range)
 */
function shapeViolations(schema, value) {
    const problems = [];
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return ['value is not an object'];
    for (const key of Object.keys(value)) {
        if (!Object.hasOwn(schema.properties ?? {}, key)) problems.push(`undeclared key ${key}`);
    }
    for (const key of schema.required ?? []) {
        if (!Object.hasOwn(value, key)) problems.push(`missing required key ${key}`);
    }
    for (const [key, node] of Object.entries(schema.properties ?? {})) {
        if (!Object.hasOwn(value, key) || value[key] === null) continue;
        if (node.enum && !node.enum.includes(value[key])) problems.push(`${key}=${value[key]} is not in ${node.enum.join('|')}`);
        if (node.type === 'boolean' && typeof value[key] !== 'boolean') problems.push(`${key} must be boolean`);
        if (node.type === 'integer' && !Number.isInteger(value[key])) problems.push(`${key} must be integer`);
        if (node.type === 'string' && typeof value[key] !== 'string') problems.push(`${key} must be string`);
    }
    return problems;
}

test('schema: every tool result satisfies the declared output shape (shape rules)', async () => {
    const out = tempDir('schema-out');
    const config = normalizeConfig({ stateDir: tempDir('schema-state') });
    const definitions = createToolDefinitions({
        defineTool: (definition) => definition,
        config,
        paths: PATHS(),
        env: { ...process.env, STUB_OUT: out },
        platform: PLATFORM,
    });
    const byName = new Map(definitions.map((definition) => [definition.name, definition]));
    const values = [
        [TOOL_NAMES.restart, { action: 'record' }],
        [TOOL_NAMES.status, {}],
        [TOOL_NAMES.result, {}],
        [TOOL_NAMES.result, { runId: '20260101-000000-abcdef' }],
    ];
    for (const [tool, args] of values) {
        const definition = byName.get(tool);
        const value = await definition.execute(args, {});
        const problems = shapeViolations(definition.output.schema, value);
        assert.deepEqual(problems, [], `${tool}(${JSON.stringify(args)}) shape: ${problems.join('; ')}`);
        const rendered = definition.output.render(args, value);
        assert.ok(Array.isArray(rendered) && rendered.length > 0, `${tool} render returned nothing`);
    }
});

test('schema: the host validator accepts the same values (when the host is installed)', async () => {
    let hostModule;
    try {
        hostModule = await loadHostModule('@deepseek-ai/dsh-tools', { profile: 'web' });
    } catch {
        return 'skip';
    }
    const { defineTool, validateJsonSchemaValue } = hostModule;
    if (typeof validateJsonSchemaValue !== 'function') return 'skip';

    const out = tempDir('schema-host-out');
    const config = normalizeConfig({ stateDir: tempDir('schema-host-state') });
    const definitions = createToolDefinitions({
        defineTool,
        config,
        paths: PATHS(),
        env: { ...process.env, STUB_OUT: out },
        platform: PLATFORM,
    });
    const byName = new Map(definitions.map((definition) => [definition.name, definition]));
    for (const [tool, args] of [
        [TOOL_NAMES.status, {}],
        [TOOL_NAMES.restart, { action: 'record' }],
        [TOOL_NAMES.result, { runId: '20260101-000000-abcdef' }],
        [TOOL_NAMES.preflight, { port: 70000 }],
    ]) {
        const definition = byName.get(tool);
        const value = await definition.execute(args, {});
        const violations = validateJsonSchemaValue(definition.output.schema, value, '');
        assert.deepEqual(violations, [], `${tool}(${JSON.stringify(args)}): ${violations.join('; ')}`);
    }
});

// --------------------------------------------------------------------------
// 6. opt-in: the real engine through the same code path
// --------------------------------------------------------------------------

if (!process.argv.includes('--with-engine')) {
    skip('real engine: -Status -Json through runForeground, isolated state dir', 'pass --with-engine to run the real engine');
} else {
    testUnless(
        PLATFORM === 'win32',
        'real engine: -Status -Json through runForeground, isolated state dir',
        'windows-only: runs scripts/dsh-restart.ps1 through a real PowerShell host',
        async () => {
            const pwsh = resolvePwsh({ pwshPath: '' }, { env: process.env, platform: PLATFORM });
            const stateDir = tempDir('real-engine-state');
            const dshHome = tempDir('real-engine-home');
            const invocation = resolveInvocation(normalizeConfig({ stateDir, dshHome }), { port: 59999 });
            const args = buildScriptArgs({ scriptPath: engineScriptPath(), action: 'status', invocation, platform: PLATFORM });
            const run = await runForeground({ execPath: pwsh.path, args, timeoutMs: 60000, env: process.env });
            assert.equal(run.ok, true, `engine exit ${run.exitCode}: ${run.stderr}`);
            const envelope = extractJsonObject(run.stdout);
            assert.ok(envelope, 'the engine must print one JSON envelope');
            assert.equal(envelope.ok, true);
            assert.equal(envelope.result, 'status');
            assert.equal(envelope.exitCode, 0);
            for (const key of ['ok', 'result', 'exitCode', 'version', 'steps', 'warnings', 'targetPid', 'newPid', 'hostUrl', 'error', 'durationMs', 'stateDir', 'logPath', 'status']) {
                assert.ok(Object.hasOwn(envelope, key), `envelope is missing ${key}`);
            }
        },
    );
}

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
    rmSync(TMP, { recursive: true, force: true });
} catch {
    // Leftover temp files must not turn a green run red.
}

console.log(`\n${passed} passed, ${failures.length} failed, ${skipped.length} skipped`);
if (failures.length > 0) {
    console.error('\nFailures:');
    for (const failure of failures) console.error(` - ${failure.name}`);
    process.exit(1);
}
