/**
 * Engine invocation for dsh-restart-win.
 *
 * Two execution modes, one argv builder:
 *
 *   - **foreground** (`runForeground`): `execFile` with a timeout and the
 *     caller's abort signal. Used for short, read-only-ish actions (status,
 *     dry-run, record, task register/unregister).
 *   - **detached** (`writeLaunchRequest` + `spawnLauncher`): the host writes a
 *     run record, a detached launcher sleeps `restartDelayMs`, then spawns the
 *     engine with `detached: true`, `stdio: 'ignore'` and no inherited stdio.
 *     The tool returns immediately, and the engine writes its final JSON to
 *     `-ResultFile` (`readRunState` reads it back).
 *
 * Arguments are always an array. No function here builds a shell string.
 */
import { execFile, spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { ACTIONS, DETACHED_ACTIONS, ConfigError } from './config.js';

// `ACTIONS` / `DETACHED_ACTIONS` live in lib/config.js (policy); this module owns
// how each action is spelled on the engine command line.
export { ACTIONS, DETACHED_ACTIONS };

/** Action -> the legacy PowerShell switch that selects it. `restart` is the default. */
export const ACTION_SWITCHES = Object.freeze({
    restart: null,
    start: '-Start',
    stop: '-Stop',
    status: '-Status',
    dry_run: '-DryRun',
    record: '-Record',
    task_register: '-RegisterTask',
    task_unregister: '-UnregisterTask',
    preflight: '-Preflight',
    verify_only: '-VerifyOnly',
});

for (const action of ACTIONS) {
    if (!Object.hasOwn(ACTION_SWITCHES, action)) {
        throw new Error(`dsh-restart-win: action "${action}" has no PowerShell switch (ACTION_SWITCHES is out of date)`);
    }
}

/** `\d{8}-\d{6}-<hex>`; also used to reject a path-shaped run id. */
export const RUN_ID_RE = /^\d{8}-\d{6}-[a-z0-9]{4,8}$/;

/** How long a freshly written run record is trusted before the launcher is declared dead. */
const LAUNCHER_START_GRACE_MS = 5000;

/**
 * Environment variable the engine reads to decide whether it injects its own
 * host-process variables into the instance it launches.
 */
export const INJECT_HOST_ENV_KEY = 'DSH_RESTART_INJECT_HOST_ENV';

/**
 * Build the environment for an engine child process.
 *
 * `injectHostEnv: false` sets `DSH_RESTART_INJECT_HOST_ENV=0`; the default
 * (`true`) leaves the environment untouched so the engine keeps its own
 * behavior. The input object is never mutated.
 *
 * @param {Record<string, string | undefined>} [env]
 * @param {boolean} [injectHostEnv]
 * @returns {Record<string, string | undefined>}
 */
export function engineEnv(env = process.env, injectHostEnv = true) {
    if (injectHostEnv !== false) return env;
    return { ...env, [INJECT_HOST_ENV_KEY]: '0' };
}

/**
 * Common PowerShell prefix. `-ExecutionPolicy Bypass` is a Windows-only flag.
 *
 * @param {string} [platform]
 * @returns {string[]}
 */
export function powershellPrefix(platform = process.platform) {
    const prefix = ['-NoLogo', '-NoProfile', '-NonInteractive'];
    if (platform === 'win32') prefix.push('-ExecutionPolicy', 'Bypass');
    return prefix;
}

/**
 * @param {string[]} args
 * @param {string} flag
 * @param {string | number} value
 */
function pushPair(args, flag, value) {
    args.push(flag, String(value));
}

/**
 * Build the PowerShell argument array (without the executable) for one action.
 * Pure: every input is already validated by `lib/config.js`.
 *
 * @param {{
 *   scriptPath: string,
 *   action: string,
 *   invocation: Record<string, unknown>,
 *   resultFile?: string,
 *   noWait?: boolean,
 *   platform?: string,
 * }} options
 * @returns {string[]}
 */
export function buildScriptArgs(options) {
    const {
        scriptPath,
        action,
        invocation,
        resultFile = '',
        noWait = false,
        platform = process.platform,
    } = options;
    if (!Object.hasOwn(ACTION_SWITCHES, action)) {
        throw new ConfigError('action', `unknown action "${action}" (accepted: ${ACTIONS.join(', ')})`);
    }
    if (typeof scriptPath !== 'string' || scriptPath === '') {
        throw new ConfigError('scriptPath', 'engine script path must be a non-empty string');
    }
    if (!invocation || typeof invocation !== 'object') {
        throw new ConfigError('invocation', 'expected the resolved invocation object');
    }
    for (const key of ['profile', 'port', 'bindHost', 'taskName', 'readySec', 'verifyReadySec', 'graceSec', 'portFreeSec']) {
        const value = invocation[key];
        if (typeof value !== 'string' && typeof value !== 'number') {
            throw new ConfigError(key, 'is missing from the resolved invocation');
        }
    }
    const args = [...powershellPrefix(platform), '-File', scriptPath];
    const actionSwitch = ACTION_SWITCHES[action];
    if (actionSwitch) args.push(actionSwitch);
    args.push('-Json');

    pushPair(args, '-Profile', invocation.profile);
    pushPair(args, '-Port', invocation.port);
    pushPair(args, '-BindHost', invocation.bindHost);
    // An empty value is omitted, never passed as '': `-DshHome ''` would
    // override the engine's own %DSH_HOME% / %USERPROFILE% default.
    if (invocation.dshHome) pushPair(args, '-DshHome', invocation.dshHome);
    if (invocation.stateDir) pushPair(args, '-StateDir', invocation.stateDir);
    pushPair(args, '-TaskName', invocation.taskName);
    pushPair(args, '-ReadySec', invocation.readySec);
    pushPair(args, '-VerifyReadySec', invocation.verifyReadySec);
    pushPair(args, '-GraceSec', invocation.graceSec);
    pushPair(args, '-PortFreeSec', invocation.portFreeSec);

    if (invocation.waitIdleSec > 0) {
        pushPair(args, '-WaitIdleSec', invocation.waitIdleSec);
        if (invocation.idleMaxSec > 0) pushPair(args, '-IdleMaxSec', invocation.idleMaxSec);
    }
    if (action === 'record') {
        if (invocation.recordCommand) pushPair(args, '-RecordCommand', invocation.recordCommand);
        if (invocation.recordWorkingDirectory) {
            pushPair(args, '-RecordWorkingDirectory', invocation.recordWorkingDirectory);
        }
    }
    if (invocation.verifyTempRoot) pushPair(args, '-VerifyTempRoot', invocation.verifyTempRoot);
    if (invocation.session) pushPair(args, '-Session', invocation.session);
    if (invocation.reason) pushPair(args, '-Reason', invocation.reason);
    if (invocation.fast) args.push('-Fast');
    if (invocation.forceUnverified) args.push('-ForceUnverified');
    if (invocation.viaTask) args.push('-ViaTask');
    if (invocation.tryCtrlC) args.push('-TryCtrlC');
    if (invocation.doNotTouchDshHome) args.push('-DoNotTouchDshHome');
    if (resultFile) pushPair(args, '-ResultFile', resultFile);
    if (noWait) args.push('-NoWait');

    for (const element of args) {
        if (typeof element !== 'string' || element.includes('\u0000')) {
            throw new ConfigError('argv', 'every argument must be a NUL-free string');
        }
    }
    return args;
}

/**
 * Build the complete argv array including the PowerShell executable.
 *
 * @param {{ execPath: string } & Parameters<typeof buildScriptArgs>[0]} options
 * @returns {string[]}
 */
export function buildArgv(options) {
    const { execPath } = options;
    if (typeof execPath !== 'string' || execPath === '') {
        throw new ConfigError('execPath', 'PowerShell executable path must be a non-empty string');
    }
    return [execPath, ...buildScriptArgs(options)];
}

/**
 * @param {number} [now]
 * @param {(size: number) => Buffer} [random]
 * @returns {string} `YYYYMMDD-HHmmss-<6 hex>`, UTC, filesystem-safe
 */
export function newRunId(now = Date.now(), random = randomBytes) {
    const date = new Date(now);
    const pad = (value, width = 2) => String(value).padStart(width, '0');
    const stamp = `${date.getUTCFullYear()}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}`
        + `-${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}`;
    return `${stamp}-${random(4).toString('hex').slice(0, 6)}`;
}

/**
 * One detached run owns four files in `<stateDir>/runs`.
 *
 * @param {string} stateDir
 * @param {string} runId
 * @returns {{ dir: string, resultFile: string, pendingFile: string, launchFile: string, requestFile: string }}
 */
export function runFilePaths(stateDir, runId) {
    const dir = join(stateDir, 'runs');
    return {
        dir,
        resultFile: join(dir, `${runId}.result.json`),
        pendingFile: join(dir, `${runId}.pending.json`),
        launchFile: join(dir, `${runId}.launch.json`),
        requestFile: join(dir, `${runId}.request.json`),
    };
}

/**
 * Write JSON through a temp file + rename, so a reader never sees half a record.
 *
 * @param {string} file
 * @param {unknown} value
 */
export function writeJsonAtomic(file, value) {
    const temp = `${file}.tmp-${process.pid}-${Date.now()}`;
    writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    renameSync(temp, file);
}

/**
 * @param {string} file
 * @returns {{ exists: boolean, ok: boolean, value: unknown, error: string | null, mtimeMs: number | null }}
 */
export function readJsonFile(file) {
    let text;
    try {
        text = readFileSync(file, 'utf8');
    } catch (error) {
        if (error && error.code === 'ENOENT') {
            return { exists: false, ok: false, value: null, error: null, mtimeMs: null };
        }
        return { exists: true, ok: false, value: null, error: String(error?.message ?? error), mtimeMs: null };
    }
    let mtimeMs = null;
    try {
        mtimeMs = statSync(file).mtimeMs;
    } catch {
        mtimeMs = null;
    }
    try {
        return { exists: true, ok: true, value: JSON.parse(text), error: null, mtimeMs };
    } catch (error) {
        return { exists: true, ok: false, value: null, error: `invalid JSON: ${String(error?.message ?? error)}`, mtimeMs };
    }
}

/**
 * Run the engine in the foreground.
 *
 * Resolves — never rejects — with the outcome, so a tool can report a clean
 * failure instead of throwing through the tool pipeline.
 *
 * @param {{
 *   execPath: string,
 *   args: string[],
 *   timeoutMs?: number,
 *   signal?: AbortSignal,
 *   env?: Record<string, string | undefined>,
 *   cwd?: string,
 * }} options
 * @returns {Promise<{
 *   ok: boolean, exitCode: number | null, signal: string | null, timedOut: boolean,
 *   aborted: boolean, stdout: string, stderr: string, durationMs: number, error: string | null,
 * }>}
 */
export function runForeground(options) {
    const {
        execPath,
        args,
        timeoutMs = 0,
        signal,
        env = process.env,
        cwd,
    } = options;
    const startedAt = Date.now();
    const finish = (fields) => ({
        ok: false,
        exitCode: null,
        signal: null,
        timedOut: false,
        aborted: false,
        stdout: '',
        stderr: '',
        durationMs: Date.now() - startedAt,
        error: null,
        ...fields,
    });
    if (signal?.aborted) {
        return Promise.resolve(finish({ aborted: true, error: 'aborted before start' }));
    }
    return new Promise((resolvePromise) => {
        /** @type {import('node:child_process').ExecFileOptions} */
        const execOptions = {
            encoding: 'utf8',
            windowsHide: true,
            maxBuffer: 16 * 1024 * 1024,
            env,
        };
        if (timeoutMs > 0) {
            execOptions.timeout = timeoutMs;
            execOptions.killSignal = 'SIGTERM';
        }
        if (cwd) execOptions.cwd = cwd;
        if (signal) execOptions.signal = signal;
        execFile(execPath, args, execOptions, (error, stdout, stderr) => {
            const durationMs = Date.now() - startedAt;
            const timedOut = Boolean(error && (error.killed === true || error.code === 'ETIMEDOUT'));
            const aborted = Boolean(error && (error.name === 'AbortError' || error.code === 'ABORT_ERR'));
            let exitCode = null;
            if (typeof error?.code === 'number') exitCode = error.code;
            else if (!error) exitCode = 0;
            const reason = timedOut
                ? `timed out after ${timeoutMs} ms`
                : aborted
                    ? 'aborted by the caller'
                    : error
                        ? String(error.message ?? error)
                        : null;
            resolvePromise({
                ok: exitCode === 0 && !error,
                exitCode,
                signal: typeof error?.signal === 'string' ? error.signal : null,
                timedOut,
                aborted,
                stdout: String(stdout ?? ''),
                stderr: String(stderr ?? ''),
                durationMs,
                error: reason,
            });
        });
    });
}

/**
 * Persist everything the detached launcher needs. Keeping it in one file means
 * the launcher never has to parse a long command line.
 *
 * @param {string} file
 * @param {{
 *   delayMs: number, runId: string, runDir: string, execPath: string, args: string[], cwd?: string,
 *   notice?: { path: string, sessionId: string, reason: string } | null,
 *   engineEnv?: Record<string, string> | null,
 * }} request
 */
export function writeLaunchRequest(file, request) {
    writeJsonAtomic(file, {
        delayMs: request.delayMs,
        runId: request.runId,
        runDir: request.runDir,
        execPath: request.execPath,
        args: request.args,
        cwd: request.cwd ?? '',
        notice: request.notice ?? null,
        // Environment overrides the supervisor must merge into the engine's env
        // (currently only DSH_RESTART_INJECT_HOST_ENV=0), kept on disk so the
        // launch stays auditable.
        engineEnv: request.engineEnv ?? null,
        requestedAt: new Date().toISOString(),
    });
}

/**
 * Start the detached launcher. The launcher inherits neither stdio nor a
 * console window, and is unref'd so the host can exit immediately.
 *
 * @param {{
 *   nodePath: string, launcherPath: string, requestFile: string,
 *   env?: Record<string, string | undefined>, cwd?: string,
 * }} options
 * @returns {{ pid: number | null }}
 */
export function spawnLauncher(options) {
    const {
        nodePath,
        launcherPath,
        requestFile,
        env = process.env,
        cwd,
    } = options;
    const child = spawn(nodePath, [launcherPath, requestFile], {
        detached: true,
        stdio: 'ignore',
        windowsHide: true,
        env,
        ...(cwd ? { cwd } : {}),
    });
    child.unref();
    return { pid: typeof child.pid === 'number' ? child.pid : null };
}

/**
 * @param {number | string | null | undefined} pid
 * @returns {boolean}
 */
export function isProcessAlive(pid) {
    const value = Number(pid);
    if (!Number.isInteger(value) || value <= 0) return false;
    try {
        process.kill(value, 0);
        return true;
    } catch (error) {
        // EPERM means the process exists but belongs to another account.
        return error?.code === 'EPERM';
    }
}

/**
 * @param {unknown} value
 * @returns {value is Record<string, unknown>}
 */
function isPlainObject(value) {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Return the balanced `{...}` substring starting at `start`, or null.
 *
 * @param {string} source
 * @param {number} start
 * @returns {string | null}
 */
function balancedObjectAt(source, start) {
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let index = start; index < source.length; index += 1) {
        const character = source[index];
        if (inString) {
            if (escaped) escaped = false;
            else if (character === '\\') escaped = true;
            else if (character === '"') inString = false;
            continue;
        }
        if (character === '"') inString = true;
        else if (character === '{') depth += 1;
        else if (character === '}') {
            depth -= 1;
            if (depth === 0) return source.slice(start, index + 1);
        }
    }
    return null;
}

/**
 * Pull the engine's JSON envelope out of stdout.
 *
 * The contract says stdout carries exactly one JSON object, and this still
 * tolerates stray host output: a full parse wins, otherwise the last balanced
 * object that parses is used. Returns null when nothing parses.
 *
 * @param {string} text
 * @returns {Record<string, unknown> | null}
 */
export function extractJsonObject(text) {
    const source = String(text ?? '').trim();
    if (source === '') return null;
    try {
        const parsed = JSON.parse(source);
        return isPlainObject(parsed) ? parsed : null;
    } catch {
        // Fall through to the scan below.
    }
    const starts = [];
    for (let index = 0; index < source.length; index += 1) {
        if (source[index] === '{') starts.push(index);
    }
    for (let cursor = starts.length - 1; cursor >= 0; cursor -= 1) {
        const candidate = balancedObjectAt(source, starts[cursor]);
        if (!candidate) continue;
        try {
            const parsed = JSON.parse(candidate);
            if (isPlainObject(parsed)) return parsed;
        } catch {
            // Keep trying earlier starts.
        }
    }
    return null;
}

/**
 * Evaluate one engine result file.
 *
 * The engine writes its final JSON envelope both to stdout and to `-ResultFile`
 * on every terminal path, so the file is the authoritative artifact for a
 * detached run.
 *
 * @param {string} file
 * @returns {{
 *   exists: boolean,
 *   state: 'ok' | 'failed',
 *   ok: boolean,
 *   envelope: Record<string, unknown> | null,
 *   exitCode: number | null,
 *   summary: string | null,
 *   error: string | null,
 *   finishedAt: string | null,
 * }}
 */
export function evaluateResultFile(file) {
    const result = readJsonFile(file);
    const finishedAt = result.mtimeMs ? new Date(result.mtimeMs).toISOString() : null;
    if (!result.exists) {
        return { exists: false, state: 'failed', ok: false, envelope: null, exitCode: null, summary: null, error: null, finishedAt };
    }
    if (!result.ok || !isPlainObject(result.value)) {
        return {
            exists: true,
            state: 'failed',
            ok: false,
            envelope: null,
            exitCode: null,
            summary: null,
            error: `result file is unreadable (${result.error ?? 'not a JSON object'})`,
            finishedAt,
        };
    }
    const envelope = result.value;
    const exitCode = Number.isInteger(envelope.exitCode) ? Number(envelope.exitCode) : null;
    const ok = envelope.ok === true && (exitCode === null || exitCode === 0);
    return {
        exists: true,
        state: ok ? 'ok' : 'failed',
        ok,
        envelope,
        exitCode,
        summary: typeof envelope.result === 'string' ? envelope.result : null,
        error: ok
            ? null
            : typeof envelope.error === 'string' && envelope.error !== ''
                ? envelope.error
                : `engine reported result "${typeof envelope.result === 'string' ? envelope.result : 'unknown'}" with exit code ${exitCode ?? 'unknown'}`,
        finishedAt,
    };
}

/**
 * Read one detached run's state without trusting anything but the files it
 * wrote. Three states are reported, and a fourth (`unknown`) when there is no
 * record at all:
 *
 *   - `ok`      result file present, `ok === true`, exit code 0 (when present)
 *   - `failed`  result file present but not ok, or the engine/launcher died
 *               before writing a result
 *   - `running` launcher or engine is still alive
 *   - `unknown` no run record for this id
 *
 * @param {{ stateDir: string, runId: string }} run
 * @param {{ now?: number, isAlive?: (pid: number) => boolean }} [options]
 * @returns {{
 *   state: 'ok' | 'failed' | 'running' | 'unknown',
 *   ok: boolean,
 *   runId: string,
 *   action: string | null,
 *   resultFile: string,
 *   exitCode: number | null,
 *   summary: string | null,
 *   startedAt: string | null,
 *   finishedAt: string | null,
 *   ageMs: number | null,
 *   envelope: Record<string, unknown> | null,
 *   error: string | null,
 * }}
 */
export function readRunState(run, options = {}) {
    const { now = Date.now(), isAlive = isProcessAlive } = options;
    const runId = String(run?.runId ?? '');
    const stateDir = String(run?.stateDir ?? '');
    const empty = {
        ok: false,
        runId,
        action: null,
        exitCode: null,
        summary: null,
        startedAt: null,
        finishedAt: null,
        ageMs: null,
        envelope: null,
    };
    if (!RUN_ID_RE.test(runId) || stateDir === '') {
        return { ...empty, state: 'unknown', resultFile: '', error: 'invalid run id' };
    }
    const files = runFilePaths(stateDir, runId);
    const base = { ...empty, resultFile: files.resultFile };

    const pending = readJsonFile(files.pendingFile);
    const pendingValue = isPlainObject(pending.value) ? pending.value : null;
    const startedAt = typeof pendingValue?.startedAt === 'string' ? pendingValue.startedAt : null;
    const startedMs = startedAt ? Date.parse(startedAt) : Number.NaN;
    const ageMs = Number.isFinite(startedMs) ? Math.max(0, now - startedMs) : null;
    const action = typeof pendingValue?.action === 'string' ? pendingValue.action : null;
    const withMeta = { ...base, action, startedAt, ageMs };

    const evaluated = evaluateResultFile(files.resultFile);
    if (evaluated.exists) {
        return {
            ...withMeta,
            state: evaluated.state,
            ok: evaluated.ok,
            exitCode: evaluated.exitCode,
            summary: evaluated.summary,
            finishedAt: evaluated.finishedAt,
            envelope: evaluated.envelope,
            error: evaluated.error,
        };
    }

    if (!pending.exists) {
        return { ...withMeta, state: 'unknown', error: `no run record for ${runId} under ${files.dir}` };
    }
    if (!pending.ok || !pendingValue) {
        return { ...withMeta, state: 'failed', error: `run record is unreadable (${pending.error ?? 'not a JSON object'})` };
    }

    const launch = readJsonFile(files.launchFile);
    const launchValue = isPlainObject(launch.value) ? launch.value : null;
    if (launch.exists && launch.ok && launchValue) {
        if (typeof launchValue.error === 'string' && launchValue.error !== '') {
            return { ...withMeta, state: 'failed', error: `detached supervisor or engine failed: ${launchValue.error}` };
        }
        const enginePid = Number(launchValue.enginePid);
        if (enginePid > 0 && isAlive(enginePid)) return { ...withMeta, state: 'running', ok: true, error: null };
        const engineExitCode = Number.isInteger(launchValue.engineExitCode) ? Number(launchValue.engineExitCode) : null;
        if (enginePid > 0 || engineExitCode !== null) {
            return {
                ...withMeta,
                state: 'failed',
                error: `engine process exited${engineExitCode === null ? '' : ` with code ${engineExitCode}`} without writing its result file`
                    + ' (detached mode discards the engine stderr; check <stateDir>\\dsh-restart.log)',
            };
        }
        // The supervisor left a record but never got an engine pid: either the
        // delay has not elapsed yet, or the supervisor died in that window.
        const launcherPid = Number(pendingValue.launcherPid);
        if (launcherPid > 0 && isAlive(launcherPid)) return { ...withMeta, state: 'running', ok: true, error: null };
        if (ageMs !== null && ageMs < LAUNCHER_START_GRACE_MS) return { ...withMeta, state: 'running', ok: true, error: null };
        return {
            ...withMeta,
            state: 'failed',
            error: 'detached supervisor exited before starting the engine (check that node and the engine script are executable)',
        };
    }

    const launcherPid = Number(pendingValue.launcherPid);
    if (launcherPid > 0 && isAlive(launcherPid)) return { ...withMeta, state: 'running', ok: true, error: null };
    if (ageMs !== null && ageMs < LAUNCHER_START_GRACE_MS) return { ...withMeta, state: 'running', ok: true, error: null };
    return {
        ...withMeta,
        state: 'failed',
        error: 'launcher exited before starting the engine (check that node and the engine script are executable)',
    };
}
