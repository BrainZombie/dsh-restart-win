/**
 * The install_plugin tool: put a plugin into the current profile through the
 * safe channel (`scripts/dsh-plugin-install.ps1`) instead of letting pnpm
 * rebuild the tree under a running host.
 *
 * Why a separate tool and not a patch to DSH's own `plugin_manager`:
 * `plugin_manager` lives inside the installation (`dsh-plugin-manager/tools`)
 * and calls `runProfilePnpm` directly — there is no hook between the tool and
 * pnpm. Rewriting a file inside the app works until the next update replaces
 * it. This tool is the opt-in path: the host is stopped first, the profile is
 * snapshotted, and a failed install rolls back instead of leaving a half
 * relinked tree.
 *
 * Safety order for `action: 'install'`:
 *   1. `-Status` — a host is stopped only if one is actually running.
 *   2. `-Stop`   — engine stop (desktop: the Electron main-process tree).
 *   3. install   — the script runs with `-OnDemand -Confirm`, so it will not
 *                  stop or start anything itself; it snapshots package.json +
 *                  pnpm-lock.yaml, runs pnpm, checks the package landed, checks
 *                  for shadowed `@deepseek-ai/*`, and rolls back on failure.
 *   4. `-Start`  — engine start. The files are already on disk at this point,
 *                  so a failed start is reported but never masks the install.
 *
 * The call is long (the host stops, pnpm runs, the host comes back), and it is
 * deliberately foreground: every phase boundary lands in `detail.steps`, and
 * the call's abort signal cancels it.
 *
 * Like `lib/tools.js`, this module imports nothing from the host: `defineTool`
 * arrives as a parameter.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
    ensureDirectory,
    isFile,
    resolveDshHome,
    resolvePwsh,
    resolveStateDir,
    runsDir,
} from './paths.js';
import {
    extractJsonObject,
    newRunId,
    runFilePaths,
    runForeground,
} from './runner.js';

/** Actions the tool exposes. */
export const INSTALL_ACTIONS = Object.freeze(['status', 'plan', 'install', 'repair_scope', 'check_shadowed']);

/** The profile `dsh` boots by default when the call does not name one. */
const DEFAULT_PROFILE = 'web';
/** A profile is a directory name under `<DSH_HOME>/profiles`. */
const PROFILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

const NULLABLE_STRING = Object.freeze({ oneOf: [{ type: 'string' }, { type: 'null' }] });
const NULLABLE_INTEGER = Object.freeze({ oneOf: [{ type: 'integer' }, { type: 'null' }] });

function messageOf(error) {
    return error instanceof Error ? error.message : String(error);
}

function tail(text, limit = 1200) {
    const value = typeof text === 'string' ? text.trim() : '';
    if (value === '') return '';
    return value.length <= limit ? value : `…${value.slice(-limit)}`;
}

/**
 * @param {{
 *   defineTool: Function,
 *   config: Readonly<Record<string, unknown>>,
 *   paths: { dshHome: string, stateDir: string, engineScript: string, installScript: string },
 *   env?: Record<string, string | undefined>,
 *   platform?: string,
 * }} options
 * @returns {object[]} zero or one tool definition
 */
export function createInstallToolDefinitions(options) {
    const {
        defineTool,
        config,
        paths,
        env = process.env,
        platform = process.platform,
    } = options;
    if (typeof defineTool !== 'function') {
        throw new TypeError('createInstallToolDefinitions: defineTool must be a function');
    }
    if (!paths || typeof paths.installScript !== 'string' || paths.installScript === '') {
        throw new TypeError('createInstallToolDefinitions: paths.installScript is required');
    }
    if (config.tools?.install === false) return [];

    const scriptTimeoutMs = Number.isInteger(config.installTimeoutMs) ? Number(config.installTimeoutMs) : 900000;
    const stepTimeoutMs = Number.isInteger(config.toolTimeoutMs) ? Number(config.toolTimeoutMs) : 30000;

    /** Resolve the profile/home/state/pwsh the scripts should use. */
    function contextFor(args) {
        // Never let an unset profile stringify into the literal "undefined": the
        // engine would then look for `<DSH_HOME>/profiles/undefined` and the call
        // would fail on a path that does not exist. Fall back to the documented
        // default, then reject anything that is not a usable profile name.
        const rawProfile = typeof args.profile === 'string' && args.profile !== ''
            ? args.profile
            : (typeof config.profile === 'string' && config.profile !== '' ? config.profile : DEFAULT_PROFILE);
        const profile = String(rawProfile).trim();
        if (!PROFILE_RE.test(profile)) {
            throw new Error(`install_plugin: invalid profile ${JSON.stringify(profile)} (expected a profile directory name)`);
        }
        const dshHome = resolveDshHome({
            dshHome: typeof args.dshHome === 'string' && args.dshHome !== '' ? args.dshHome : config.dshHome,
        }, env);
        const stateDir = resolveStateDir({
            stateDir: typeof args.stateDir === 'string' && args.stateDir !== '' ? args.stateDir : config.stateDir,
        }, env);
        const pwsh = resolvePwsh({
            pwshPath: typeof args.pwshPath === 'string' && args.pwshPath !== '' ? args.pwshPath : config.pwshPath,
        }, { env, platform });
        return { profile, dshHome, stateDir, pwsh };
    }

    /** `[pwsh, -NoProfile, -NonInteractive, -File, <script>, ...extra]`. */
    function psArgs(ctx, scriptPath, extra) {
        return ['-NoProfile', '-NonInteractive', '-File', scriptPath, ...extra];
    }

    /** Profile (and optionally home/state) switches shared by both scripts. */
    function profileSwitches(ctx, withState) {
        const args = ['-Profile', ctx.profile];
        if (config.dshHome !== '') args.push('-DshHome', ctx.dshHome);
        if (withState === true && config.stateDir !== '') args.push('-StateDir', ctx.stateDir);
        return args;
    }

    /** One engine action in the foreground, normalized like `lib/tools.js` does it. */
    async function engineAction(action, ctx, exec) {
        const run = await runForeground({
            execPath: ctx.pwsh.path,
            args: psArgs(ctx, paths.engineScript, [action, ...profileSwitches(ctx, false), '-Json']),
            timeoutMs: stepTimeoutMs,
            signal: exec?.signal,
            env,
        });
        const envelope = extractJsonObject(run.stdout);
        return {
            ok: run.ok,
            exitCode: run.exitCode,
            envelope,
            state: envelope && typeof envelope.result === 'string' ? envelope.result : null,
            error: run.ok ? null : (run.timedOut ? `timed out after ${stepTimeoutMs} ms` : (tail(run.stderr) || run.error)),
        };
    }

    /**
     * One install-script run, with its JSON report read back.
     *
     * @param {'census'|'plan'|'install'|'repair_scope'|'check_shadowed'} mode
     * @param {ReturnType<typeof contextFor>} ctx
     * @param {{ spec?: string, bundle?: boolean, healthSec?: number, reason?: string, sessionId?: string }} options
     * @param {unknown} exec
     * @param {number} timeoutMs
     */
    async function scriptRun(mode, ctx, options, exec, timeoutMs) {
        ensureDirectory(runsDir(ctx.stateDir));
        const runId = newRunId();
        const files = runFilePaths(ctx.stateDir, runId);
        ensureDirectory(files.dir);
        const reportFile = join(files.dir, `${mode}.report.json`);
        const extra = [];
        if (mode === 'census') extra.push('-CensusOnly');
        else if (mode === 'plan') {
            extra.push('-Spec', options.spec, '-WhatIfPlan');
            if (options.bundle === true) extra.push('-Bundle');
        } else if (mode === 'repair_scope') extra.push('-RepairScope', '-Confirm');
        else if (mode === 'check_shadowed') extra.push('-CheckShadowed', '-Confirm');
        else {
            // -OnDemand: the host is already stopped by this tool and is started again here.
            extra.push('-Spec', options.spec, '-OnDemand', '-Confirm');
            if (options.bundle === true) extra.push('-Bundle');
            if (Number.isInteger(options.healthSec)) extra.push('-HealthSec', String(options.healthSec));
            if (typeof options.reason === 'string' && options.reason !== '') extra.push('-Reason', options.reason);
            if (typeof options.sessionId === 'string' && options.sessionId !== '') extra.push('-SessionId', options.sessionId);
        }
        const args = psArgs(ctx, paths.installScript, [
            ...extra,
            ...profileSwitches(ctx, true),
            '-Report', reportFile,
        ]);
        const run = await runForeground({
            execPath: ctx.pwsh.path,
            args,
            timeoutMs,
            signal: exec?.signal,
            env,
            cwd: files.dir,
        });
        let report = null;
        try {
            report = JSON.parse(readFileSync(reportFile, 'utf8'));
        } catch {
            report = null;
        }
        return { run, report, reportFile, runId, resultFile: files.resultFile, args };
    }

    /** Every failure answer in one shape (the declared output schema). */
    function failure(action, error, extra) {
        return {
            ok: false,
            action,
            state: 'failed',
            runId: null,
            reportFile: null,
            exitCode: null,
            summary: null,
            error,
            detail: null,
            ...extra,
        };
    }

    const definition = defineTool({
        name: 'install_plugin',
        description: 'Install a DSH plugin through the safe channel instead of `plugin_manager`. '
            + '`plugin_manager` runs pnpm against a live profile: it prunes `<DSH_HOME>\\profiles\\node_modules` (the shared '
            + '@deepseek-ai projection the desktop host resolves from), relinks the tree under the running process, and can '
            + 'leave base packages shadowed so the app no longer boots. This tool does it in the order that survives: '
            + 'snapshot package.json + pnpm-lock.yaml → stop the host → pnpm add → verify the package landed → check for '
            + 'shadowed @deepseek-ai/* → start the host. A failed step rolls the snapshot back. '
            + 'The call is long and the host goes down in the middle, so the calling session is interrupted; '
            + 'use action=plan first, and action=status / check_shadowed freely (they change nothing). '
            + 'Prefer this over plugin_manager whenever asked to install, upgrade, or repair a plugin.',
        parameters: {
            action: {
                type: 'string',
                required: true,
                enum: [...INSTALL_ACTIONS],
                description: 'status = read-only machine facts and active sessions; plan = the exact steps for a spec, touching nothing; '
                    + 'install = stop → install → start; repair_scope = re-extract the shared @deepseek-ai projection from the '
                    + 'installation; check_shadowed = move profile-local packages that shadow the app into .stale-packages.',
            },
            spec: {
                type: 'string',
                description: 'For action=install/plan: npm name, name@version, github:, a tarball URL, an absolute local directory, or a link:/file: path.',
            },
            bundle: { type: 'boolean', description: 'Also add the package to dsh.profile.bundles (default false: install only).' },
            healthSec: { type: 'integer', description: 'Seconds the script waits for the host to answer HTTP 401/200 after the install (default 30).' },
            reason: { type: 'string', description: 'Human-readable note recorded in the run log and the continuation notice.' },
            profile: { type: 'string', description: 'Profile to install into (default: the configured profile).' },
            dshHome: { type: 'string', description: 'DSH home (default: configured, then $DSH_HOME, then %USERPROFILE%\\.dsh).' },
            stateDir: { type: 'string', description: 'State directory (default: configured, then %LOCALAPPDATA%\\dsh-restart).' },
            pwshPath: { type: 'string', description: 'PowerShell executable (default: pwsh, then powershell.exe).' },
        },
        output: {
            schema: {
                type: 'object',
                additionalProperties: false,
                properties: {
                    ok: { type: 'boolean', required: true },
                    action: { type: 'string', required: true },
                    state: { type: 'string', enum: ['ok', 'failed'], required: true },
                    runId: NULLABLE_STRING,
                    reportFile: NULLABLE_STRING,
                    exitCode: NULLABLE_INTEGER,
                    summary: NULLABLE_STRING,
                    error: NULLABLE_STRING,
                    detail: { type: 'json', description: 'Phase-by-phase outcome; for install: stop / install / start.' },
                },
            },
            render: (_args, value) => {
                const lines = [{
                    type: 'text',
                    text: `${value.action}: ${value.ok ? 'ok' : 'FAILED'}${value.summary ? ` (${value.summary})` : ''}${value.error ? ` — ${value.error}` : ''}`,
                }];
                const steps = value.detail && Array.isArray(value.detail.steps) ? value.detail.steps : [];
                for (const step of steps) {
                    lines.push({
                        type: 'text',
                        text: `  ${step.step}: ${step.ok ? 'ok' : 'FAILED'}${step.detail ? ` — ${step.detail}` : ''}`,
                    });
                }
                if (value.state === 'ok' && value.action === 'install') {
                    lines.push({ type: 'text', text: 'The host restarted with the package installed. Verify the plugin appears before relying on it.' });
                }
                return lines;
            },
        },
        timeoutMs: scriptTimeoutMs + stepTimeoutMs * 2,
        async execute(args, exec) {
            const action = typeof args.action === 'string' ? args.action : '';
            if (!INSTALL_ACTIONS.includes(action)) return failure(action, `unknown action "${action}"`);
            if (!isFile(paths.installScript)) return failure(action, `install script is missing: ${paths.installScript}`);

            let ctx;
            try {
                ctx = contextFor(args);
            } catch (error) {
                return failure(action, messageOf(error));
            }

            // ---- read-only
            if (action === 'status' || action === 'repair_scope' || action === 'check_shadowed') {
                try {
                    const mode = action === 'status' ? 'census' : action;
                    const result = await scriptRun(mode, ctx, {}, exec, Math.min(scriptTimeoutMs, 120000));
                    return {
                        ok: result.run.ok,
                        action,
                        state: result.run.ok ? 'ok' : 'failed',
                        runId: result.runId,
                        reportFile: result.reportFile,
                        exitCode: result.run.exitCode,
                        summary: result.run.ok ? action : null,
                        error: result.run.ok
                            ? null
                            : (result.run.timedOut ? 'the script timed out' : (tail(result.run.stderr) || result.run.error)),
                        detail: {
                            report: result.report,
                            argv: result.args,
                            stdout: tail(result.run.stdout, 3000),
                            durationMs: result.run.durationMs,
                        },
                    };
                } catch (error) {
                    return failure(action, messageOf(error));
                }
            }

            // ---- spec validation (plan and install)
            const spec = typeof args.spec === 'string' ? args.spec.trim() : '';
            if (spec === '') return failure(action, 'spec is required for action=plan/install');
            // A leading dash would be parsed as a PowerShell switch rather than a spec.
            if (spec.startsWith('-')) return failure(action, 'spec must not start with "-"');

            if (action === 'plan') {
                try {
                    const result = await scriptRun('plan', ctx, { spec, bundle: args.bundle }, exec, stepTimeoutMs);
                    return {
                        ok: result.run.ok,
                        action,
                        state: result.run.ok ? 'ok' : 'failed',
                        runId: result.runId,
                        reportFile: result.reportFile,
                        exitCode: result.run.exitCode,
                        summary: result.run.ok ? 'plan' : null,
                        error: result.run.ok ? null : (tail(result.run.stderr) || result.run.error),
                        detail: { spec, plan: result.report, argv: result.args, stdout: tail(result.run.stdout, 3000) },
                    };
                } catch (error) {
                    return failure(action, messageOf(error));
                }
            }

            // ---- install: stop → install (-OnDemand) → start
            const steps = [];
            const push = (step, ok, detail, exitCode = null) => {
                steps.push({ step, ok, detail: detail ?? null, exitCode });
            };

            try {
                const before = await engineAction('-Status', ctx, exec);
                const status = before.envelope && typeof before.envelope.status === 'object' ? before.envelope.status : null;
                const hostRunning = before.ok && status !== null
                    && (status.serving === true || Number.isInteger(status.mainPid) || Number.isInteger(status.targetPid));
                if (hostRunning) {
                    const stopped = await engineAction('-Stop', ctx, exec);
                    push('stop', stopped.ok, stopped.ok ? null : (stopped.error ?? stopped.state), stopped.exitCode);
                    if (!stopped.ok) {
                        return failure(action, stopped.error ?? 'the host refused to stop; nothing was installed', {
                            exitCode: stopped.exitCode,
                            summary: 'could-not-stop-host',
                            detail: { spec, steps },
                        });
                    }
                } else {
                    push('stop', true, 'no running host was found; the install runs without a stop');
                }
            } catch (error) {
                return failure(action, `could not check or stop the host: ${messageOf(error)}`, { detail: { spec, steps } });
            }

            let install;
            try {
                install = await scriptRun('install', ctx, {
                    spec,
                    bundle: args.bundle,
                    healthSec: args.healthSec,
                    reason: args.reason,
                    sessionId: typeof args.sessionId === 'string' ? args.sessionId : '',
                }, exec, scriptTimeoutMs);
            } catch (error) {
                return failure(action, `the install step threw: ${messageOf(error)}`, { detail: { spec, steps } });
            }

            const report = install.report;
            const installOk = install.run.ok && report !== null && report.status === 'ok';
            push('install', installOk,
                report === null
                    ? (tail(install.run.stderr) || 'the script returned no report')
                    : `status=${report.status} pnpmExit=${report.pnpmExit} landed=${report.landed} healthy=${report.healthy} rollback=${report.rollbackOk}`,
                install.run.exitCode);
            if (!installOk) {
                return failure(action,
                    report === null
                        ? (tail(install.run.stderr) || 'the install script returned no report file')
                        : `the install did not succeed (${report.status}); the snapshot was ${report.rollbackOk === true
                            ? 'restored'
                            : 'NOT restored — check node_modules and pnpm-lock.yaml by hand'}`,
                    {
                        runId: install.runId,
                        reportFile: install.reportFile,
                        exitCode: install.run.exitCode,
                        summary: report === null ? 'no-report' : String(report.status),
                        detail: { spec, steps, report, stdout: tail(install.run.stdout, 3000) },
                    });
            }

            // The files are on disk now; a failed start is reported, never hidden.
            let startError = null;
            try {
                const started = await engineAction('-Start', ctx, exec);
                push('start', started.ok, started.ok ? null : (started.error ?? started.state), started.exitCode);
                if (!started.ok) startError = started.error ?? 'the host did not start';
            } catch (error) {
                push('start', false, messageOf(error));
                startError = messageOf(error);
            }

            return {
                ok: startError === null,
                action,
                state: startError === null ? 'ok' : 'failed',
                runId: install.runId,
                reportFile: install.reportFile,
                exitCode: install.run.exitCode,
                summary: startError === null ? 'installed' : 'installed-but-host-not-started',
                error: startError,
                detail: {
                    spec,
                    steps,
                    report,
                    healthy: report?.healthy ?? null,
                    healthyPort: report?.healthyPort ?? null,
                    stdout: tail(install.run.stdout, 3000),
                },
            };
        },
    });

    return [definition];
}
