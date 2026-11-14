/**
 * Tool definitions for dsh-restart-win.
 *
 * This module deliberately imports **nothing from the host**: `defineTool` is
 * injected by `lib/index.js` after it resolves `@deepseek-ai/dsh-tools`. That
 * keeps the tool surface loadable in a plain Node process (`npm test` does
 * exactly that) and means a machine without PowerShell only fails when a tool
 * actually runs, with an actionable message.
 */
import { join, resolve, sep } from 'node:path';
import {
    asPathValue,
    assertActionRequirements,
    resolveInvocation,
} from './config.js';
import {
    ensureDirectory,
    isFile,
    resolveDshHome,
    resolvePwsh,
    resolveStateDir,
    runsDir,
} from './paths.js';
import {
    ACTIONS,
    DETACHED_ACTIONS,
    INJECT_HOST_ENV_KEY,
    buildScriptArgs,
    engineEnv,
    evaluateResultFile,
    extractJsonObject,
    newRunId,
    readRunState,
    runFilePaths,
    runForeground,
    spawnLauncher,
    writeJsonAtomic,
    writeLaunchRequest,
} from './runner.js';

/** Tool names registered with the host. */
export const TOOL_NAMES = Object.freeze({
    restart: 'win_restart',
    status: 'win_restart_status',
    preflight: 'win_restart_preflight',
    result: 'win_restart_result',
});

/** Nullable string in the output JSON Schema subset. */
const NULLABLE_STRING = Object.freeze({ oneOf: [{ type: 'string' }, { type: 'null' }] });
/** Nullable integer in the output JSON Schema subset. */
const NULLABLE_INTEGER = Object.freeze({ oneOf: [{ type: 'integer' }, { type: 'null' }] });

/** Extra budget `win_restart_result` may spend waiting for a run to settle. */
const RESULT_WAIT_BUDGET_MS = 120000;

/** @param {unknown} error */
function errorMessage(error) {
    return error instanceof Error ? error.message : String(error);
}

/** @param {string} text @param {number} [max] */
function tail(text, max = 600) {
    const source = String(text ?? '').trim();
    return source.length <= max ? source : `…${source.slice(-max)}`;
}

/**
 * Canonical path of the smart-restart pending notice.
 *
 * @param {string} dshHome absolute DSH home
 * @returns {string}
 */
export function pendingNoticePath(dshHome) {
    return join(dshHome, '.smart-restart', 'pending-notice.json');
}

/**
 * Write the smart-restart pending notice the host consumes after the restart.
 *
 * Same shape and location as the engine's own `Write-PendingNotice`
 * (`<dshHome>/.smart-restart/pending-notice.json`, UTF-8 without BOM), and
 * written **before** anything is spawned so the notice survives a host that
 * dies during the delay window. The detached supervisor rewrites it with the
 * run id in `reason` right before the engine starts, then decides by byte
 * comparison whether the engine committed a shutdown (see lib/delayed-spawn.mjs).
 *
 * @param {{ dshHome: string, sessionId: string, reason: string }} input
 * @returns {{ written: boolean, path: string | null, error: string | null }}
 */
export function writePendingNotice(input) {
    const { dshHome, sessionId, reason } = input;
    if (!sessionId) return { written: false, path: null, error: null };
    const file = pendingNoticePath(dshHome);
    try {
        ensureDirectory(join(dshHome, '.smart-restart'));
        writeJsonAtomic(file, {
            sessionId,
            reason,
            when: new Date().toISOString(),
        });
        return { written: true, path: file, error: null };
    } catch (error) {
        return { written: false, path: file, error: errorMessage(error) };
    }
}

/**
 * @param {unknown} exec tool execution context supplied by the host
 * @returns {string} the calling session id, or `''`
 */
export function sessionIdFromExec(exec) {
    try {
        const id = exec?.agent?.id;
        return typeof id === 'string' ? id : '';
    } catch {
        return '';
    }
}

/**
 * Build the four tool definitions.
 *
 * @param {{
 *   defineTool: Function,
 *   config: Readonly<Record<string, unknown>>,
 *   paths: { dshHome: string, stateDir: string, engineScript: string, launcherScript: string },
 *   env?: Record<string, string | undefined>,
 *   platform?: string,
 *   logger?: { warn: (...args: unknown[]) => void },
 * }} options
 * @returns {object[]} tool definitions, one per enabled `config.tools` switch
 */
export function createToolDefinitions(options) {
    const {
        defineTool,
        config,
        paths,
        env = process.env,
        platform = process.platform,
        logger = console,
    } = options;
    if (typeof defineTool !== 'function') {
        throw new TypeError('createToolDefinitions: defineTool must be a function');
    }
    if (!config || typeof config !== 'object') {
        throw new TypeError('createToolDefinitions: config is required');
    }
    if (!paths || typeof paths !== 'object') {
        throw new TypeError('createToolDefinitions: paths are required');
    }

    /**
     * @param {Record<string, unknown>} args
     * @param {unknown} exec
     * @returns {Readonly<Record<string, unknown>>}
     */
    function invocationFor(args, exec) {
        const call = { ...args };
        delete call.action;
        delete call.mode;
        delete call.dryRun;
        delete call.waitMs;
        delete call.runId;
        delete call.resultFile;
        if (call.session === undefined) call.session = sessionIdFromExec(exec);
        return resolveInvocation(config, call);
    }

    /**
     * @param {Record<string, unknown>} invocation
     * @returns {{ path: string, source: string }}
     */
    function pwshFor(invocation) {
        return resolvePwsh({ pwshPath: String(invocation.pwshPath ?? '') }, { env, platform });
    }

    /**
     * Start one detached run and return immediately. The returned object is the
     * tool's canonical value: `{ started, runId, resultFile }` plus context.
     *
     * @param {string} action
     * @param {Readonly<Record<string, unknown>>} invocation
     */
    async function startDetachedRun(action, invocation) {
        const pwsh = pwshFor(invocation);
        if (!isFile(paths.engineScript)) {
            throw new Error(`engine script is missing: ${paths.engineScript}`);
        }
        const stateDir = resolveStateDir({ stateDir: String(invocation.stateDir ?? '') }, env);
        const dshHome = resolveDshHome({ dshHome: String(invocation.dshHome ?? '') }, env);
        ensureDirectory(runsDir(stateDir));
        const runId = newRunId();
        const files = runFilePaths(stateDir, runId);
        const sessionId = String(invocation.session ?? '');
        const reason = String(invocation.reason ?? '');
        const notice = action === 'restart'
            ? writePendingNotice({ dshHome, sessionId, reason })
            : { written: false, path: null, error: null };
        if (notice.error) logger.warn('[dsh-restart-win] could not write pending-notice.json:', notice.error);

        const pending = {
            runId,
            action,
            startedAt: new Date().toISOString(),
            delayMs: invocation.delayMs,
            resultFile: files.resultFile,
            engineScript: paths.engineScript,
            pwshPath: pwsh.path,
            pwshSource: pwsh.source,
            profile: invocation.profile,
            port: invocation.port,
            sessionId: sessionId || null,
            pendingNotice: notice.path,
            hostPid: process.pid,
            launcherPid: null,
        };
        writeJsonAtomic(files.pendingFile, pending);

        const args = buildScriptArgs({
            scriptPath: paths.engineScript,
            action,
            invocation,
            resultFile: files.resultFile,
            noWait: true,
            platform,
        });
        writeLaunchRequest(files.requestFile, {
            delayMs: Number(invocation.delayMs),
            runId,
            runDir: files.dir,
            execPath: pwsh.path,
            args,
            // The supervisor merges these into the engine's environment, so the
            // detached path behaves exactly like the foreground one.
            engineEnv: config.injectHostEnv === false ? { [INJECT_HOST_ENV_KEY]: '0' } : null,
            // The supervisor rewrites the notice with the run id in `reason`
            // right before the engine starts, so it can later tell its own bytes
            // from the engine's by exact comparison.
            notice: action === 'restart' && sessionId
                ? {
                    path: pendingNoticePath(dshHome),
                    sessionId,
                    reason: reason || 'dsh-restart-win restart',
                }
                : null,
        });

        // A run record exists before the supervisor is even spawned: if the
        // supervisor cannot start (or is killed before its first write), the run
        // still resolves to `failed` with a reason instead of hanging.
        writeJsonAtomic(files.launchFile, {
            runId,
            phase: 'scheduled',
            enginePid: null,
            engineExitCode: null,
            error: null,
            delayMs: Number(invocation.delayMs),
            at: new Date().toISOString(),
        });

        let launcherPid = null;
        try {
            const spawned = spawnLauncher({
                nodePath: process.execPath,
                launcherPath: paths.launcherScript,
                requestFile: files.requestFile,
                env: engineEnv(env, config.injectHostEnv),
            });
            launcherPid = spawned.pid;
        } catch (error) {
            writeJsonAtomic(files.launchFile, {
                runId,
                phase: 'finished',
                enginePid: null,
                engineExitCode: null,
                error: `could not start the detached supervisor: ${errorMessage(error)}`,
                delayMs: Number(invocation.delayMs),
                at: new Date().toISOString(),
            });
            throw new Error(`could not start the detached launcher: ${errorMessage(error)}`);
        }
        writeJsonAtomic(files.pendingFile, { ...pending, launcherPid });

        return {
            ok: true,
            action,
            started: true,
            state: 'running',
            runId,
            resultFile: files.resultFile,
            exitCode: null,
            summary: null,
            error: null,
            delayMs: Number(invocation.delayMs),
            detail: {
                pwshPath: pwsh.path,
                pwshSource: pwsh.source,
                engineScript: paths.engineScript,
                stateDir,
                dshHome,
                pendingNotice: notice.path,
                pendingNoticeWritten: notice.written,
                launcherPid,
                args,
            },
        };
    }

    /**
     * Run a short action in the foreground and normalize the engine envelope.
     *
     * @param {string} action
     * @param {Readonly<Record<string, unknown>>} invocation
     * @param {unknown} exec
     */
    async function runForegroundAction(action, invocation, exec) {
        const pwsh = pwshFor(invocation);
        if (!isFile(paths.engineScript)) {
            throw new Error(`engine script is missing: ${paths.engineScript}`);
        }
        const args = buildScriptArgs({
            scriptPath: paths.engineScript,
            action,
            invocation,
            resultFile: '',
            noWait: false,
            platform,
        });
        const run = await runForeground({
            execPath: pwsh.path,
            args,
            timeoutMs: config.toolTimeoutMs,
            signal: exec?.signal,
            env: engineEnv(env, config.injectHostEnv),
        });
        const envelope = extractJsonObject(run.stdout);
        const engineExit = envelope && Number.isInteger(envelope.exitCode) ? Number(envelope.exitCode) : null;
        const exitCode = engineExit ?? run.exitCode;
        let error = null;
        if (!envelope) {
            error = run.aborted
                ? 'the call was cancelled before the engine returned a result'
                : run.timedOut
                    ? `engine did not answer within ${config.toolTimeoutMs} ms`
                    : `engine exited with code ${run.exitCode ?? 'unknown'} without a JSON envelope`
                        + (run.stderr ? `: ${tail(run.stderr)}` : '');
        } else if (envelope.ok !== true || (engineExit !== null && engineExit !== 0)) {
            error = typeof envelope.error === 'string' && envelope.error !== ''
                ? envelope.error
                : `engine reported result "${typeof envelope.result === 'string' ? envelope.result : 'unknown'}" with exit code ${exitCode ?? 'unknown'}`;
        }
        const ok = envelope !== null && envelope.ok === true && (engineExit === null || engineExit === 0) && !run.aborted;
        return {
            ok,
            exitCode,
            envelope,
            summary: typeof envelope?.result === 'string' ? envelope.result : null,
            error,
            durationMs: run.durationMs,
            timedOut: run.timedOut,
            aborted: run.aborted,
            stderrTail: run.stderr ? tail(run.stderr) : null,
            stdoutTail: run.stdout && !envelope ? tail(run.stdout) : null,
        };
    }

    /**
     * @param {Readonly<Record<string, unknown>>} invocation
     * @param {unknown} exec
     */
    async function statusFor(invocation, exec) {
        const run = await runForegroundAction('status', invocation, exec);
        const status = run.envelope && typeof run.envelope.status === 'object' && run.envelope.status !== null
            ? run.envelope.status
            : null;
        const warnings = Array.isArray(run.envelope?.warnings)
            ? run.envelope.warnings.map((warning) => String(warning))
            : [];
        let error = run.error;
        if (!error && !status) {
            error = 'engine status envelope has no `status` object (contract §3.3)';
        }
        return {
            ok: run.ok && status !== null,
            state: run.ok && status !== null ? 'ok' : 'failed',
            result: run.summary,
            version: typeof run.envelope?.version === 'string' ? run.envelope.version : null,
            exitCode: run.exitCode,
            durationMs: run.durationMs,
            hostUrl: typeof run.envelope?.hostUrl === 'string' ? run.envelope.hostUrl : null,
            targetPid: Number.isInteger(run.envelope?.targetPid) ? Number(run.envelope.targetPid) : null,
            warnings,
            status,
            stateDir: typeof run.envelope?.stateDir === 'string' ? run.envelope.stateDir : null,
            logPath: typeof run.envelope?.logPath === 'string' ? run.envelope.logPath : null,
            error,
            stderrTail: run.stderrTail,
        };
    }

    /** @param {string} action @param {Record<string, unknown>} extra */
    function failure(action, extra) {
        return {
            ok: false,
            action,
            started: false,
            state: 'failed',
            runId: null,
            resultFile: null,
            exitCode: null,
            summary: null,
            delayMs: 0,
            detail: null,
            ...extra,
        };
    }

    /** @param {string} name @param {string} text */
    function textLine(text) {
        return { type: 'text', text };
    }

    const definitions = [];
    const commonOverrides = {
        profile: { type: 'string', description: 'DSH profile to restart (default: the configured profile).' },
        hostKind: {
            type: 'string',
            enum: ['auto', 'web', 'desktop'],
            description: 'Host shape: auto (detect), web (a `dsh web` process on the configured port), or desktop '
                + '(the DSH Desktop Electron shell whose host child listens on a random port). Default: configured hostKind (auto).',
        },
        port: { type: 'integer', description: 'Host port used to find the running instance (default: configured port; ignored for desktop, where the port is discovered).' },
        bindHost: { type: 'string', description: 'Host bind address used for probes (default: configured bindHost).' },
        dshHome: { type: 'string', description: 'DSH home directory (default: configured dshHome, then $DSH_HOME, then %USERPROFILE%\\.dsh).' },
        stateDir: { type: 'string', description: 'Engine state/log directory (default: configured stateDir, then %LOCALAPPDATA%\\dsh-restart).' },
        pwshPath: { type: 'string', description: 'PowerShell executable to use (default: pwsh, then powershell.exe from PATH).' },
    };

    const timeOverrides = {
        readySec: { type: 'integer', description: 'Seconds to wait for the restarted host to become ready (default 90).' },
        verifyReadySec: { type: 'integer', description: 'Seconds to wait for the deep-verification instance (default 150).' },
        graceSec: { type: 'integer', description: 'Graceful stop grace period in seconds (default 3).' },
        portFreeSec: { type: 'integer', description: 'Seconds to wait for the old port to be released (default 30).' },
    };

    if (config.tools.restart) {
        definitions.push(defineTool({
            name: TOOL_NAMES.restart,
            description: 'Restart (or start/stop/dry-run/record/register) the DSH Web host on Windows through the dsh-restart engine. '
                + 'Restart-class actions return immediately with { started, runId, resultFile } and act only after restartDelayMs, '
                + 'so this call\'s result is written before the host can die; read the outcome later with win_restart_result.',
            parameters: {
                action: {
                    type: 'string',
                    enum: [...ACTIONS],
                    description: 'restart = safe full restart (default); start = launch only; stop = stop only; status = read-only snapshot; '
                        + 'dry_run = rehearse without changing anything; record = save the real launch command; '
                        + 'task_register / task_unregister = manage the scheduled task; preflight / verify_only = long isolated verification.',
                },
                fast: { type: 'boolean', description: 'Skip deep verification. The engine still refuses to stop a running instance unless forceUnverified is also true.' },
                forceUnverified: { type: 'boolean', description: 'Explicitly accept stopping an instance that was not deep-verified (only meaningful with fast).' },
                viaTask: { type: 'boolean', description: 'Let the scheduled task perform the restart, escaping the host process tree.' },
                dryRun: { type: 'boolean', description: 'Rehearse the restart without stopping anything (only valid with action=restart; maps to the engine dry-run action).' },
                tryCtrlC: { type: 'boolean', description: 'Try a graceful Ctrl+C stop before terminating the instance.' },
                waitIdleSec: { type: 'integer', description: 'Wait up to this many seconds for the session to go idle before restarting (0 = do not wait).' },
                idleMaxSec: { type: 'integer', description: 'Cap for the idle wait, in seconds (default 300).' },
                delayMs: { type: 'integer', description: 'Detached actions: delay before the engine touches the host (default: configured restartDelayMs).' },
                ...commonOverrides,
                taskName: { type: 'string', description: 'Scheduled-task name (default: configured taskName).' },
                ...timeOverrides,
                session: { type: 'string', description: 'Session id to pin the post-restart notice to (default: the calling session).' },
                reason: { type: 'string', description: 'Human-readable note carried into the post-restart notice.' },
                recordCommand: { type: 'string', description: 'Exactly the command that started the host (required for action=record).' },
                recordWorkingDirectory: { type: 'string', description: 'Working directory the host was started in (used by action=record).' },
                verifyTempRoot: { type: 'string', description: 'Temp directory root for the isolated verification instance (default: %TEMP%).' },
            },
            output: {
                schema: {
                    type: 'object',
                    additionalProperties: false,
                    properties: {
                        ok: { type: 'boolean', required: true },
                        action: { type: 'string', required: true },
                        started: { type: 'boolean', required: true },
                        state: { type: 'string', enum: ['ok', 'failed', 'running'], required: true },
                        runId: NULLABLE_STRING,
                        resultFile: NULLABLE_STRING,
                        exitCode: NULLABLE_INTEGER,
                        summary: NULLABLE_STRING,
                        error: NULLABLE_STRING,
                        delayMs: { type: 'integer' },
                        detail: { type: 'json', description: 'Action-specific context (engine argv, resolved PowerShell, status object for action=status).' },
                    },
                },
                render: (_args, value) => {
                    const lines = [];
                    if (value.state === 'running') {
                        lines.push(textLine(
                            `${value.action}: scheduled — the engine acts in ${value.delayMs} ms, after this result is written.`,
                        ));
                        lines.push(textLine(
                            `Run id ${value.runId}; read the outcome with win_restart_result(runId: "${value.runId}"). Result file: ${value.resultFile}`,
                        ));
                    } else if (value.ok) {
                        lines.push(textLine(`${value.action}: ok${value.summary ? ` (${value.summary})` : ''}${value.exitCode === null ? '' : ` [exit ${value.exitCode}]`}.`));
                    } else {
                        lines.push(textLine(
                            `${value.action}: FAILED${value.exitCode === null ? '' : ` (exit ${value.exitCode})`}${value.summary ? ` — ${value.summary}` : ''}${value.error ? `: ${value.error}` : ''}`,
                        ));
                    }
                    return lines;
                },
            },
            timeoutMs: config.toolTimeoutMs,
            async execute(args, exec) {
                const requested = typeof args.action === 'string' ? args.action : 'restart';
                if (!ACTIONS.includes(requested)) {
                    return failure(requested, { error: `unknown action "${requested}"` });
                }
                let action = requested;
                if (args.dryRun === true) {
                    if (requested !== 'restart') {
                        return failure(requested, { error: 'dryRun is only valid with action "restart"' });
                    }
                    action = 'dry_run';
                }
                let invocation;
                try {
                    invocation = invocationFor(args, exec);
                    assertActionRequirements(action, invocation);
                } catch (error) {
                    return failure(action, { error: errorMessage(error) });
                }
                try {
                    if (action === 'status') {
                        const status = await statusFor(invocation, exec);
                        return {
                            ok: status.ok,
                            action,
                            started: false,
                            state: status.state,
                            runId: null,
                            resultFile: null,
                            exitCode: status.exitCode,
                            summary: status.result,
                            error: status.error,
                            delayMs: 0,
                            detail: { status: status.status, hostUrl: status.hostUrl, warnings: status.warnings },
                        };
                    }
                    if (DETACHED_ACTIONS.includes(action)) {
                        return await startDetachedRun(action, invocation);
                    }
                    const run = await runForegroundAction(action, invocation, exec);
                    return {
                        ok: run.ok,
                        action,
                        started: false,
                        state: run.ok ? 'ok' : 'failed',
                        runId: null,
                        resultFile: null,
                        exitCode: run.exitCode,
                        summary: run.summary,
                        error: run.error,
                        delayMs: 0,
                        detail: {
                            envelope: run.envelope,
                            warnings: Array.isArray(run.envelope?.warnings) ? run.envelope.warnings : [],
                            stderrTail: run.stderrTail,
                        },
                    };
                } catch (error) {
                    return failure(action, { error: errorMessage(error) });
                }
            },
        }));
    }

    if (config.tools.status) {
        definitions.push(defineTool({
            name: TOOL_NAMES.status,
            description: 'Read-only snapshot of the DSH Web host on Windows: engine version, HTTP probe, discovered instances, launch URL, '
                + 'boot record, last restart and marker. Runs in the foreground and never changes anything.',
            parameters: {
                ...commonOverrides,
            },
            output: {
                schema: {
                    type: 'object',
                    additionalProperties: false,
                    properties: {
                        ok: { type: 'boolean', required: true },
                        state: { type: 'string', enum: ['ok', 'failed'], required: true },
                        result: NULLABLE_STRING,
                        version: NULLABLE_STRING,
                        exitCode: NULLABLE_INTEGER,
                        durationMs: NULLABLE_INTEGER,
                        hostUrl: NULLABLE_STRING,
                        targetPid: NULLABLE_INTEGER,
                        warnings: { type: 'array', items: { type: 'string' } },
                        status: { type: 'json', description: 'The engine `status` object passed through unchanged (instances / http / serving / bootRecord / lastRestart / marker / launchUrl …).' },
                        stateDir: NULLABLE_STRING,
                        logPath: NULLABLE_STRING,
                        error: NULLABLE_STRING,
                        stderrTail: NULLABLE_STRING,
                    },
                },
                render: (_args, value) => {
                    if (value.error && value.state !== 'ok') {
                        return [textLine(`win_restart_status failed: ${value.error}`)];
                    }
                    try {
                        const status = value.status ?? {};
                        const facts = [];
                        if (typeof status.http === 'string') facts.push(`http ${status.http}`);
                        if (typeof status.serving === 'boolean') facts.push(status.serving ? 'serving' : 'not serving');
                        if (Array.isArray(status.instances)) facts.push(`${status.instances.length} instance(s)`);
                        const first = Array.isArray(status.instances) ? status.instances[0] : null;
                        const pid = Number.isInteger(first?.pid) ? first.pid : value.targetPid;
                        if (Number.isInteger(pid)) facts.push(`pid ${pid}`);
                        if (value.hostUrl) facts.push(`url ${value.hostUrl}`);
                        const lines = [textLine(`DSH status: ${facts.length ? facts.join(', ') : 'no facts reported'}`)];
                        if (value.error) lines.push(textLine(`note: ${value.error}`));
                        return lines;
                    } catch {
                        return [textLine('DSH status: reported, but the snapshot could not be summarized.')];
                    }
                },
            },
            timeoutMs: config.toolTimeoutMs,
            async execute(args, exec) {
                let invocation;
                try {
                    invocation = invocationFor(args, exec);
                } catch (error) {
                    return {
                        ok: false,
                        state: 'failed',
                        result: null,
                        version: null,
                        exitCode: null,
                        durationMs: null,
                        hostUrl: null,
                        targetPid: null,
                        warnings: [],
                        status: null,
                        stateDir: null,
                        logPath: null,
                        error: errorMessage(error),
                        stderrTail: null,
                    };
                }
                try {
                    return await statusFor(invocation, exec);
                } catch (error) {
                    return {
                        ok: false,
                        state: 'failed',
                        result: null,
                        version: null,
                        exitCode: null,
                        durationMs: null,
                        hostUrl: null,
                        targetPid: null,
                        warnings: [],
                        status: null,
                        stateDir: null,
                        logPath: null,
                        error: errorMessage(error),
                        stderrTail: null,
                    };
                }
            },
        }));
    }

    if (config.tools.preflight) {
        definitions.push(defineTool({
            name: TOOL_NAMES.preflight,            description: 'Run the long, isolated preflight of the dsh-restart engine (symlink permission check + a real throw-away host boot in a temporary home). '
                + 'Nothing production is touched. Returns immediately with { started, runId, resultFile }; read the verdict with win_restart_result.',
            parameters: {
                mode: {
                    type: 'string',
                    enum: ['preflight', 'verify_only'],
                    description: 'preflight = symlink permission check plus deep verification (default); verify_only = deep verification only.',
                },
                delayMs: { type: 'integer', description: 'Delay before the isolated run starts (default: configured restartDelayMs).' },
                verifyTempRoot: { type: 'string', description: 'Temp directory root for the isolated instance (default: %TEMP%).' },
                ...commonOverrides,
                ...timeOverrides,
            },
            output: {
                schema: {
                    type: 'object',
                    additionalProperties: false,
                    properties: {
                        ok: { type: 'boolean', required: true },
                        started: { type: 'boolean', required: true },
                        state: { type: 'string', enum: ['running', 'failed'], required: true },
                        mode: { type: 'string', enum: ['preflight', 'verify_only'], required: true },
                        runId: NULLABLE_STRING,
                        resultFile: NULLABLE_STRING,
                        delayMs: NULLABLE_INTEGER,
                        error: NULLABLE_STRING,
                        detail: { type: 'json', description: 'Resolved PowerShell, engine script and state directory used for the run.' },
                    },
                },
                render: (_args, value) => {
                    if (value.state === 'running') {
                        return [
                            textLine(`${value.mode}: started in the background (run ${value.runId}); it acts in ${value.delayMs} ms.`),
                            textLine(`Read the verdict with win_restart_result(runId: "${value.runId}"). Result file: ${value.resultFile}`),
                        ];
                    }
                    return [textLine(`${value.mode}: could not start${value.error ? ` — ${value.error}` : ''}`)];
                },
            },
            timeoutMs: config.toolTimeoutMs,
            async execute(args, exec) {
                const mode = args.mode === 'verify_only' ? 'verify_only' : 'preflight';
                let invocation;
                try {
                    invocation = invocationFor(args, exec);
                    assertActionRequirements(mode, invocation);
                } catch (error) {
                    return {
                        ok: false,
                        started: false,
                        state: 'failed',
                        mode,
                        runId: null,
                        resultFile: null,
                        delayMs: null,
                        error: errorMessage(error),
                        detail: null,
                    };
                }
                try {
                    const run = await startDetachedRun(mode, invocation);
                    return {
                        ok: run.ok,
                        started: run.started,
                        state: 'running',
                        mode,
                        runId: run.runId,
                        resultFile: run.resultFile,
                        delayMs: run.delayMs,
                        error: run.error,
                        detail: { ...run.detail, verifyTimeoutMs: config.verifyTimeoutMs },
                    };
                } catch (error) {
                    return {
                        ok: false,
                        started: false,
                        state: 'failed',
                        mode,
                        runId: null,
                        resultFile: null,
                        delayMs: null,
                        error: errorMessage(error),
                        detail: null,
                    };
                }
            },
        }));
    }

    if (config.tools.result) {
        definitions.push(defineTool({
            name: TOOL_NAMES.result,
            description: 'Read the result of a detached dsh-restart run by runId (or an explicit resultFile inside stateDir). '
                + 'Reports ok / failed / running, plus the engine envelope when the run finished.',
            parameters: {
                runId: { type: 'string', description: 'Run id returned by win_restart or win_restart_preflight (e.g. 20260101-120000-a1b2c3).' },
                resultFile: { type: 'string', description: 'Explicit result file path; must live inside stateDir.' },
                stateDir: { type: 'string', description: 'State directory override; only needed when the run used a non-default one.' },
                waitMs: { type: 'integer', description: 'Wait up to this many milliseconds for a running task to finish (default 0 = read once).' },
            },
            output: {
                schema: {
                    type: 'object',
                    additionalProperties: false,
                    properties: {
                        ok: { type: 'boolean', required: true },
                        state: { type: 'string', enum: ['ok', 'failed', 'running', 'unknown'], required: true },
                        runId: NULLABLE_STRING,
                        resultFile: NULLABLE_STRING,
                        action: NULLABLE_STRING,
                        startedAt: NULLABLE_STRING,
                        finishedAt: NULLABLE_STRING,
                        exitCode: NULLABLE_INTEGER,
                        summary: NULLABLE_STRING,
                        ageMs: NULLABLE_INTEGER,
                        error: NULLABLE_STRING,
                        envelope: { type: 'json', description: 'The engine result envelope exactly as written by -ResultFile (ok/result/exitCode/version/steps/…).' },
                    },
                },
                render: (_args, value) => {
                    if (value.state === 'running') {
                        const waited = Number.isInteger(value.ageMs) ? ` after ${Math.round(value.ageMs / 1000)}s` : '';
                        return [textLine(`run ${value.runId ?? '?'}: still running${waited}. Call win_restart_result again when it finishes.`)];
                    }
                    if (value.state === 'unknown') {
                        return [textLine(`run ${value.runId ?? '?'}: no record${value.error ? ` — ${value.error}` : ''}.`)];
                    }
                    const head = `${value.action ?? 'run'} ${value.runId ?? ''}: ${value.state === 'ok' ? 'ok' : 'FAILED'}`;
                    const facts = [
                        value.summary ? `result ${value.summary}` : null,
                        Number.isInteger(value.exitCode) ? `exit ${value.exitCode}` : null,
                        value.error ?? null,
                    ].filter(Boolean);
                    return [textLine(facts.length ? `${head} — ${facts.join(', ')}` : head)];
                },
            },
            timeoutMs: config.toolTimeoutMs + RESULT_WAIT_BUDGET_MS,
            async execute(args, exec) {
                /** @returns {object} */
                const unknown = (error) => ({
                    ok: false,
                    state: 'unknown',
                    runId: typeof args.runId === 'string' ? args.runId : null,
                    resultFile: typeof args.resultFile === 'string' ? args.resultFile : null,
                    action: null,
                    startedAt: null,
                    finishedAt: null,
                    exitCode: null,
                    summary: null,
                    ageMs: null,
                    error,
                    envelope: null,
                });
                const waitMs = Number.isInteger(args.waitMs) ? Math.max(0, Math.min(120000, args.waitMs)) : 0;
                let stateDir;
                try {
                    stateDir = resolveStateDir({ stateDir: String(args.stateDir ?? config.stateDir ?? '') }, env);
                } catch (error) {
                    return unknown(errorMessage(error));
                }
                if (typeof args.resultFile === 'string' && args.resultFile !== '') {
                    let file;
                    try {
                        file = asPathValue(args.resultFile, 'resultFile', { allowEmpty: false });
                    } catch (error) {
                        return unknown(errorMessage(error));
                    }
                    const root = stateDir.endsWith(sep) ? stateDir : `${stateDir}${sep}`;
                    const normalizedFile = resolve(file);
                    const normalizedRoot = resolve(root);
                    if (platform === 'win32'
                        ? !normalizedFile.toLowerCase().startsWith(normalizedRoot.toLowerCase())
                        : !normalizedFile.startsWith(normalizedRoot)) {
                        return unknown(`resultFile must live inside stateDir (${stateDir})`);
                    }
                    const evaluated = evaluateResultFile(normalizedFile);
                    if (!evaluated.exists) {
                        return {
                            ok: false,
                            state: 'unknown',
                            runId: typeof args.runId === 'string' ? args.runId : null,
                            resultFile: normalizedFile,
                            action: null,
                            startedAt: null,
                            finishedAt: null,
                            exitCode: null,
                            summary: null,
                            ageMs: null,
                            error: 'result file does not exist yet',
                            envelope: null,
                        };
                    }
                    return {
                        ok: evaluated.ok,
                        state: evaluated.state,
                        runId: typeof args.runId === 'string' ? args.runId : null,
                        resultFile: normalizedFile,
                        action: typeof evaluated.envelope?.action === 'string' ? evaluated.envelope.action : null,
                        startedAt: null,
                        finishedAt: evaluated.finishedAt,
                        exitCode: evaluated.exitCode,
                        summary: evaluated.summary,
                        ageMs: null,
                        error: evaluated.error,
                        envelope: evaluated.envelope,
                    };
                }
                if (typeof args.runId !== 'string' || args.runId === '') {
                    return unknown('pass runId or resultFile');
                }
                const runId = args.runId;
                const first = readRunState({ stateDir, runId });
                let deadline = Date.now() + waitMs;
                // A deep-verification run is budgeted by verifyTimeoutMs: never wait
                // longer than the configured verification window for one.
                if (first.action === 'preflight' || first.action === 'verify_only') {
                    const startedMs = first.startedAt ? Date.parse(first.startedAt) : Number.NaN;
                    if (Number.isFinite(startedMs)) deadline = Math.min(deadline, startedMs + config.verifyTimeoutMs);
                }
                let state = first;
                while (state.state === 'running' && Date.now() < deadline && !exec?.signal?.aborted) {
                    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
                    state = readRunState({ stateDir, runId });
                }
                return {
                    ok: state.state === 'ok' || state.state === 'running',
                    state: state.state,
                    runId: state.runId,
                    resultFile: state.resultFile || null,
                    action: state.action,
                    startedAt: state.startedAt,
                    finishedAt: state.finishedAt,
                    exitCode: state.exitCode,
                    summary: state.summary,
                    ageMs: state.ageMs,
                    error: state.error,
                    envelope: state.envelope,
                };
            },
        }));
    }

    return definitions;
}
