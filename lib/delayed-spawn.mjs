#!/usr/bin/env node
/**
 * Detached delayed launcher for dsh-restart-win.
 *
 * The host starts this file with `detached: true, stdio: 'ignore'` and moves on.
 * This process waits `restartDelayMs` (so the tool result is already written),
 * then starts the PowerShell engine and **stays alive until the engine exits**.
 * Because the launcher itself is detached, the engine survives the host being
 * stopped by the restart.
 *
 * Why a Node supervisor instead of spawning PowerShell detached directly: on
 * Windows, PowerShell 7 and 5.1 both exit immediately without running anything
 * when created with a detached process flag (verified on this machine; Node and
 * cmd behave normally). The detached flag therefore belongs on the supervisor,
 * and the engine runs as its ordinary child.
 *
 * Two guarantees this file owes the reader (`lib/runner.js#readRunState`):
 *
 *   1. **A run record exists from the first millisecond** (`phase: 'delayed'`)
 *      and is rewritten at every transition; an interruption, a failed spawn or
 *      an early exit always leaves `error`, so a run can never hang silently.
 *   2. **Resume-notice ownership by bytes.** Before the engine starts, the
 *      supervisor writes the notice itself with the run id in `reason` (unique
 *      per run) and remembers the exact bytes. If, after the engine exits, the
 *      file still holds those bytes, the engine never committed a shutdown and
 *      the notice is deleted; if the bytes changed, the engine wrote its own
 *      notice and that one is kept.
 *
 * The launcher reads one JSON request file instead of a long command line: no
 * quoting, no shell, and the exact argv the engine received stays auditable.
 */
import { spawn } from 'node:child_process';
import { readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { RUN_ID_RE, writeJsonAtomic } from './runner.js';

/** Upper bound accepted from a request file (also bounded by config validation). */
export const MAX_DELAY_MS = 600000;

/** How long the supervisor waits for the engine's own launch record after a handoff. */
export const HANDOFF_WAIT_MS = 8000;

/**
 * Wait for the engine that was started through the shell to report itself.
 *
 * `taskkill /T` walks the parent chain, so an engine spawned as our child dies
 * the instant it stops the host. The handoff starts it from `explorer.exe`
 * instead, which makes it a child of the shell; the engine then writes
 * `-LaunchRecord` with `via: 'handoff'`, which is what this waits for.
 *
 * @param {string} file the launch record the engine was told to write
 * @param {number} [timeoutMs] how long to wait before declaring the handoff dead
 * @returns {Promise<boolean>} true when the engine reported itself
 */
export async function waitForEngineRecord(file, timeoutMs = HANDOFF_WAIT_MS) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        try {
            const record = JSON.parse(readFileSync(file, 'utf8'));
            if (record && record.phase === 'engine-running' && record.via === 'handoff') return true;
        } catch {
            // Not written yet: the engine may still be starting.
        }
        await sleep(150);
    }
    return false;
}

/** Characters that must never reach the engine argv from a request file. */
const NUL_RE = /\u0000/;

/** Signals a supervisor can catch before Windows tears it down. */
const HANDLED_SIGNALS = ['SIGINT', 'SIGTERM', 'SIGBREAK'];

/**
 * @param {unknown} raw parsed request JSON
 * @returns {{
 *   delayMs: number,
 *   runId: string,
 *   runDir: string,
 *   execPath: string,
 *   args: string[],
 *   cwd: string,
 *   notice: { path: string, sessionId: string, reason: string } | null,
 *   engineEnv: Record<string, string> | null,
 * }}
 */
export function parseLaunchRequest(raw) {
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
        throw new Error('launch request must be a JSON object');
    }
    const { delayMs, runId, runDir, execPath, args, cwd, notice, engineEnv } = raw;
    if (typeof delayMs !== 'number' || !Number.isInteger(delayMs) || delayMs < 0 || delayMs > MAX_DELAY_MS) {
        throw new Error(`delayMs must be an integer between 0 and ${MAX_DELAY_MS}`);
    }
    if (typeof runId !== 'string' || !RUN_ID_RE.test(runId)) {
        throw new Error('runId is not a valid run id');
    }
    if (typeof runDir !== 'string' || runDir === '' || NUL_RE.test(runDir)) {
        throw new Error('runDir must be a non-empty path');
    }
    if (typeof execPath !== 'string' || execPath === '' || NUL_RE.test(execPath)) {
        throw new Error('execPath must be a non-empty path');
    }
    if (!Array.isArray(args) || args.length === 0) {
        throw new Error('args must be a non-empty array');
    }
    for (const argument of args) {
        if (typeof argument !== 'string' || NUL_RE.test(argument)) {
            throw new Error('every engine argument must be a NUL-free string');
        }
    }
    let parsedNotice = null;
    if (notice !== undefined && notice !== null) {
        if (typeof notice !== 'object' || Array.isArray(notice)) {
            throw new Error('notice must be an object or null');
        }
        const { path, sessionId, reason } = notice;
        if (typeof path !== 'string' || path === '' || NUL_RE.test(path)) {
            throw new Error('notice.path must be a non-empty path');
        }
        if (typeof sessionId !== 'string' || sessionId === '' || NUL_RE.test(sessionId)) {
            throw new Error('notice.sessionId must be a non-empty string');
        }
        if (typeof reason !== 'string' || NUL_RE.test(reason) || reason.length > 2000) {
            throw new Error('notice.reason must be a short NUL-free string');
        }
        parsedNotice = { path, sessionId, reason };
    }
    let parsedEnv = null;
    if (engineEnv !== undefined && engineEnv !== null) {
        if (typeof engineEnv !== 'object' || Array.isArray(engineEnv)) {
            throw new Error('engineEnv must be an object or null');
        }
        const entries = Object.entries(engineEnv);
        if (entries.length > 32) throw new Error('engineEnv accepts at most 32 variables');
        parsedEnv = {};
        for (const [key, value] of entries) {
            if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
                throw new Error(`engineEnv key "${key}" is not a valid environment variable name`);
            }
            if (typeof value !== 'string' || NUL_RE.test(value) || value.length > 1024) {
                throw new Error(`engineEnv.${key} must be a short string`);
            }
            parsedEnv[key] = value;
        }
    }
    return {
        delayMs,
        runId,
        runDir,
        execPath,
        args: [...args],
        cwd: typeof cwd === 'string' && cwd !== '' ? cwd : '',
        notice: parsedNotice,
        engineEnv: parsedEnv,
    };
}

/**
 * @param {string} runDir
 * @param {string} runId
 * @returns {string}
 */
export function launchFileFor(runDir, runId) {
    return join(runDir, `${runId}.launch.json`);
}

/**
 * Write the notice and return the exact bytes written, so ownership can be
 * decided later by byte comparison (the engine overwrites it with different
 * bytes, including a fresh `when`, when it commits to the shutdown).
 *
 * @param {string} file
 * @param {{ sessionId: string, reason: string, when: string }} document
 * @returns {string} the text now on disk
 */
export function writeNoticeFile(file, document) {
    const text = `${JSON.stringify(document, null, 2)}\n`;
    const temp = `${file}.tmp-${process.pid}`;
    writeFileSync(temp, text, 'utf8');
    renameSync(temp, file);
    return text;
}

/**
 * Delete the notice only when it still holds exactly the bytes this supervisor
 * wrote. Anything else (the engine's own notice, a consumed file, an unreadable
 * file) is left alone.
 *
 * @param {string | null} noticePath
 * @param {string | null} writtenText
 * @returns {'not-written' | 'deleted-stale' | 'kept-engine-notice' | 'absent' | 'kept-unreadable'}
 */
export function settleNotice(noticePath, writtenText) {
    if (!noticePath || writtenText === null) return 'not-written';
    let current;
    try {
        current = readFileSync(noticePath, 'utf8');
    } catch (error) {
        return error && error.code === 'ENOENT' ? 'absent' : 'kept-unreadable';
    }
    if (current !== writtenText) return 'kept-engine-notice';
    try {
        rmSync(noticePath, { force: true });
        return 'deleted-stale';
    } catch {
        return 'kept-unreadable';
    }
}


/** Quote one Windows argv token (CommandLineToArgvW rules; paths never contain quotes here). */
function quoteWinArg(arg) {
    if (arg === '') return '""';
    if (!/[\s"]/.test(arg)) return arg;
    let out = '"';
    let backslashes = 0;
    for (const ch of arg) {
        if (ch === '\\') { backslashes += 1; continue; }
        if (ch === '"') { out += '\\'.repeat(backslashes * 2 + 1) + '"'; backslashes = 0; continue; }
        out += '\\'.repeat(backslashes) + ch;
        backslashes = 0;
    }
    out += '\\'.repeat(backslashes * 2) + '"';
    return out;
}

/**
 * Write a VBScript that starts the engine hidden, so `explorer.exe <vbs>` runs it
 * outside the caller's process tree (and job object).
 *
 * @returns {{ ok: boolean, vbsPath: string | null, error: string | null }}
 */
function writeHandoff(request, launchFile, noticeOutcome) {
    try {
        const args = [...request.args, '-LaunchRecord', launchFile];
        const commandLine = [request.execPath, ...args].map(quoteWinArg).join(' ');
        const vbs = [
            'Set sh = CreateObject("WScript.Shell")',
            `sh.Run "${commandLine.replace(/"/g, '""')}", 0, False`,
            '',
        ].join('\r\n');
        const vbsPath = join(request.runDir, `${request.runId}.handoff.vbs`);
        writeFileSync(vbsPath, vbs, 'utf8');
        return { ok: true, vbsPath, error: null };
    } catch (error) {
        return { ok: false, vbsPath: null, error: error instanceof Error ? error.message : String(error) };
    }
}

/**
 * Wait, then run the engine to completion, always leaving a terminal record.
 *
 * @param {ReturnType<typeof parseLaunchRequest>} request
 * @returns {Promise<{ enginePid: number | null, exitCode: number | null, error: string | null, notice: string }>}
 */
export async function launch(request) {
    const launchFile = launchFileFor(request.runDir, request.runId);
    let enginePid = null;
    let finished = false;
    const record = (fields) => {
        try {
            writeJsonAtomic(launchFile, {
                runId: request.runId,
                delayMs: request.delayMs,
                at: new Date().toISOString(),
                ...fields,
            });
        } catch {
            // The record is evidence; a broken disk must not break the restart.
        }
    };
    const finish = (fields) => {
        if (finished) return;
        finished = true;
        record({ phase: 'finished', ...fields });
    };

    // A record exists before the delay, so a killed supervisor still leaves a
    // trace that readRunState can turn into a verdict.
    record({ phase: 'delayed', enginePid: null, error: null, engineEnv: request.engineEnv });

    const onSignal = (signal) => {
        finish({ enginePid, engineExitCode: null, error: `supervisor received ${signal}`, notice: 'not-written' });
        process.exit(128);
    };
    for (const signal of HANDLED_SIGNALS) process.once(signal, () => onSignal(signal));

    let noticeText = null;
    let noticeOutcome = 'not-written';
    try {
        if (request.delayMs > 0) await sleep(request.delayMs);

        if (request.notice) {
            try {
                noticeText = writeNoticeFile(request.notice.path, {
                    sessionId: request.notice.sessionId,
                    reason: `${request.notice.reason} [run ${request.runId}]`,
                    when: new Date().toISOString(),
                });
            } catch (error) {
                noticeOutcome = 'kept-unreadable';
                throw new Error(`could not write the resume notice: ${error instanceof Error ? error.message : String(error)}`);
            }
        }

        // Every host kind gets stopped with `taskkill /T`, which walks the parent
        // chain — and this supervisor sits inside that chain, so an in-tree engine
        // is killed at the moment it stops the host. That is exactly what happened
        // on `dsh web`: the host went down and nothing relaunched it. Start the
        // engine through the shell instead (`explorer.exe <vbs>` → WScript), which
        // parents it outside our tree, then wait for the engine's own launch
        // record. A host that blocks script hosts falls back to the in-tree spawn.
        //
        // `DSH_RESTART_HANDOFF=0` forces the old in-tree path.
        if (process.env.DSH_RESTART_HANDOFF !== '0') {
            const handoff = writeHandoff(request, launchFile, noticeOutcome);
            if (handoff.ok) {
                let explorerStarted = false;
                try {
                    const explorer = spawn('explorer.exe', [handoff.vbsPath], {
                        detached: true,
                        stdio: 'ignore',
                        windowsHide: true,
                    });
                    explorer.unref();
                    explorerStarted = true;
                } catch {
                    // Fall through to the in-tree path below.
                }
                if (explorerStarted) {
                    record({ phase: 'handoff', enginePid: null, error: null, handoff: handoff.vbsPath });
                    if (await waitForEngineRecord(launchFile)) {
                        return { enginePid: null, exitCode: null, error: null, notice: noticeOutcome };
                    }
                    // The shell accepted the script but no engine reported in.
                    record({ phase: 'handoff-timeout', enginePid: null, error: null, handoff: handoff.vbsPath });
                }
            }
        }
        const child = spawn(request.execPath, request.args, {
            stdio: 'ignore',
            windowsHide: true,
            ...(request.cwd ? { cwd: request.cwd } : {}),
            env: { ...process.env, ...(request.engineEnv ?? {}) },
        });
        const spawned = await new Promise((resolvePromise) => {
            child.once('spawn', () => resolvePromise({ ok: true, error: null }));
            child.once('error', (error) => resolvePromise({ ok: false, error: String(error?.message ?? error) }));
        });
        if (!spawned.ok) {
            noticeOutcome = settleNotice(request.notice?.path ?? null, noticeText);
            finish({ enginePid: null, engineExitCode: null, error: spawned.error, notice: noticeOutcome });
            return { enginePid: null, exitCode: null, error: spawned.error, notice: noticeOutcome };
        }
        enginePid = typeof child.pid === 'number' ? child.pid : null;
        record({ phase: 'engine-running', enginePid, error: null });
        const exitCode = await new Promise((resolvePromise) => {
            child.once('close', (code) => resolvePromise(typeof code === 'number' ? code : null));
            child.once('error', () => resolvePromise(null));
        });
        noticeOutcome = settleNotice(request.notice?.path ?? null, noticeText);
        finish({ enginePid, engineExitCode: exitCode, error: null, notice: noticeOutcome, finishedAt: new Date().toISOString() });
        return { enginePid, exitCode, error: null, notice: noticeOutcome };
    } catch (error) {
        noticeOutcome = settleNotice(request.notice?.path ?? null, noticeText);
        finish({
            enginePid,
            engineExitCode: null,
            error: error instanceof Error ? error.message : String(error),
            notice: noticeOutcome,
        });
        throw error;
    }
}

/**
 * @param {string[]} argv `process.argv`
 * @returns {Promise<number>} exit code
 */
export async function main(argv) {
    const requestFile = argv[2];
    if (!requestFile) {
        process.stderr.write('delayed-spawn: missing launch request path\n');
        return 64;
    }
    let request;
    try {
        request = parseLaunchRequest(JSON.parse(readFileSync(requestFile, 'utf8')));
    } catch (error) {
        process.stderr.write(`delayed-spawn: ${error instanceof Error ? error.message : String(error)}\n`);
        return 64;
    }
    try {
        const outcome = await launch(request);
        return outcome.error ? 1 : 0;
    } catch (error) {
        process.stderr.write(`delayed-spawn: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
        return 1;
    }
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (entry !== '' && import.meta.url === entry) {
    process.exitCode = await main(process.argv);
}
