#!/usr/bin/env node
/**
 * End-to-end driver for the `install_plugin` tool — the real one, not a stub.
 *
 * It calls the tool's own `execute()` with a `link:` spec pointing at a no-op probe
 * package, so the whole chain is exercised: the tool validates the spec, starts
 * `scripts/dsh-plugin-install.ps1 -Confirm -Detach` through WMI, and the script
 * snapshots the profile, stops the host, runs pnpm, checks the package landed,
 * checks for shadowed base packages, starts the host again and health-checks it.
 *
 * THIS STOPS THE HOST. That is why it needs an explicit `--run`: without it the
 * script only prints what it would do.
 *
 *   node test/probe-install-plugin.mjs                 # plan only (no side effects)
 *   node test/probe-install-plugin.mjs --run           # performs the install
 *   node test/probe-install-plugin.mjs --verify <report.json>   # read the result back
 *
 * The probe package lives outside the repository (scratch dir) and contains no
 * behavior: it exists only to prove a package can be installed and that the host
 * comes back afterwards. Remove it with the same safe channel (stop → pnpm remove
 * → start) once the run is verified.
 */
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createInstallToolDefinitions } from '../lib/install-tools.js';
import { engineScriptPath, installScriptPath, resolveDshHome, resolveStateDir } from '../lib/paths.js';

const PROBE_NAME = '@local/dsh-restart-install-probe';
const PROBE_VERSION = '0.0.1';

const argv = process.argv.slice(2);
const run = argv.includes('--run');
const verifyIndex = argv.indexOf('--verify');
const verifyReport = verifyIndex >= 0 ? argv[verifyIndex + 1] : '';

/** Create the no-op probe package outside the repo, if it is not there yet. */
function ensureProbePackage() {
    const dir = join(tmpdir(), 'dsh-restart-install-probe');
    mkdirSync(dir, { recursive: true });
    const pkgPath = join(dir, 'package.json');
    if (!existsSync(pkgPath)) {
        writeFileSync(pkgPath, `${JSON.stringify({
            name: PROBE_NAME,
            version: PROBE_VERSION,
            private: true,
            description: 'Throwaway package used to prove install_plugin end to end; contains no behavior.',
            type: 'module',
            main: './index.js',
            files: ['index.js'],
            license: 'MIT',
        }, null, 2)}\n`, 'utf8');
        writeFileSync(join(dir, 'index.js'),
            '// No-op probe package: proves a package can be installed without changing behavior.\n'
            + "export const name = 'dsh-restart-install-probe';\n"
            + 'export function apply() {}\n', 'utf8');
    }
    // `tmpdir()` may hand back an 8.3 short path (C:\\Users\\ADMINI~1\\...).
    // pnpm rewrites dependencies by path, so hand it the canonical long form.
    try {
        return realpathSync.native(dir);
    } catch {
        return dir;
    }
}

/** Read the report the install script wrote, plus the observable profile state. */
function verify(reportPath) {
    const report = JSON.parse(readFileSync(reportPath, 'utf8'));
    const dshHome = resolveDshHome({ dshHome: '' }, process.env);
    const profileDir = join(dshHome, 'profiles', typeof report.profile === 'string' ? report.profile : 'desktop');
    const pkg = JSON.parse(readFileSync(join(profileDir, 'package.json'), 'utf8'));
    const dep = pkg.dependencies?.[PROBE_NAME] ?? null;
    const landed = existsSync(join(profileDir, 'node_modules', ...PROBE_NAME.split('/'), 'package.json'));
    const status = spawnSync(process.env.DSH_RESTART_PROBE_PWSH || 'pwsh',
        ['-NoProfile', '-File', engineScriptPath(), '-Status', '-Json'],
        { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
    let http = null;
    try {
        http = JSON.parse(status.stdout.replace(/^\uFEFF/, '')).status.http;
    } catch { /* reported below */ }
    const out = {
        report: report.result ?? null,
        reportOk: report.ok ?? null,
        dependency: dep,
        landed,
        http,
        healthy: http === 401 || http === 200,
    };
    console.log(JSON.stringify(out, null, 2));
    const ok = out.reportOk === true && out.landed && out.healthy;
    process.exitCode = ok ? 0 : 1;
    return out;
}

if (verifyReport) {
    verify(resolve(verifyReport));
} else {
    const probeDir = ensureProbePackage();
    const spec = `link:${probeDir}`;
    if (!run) {
        console.log(JSON.stringify({
            mode: 'plan',
            note: 'nothing has been touched; re-run with --run to perform the install (this stops the host)',
            spec,
            installScript: installScriptPath(),
            engine: engineScriptPath(),
            profile: 'desktop',
            dshHome: resolveDshHome({ dshHome: '' }, process.env),
            stateDir: resolveStateDir({ stateDir: '' }, process.env),
        }, null, 2));
    } else {
        const [tool] = createInstallToolDefinitions({
            defineTool: (definition) => definition,
            config: {
                profile: 'desktop',
                dshHome: '',
                stateDir: '',
                pwshPath: '',
                installTimeoutMs: 900000,
                toolTimeoutMs: 30000,
                tools: { install: true },
            },
            paths: {
                dshHome: resolveDshHome({ dshHome: '' }, process.env),
                stateDir: resolveStateDir({ stateDir: '' }, process.env),
                engineScript: engineScriptPath(),
                installScript: installScriptPath(),
            },
        });
        const value = await tool.execute({ action: 'install', spec, reason: 'install_plugin e2e probe' }, {});
        console.log(JSON.stringify(value, null, 2));
        process.exitCode = value.ok ? 0 : 1;
    }
}
