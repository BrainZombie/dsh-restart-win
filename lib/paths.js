/**
 * Path and executable resolution for dsh-restart-win.
 *
 * Nothing here is hardcoded to one machine: `dshHome`, `stateDir`, the engine
 * script and the PowerShell host are all derived at runtime from the
 * environment, the plugin configuration, or the package location. A missing
 * piece raises `PathsError` at the moment it is needed, so the plugin still
 * loads on a machine without PowerShell and reports the problem per call.
 */
import { mkdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, dirname, isAbsolute, join, resolve, win32 } from 'node:path';
import { fileURLToPath } from 'node:url';

/** A path or executable that could not be resolved. */
export class PathsError extends Error {
    /**
     * @param {string} detail what could not be resolved and what to do about it
     */
    constructor(detail) {
        super(`dsh-restart-win: ${detail}`);
        this.name = 'PathsError';
    }
}

/**
 * Read an environment variable, honoring both the exact and the upper-case
 * spelling (Windows treats the names case-insensitively; a plain object passed
 * by a test does not).
 *
 * @param {Record<string, string | undefined>} env
 * @param {string} name
 * @returns {string | undefined}
 */
function envValue(env, name) {
    const exact = env[name];
    if (typeof exact === 'string' && exact.trim() !== '') return exact.trim();
    const upper = env[name.toUpperCase()];
    if (typeof upper === 'string' && upper.trim() !== '') return upper.trim();
    return undefined;
}

/**
 * @param {Record<string, string | undefined>} [env]
 * @returns {string} `%LOCALAPPDATA%`, or the standard per-user location
 */
export function localAppData(env = process.env) {
    const configured = envValue(env, 'LOCALAPPDATA');
    if (configured) return configured;
    const profile = envValue(env, 'USERPROFILE');
    if (profile) return join(profile, 'AppData', 'Local');
    return join(homedir(), 'AppData', 'Local');
}

/**
 * @param {Record<string, string | undefined>} [env]
 * @returns {string} `$DSH_HOME`, or `<user home>/.dsh`
 */
export function defaultDshHome(env = process.env) {
    const configured = envValue(env, 'DSH_HOME');
    if (configured) return configured;
    const profile = envValue(env, 'USERPROFILE');
    return join(profile ?? homedir(), '.dsh');
}

/**
 * @param {{ dshHome?: string }} config
 * @param {Record<string, string | undefined>} [env]
 * @returns {string} absolute DSH home directory
 */
export function resolveDshHome(config, env = process.env) {
    const configured = typeof config?.dshHome === 'string' ? config.dshHome : '';
    const chosen = configured || defaultDshHome(env);
    if (!isAbsolute(chosen) && !win32.isAbsolute(chosen)) {
        throw new PathsError(`DSH home must be an absolute path (got "${chosen}")`);
    }
    return chosen;
}

/**
 * Default state directory. CONTRACT §4 pins this to `%LOCALAPPDATA%\dsh-restart`
 * so existing logs, boot records and restart notices keep working.
 *
 * @param {{ stateDir?: string }} config
 * @param {Record<string, string | undefined>} [env]
 * @returns {string} absolute state directory
 */
export function resolveStateDir(config, env = process.env) {
    const configured = typeof config?.stateDir === 'string' ? config.stateDir : '';
    if (configured !== '') {
        if (!isAbsolute(configured) && !win32.isAbsolute(configured)) {
            throw new PathsError(`state directory must be an absolute path (got "${configured}")`);
        }
        return configured;
    }
    return join(localAppData(env), 'dsh-restart');
}

/**
 * @returns {string} directory holding `package.json` and `lib/`
 */
export function packageRoot() {
    return dirname(dirname(fileURLToPath(import.meta.url)));
}

/**
 * @param {string} [root] package root override (tests)
 * @returns {string} absolute path of the PowerShell engine
 */
export function engineScriptPath(root = packageRoot()) {
    return join(root, 'scripts', 'dsh-restart.ps1');
}

/**
 * @param {string} [root] package root override (tests)
 * @returns {string} absolute path of the safe plugin-install channel
 */
export function installScriptPath(root = packageRoot()) {
    return join(root, 'scripts', 'dsh-plugin-install.ps1');
}

/**
 * @param {string} [root] package root override (tests)
 * @returns {string} absolute path of the detached-run launcher
 */
export function launcherScriptPath(root = packageRoot()) {
    return join(root, 'lib', 'delayed-spawn.mjs');
}

/**
 * @param {string} [root] package root override (tests)
 * @returns {string} absolute path of the scheduled-task template
 */
export function taskTemplatePath(root = packageRoot()) {
    return join(root, 'scripts', 'dsh-restart.task.xml');
}

/**
 * @param {string} stateDir absolute state directory
 * @returns {string} directory holding one file triplet per detached run
 */
export function runsDir(stateDir) {
    return join(stateDir, 'runs');
}

/**
 * @param {string} path
 * @returns {boolean}
 */
export function isFile(path) {
    try {
        return statSync(path).isFile();
    } catch {
        return false;
    }
}

/**
 * @param {string} path
 * @returns {string} the same path, after making the directory exist
 */
export function ensureDirectory(path) {
    mkdirSync(path, { recursive: true });
    return path;
}

const WINDOWS_EXECUTABLE_EXTENSIONS = ['.exe', '.cmd', '.bat', '.com'];

/**
 * Locate an executable on PATH. No shell, no `where.exe` — a directory scan is
 * predictable and works from a service context with a minimal environment.
 *
 * @param {string} name executable name (`pwsh`) or path
 * @param {{ env?: Record<string, string | undefined>, platform?: string }} [options]
 * @returns {string | null} absolute path, or null when not found
 */
export function findExecutable(name, options = {}) {
    const { env = process.env, platform = process.platform } = options;
    if (typeof name !== 'string' || name.trim() === '') return null;
    const target = name.trim();
    const looksLikePath = target.includes('/') || target.includes('\\');
    if (looksLikePath) {
        const absolute = resolve(target);
        return isFile(absolute) ? absolute : null;
    }
    const hasExtension = /\.[A-Za-z0-9]+$/.test(target);
    const candidates = hasExtension
        ? [target]
        : platform === 'win32'
            ? WINDOWS_EXECUTABLE_EXTENSIONS.map((extension) => `${target}${extension}`)
            : [target];
    const pathValue = envValue(env, 'PATH') ?? envValue(env, 'Path') ?? '';
    const directories = pathValue.split(platform === 'win32' ? ';' : delimiter);
    for (const directory of directories) {
        const trimmed = directory.trim().replace(/^"|"$/g, '');
        if (trimmed === '') continue;
        for (const candidate of candidates) {
            const full = join(trimmed, candidate);
            if (isFile(full)) return resolve(full);
        }
    }
    return null;
}

/**
 * Resolve the PowerShell host: an explicit `pwshPath` wins, otherwise `pwsh`
 * is preferred and Windows PowerShell (`powershell.exe`) is the fallback.
 *
 * @param {{ pwshPath?: string }} config
 * @param {{ env?: Record<string, string | undefined>, platform?: string }} [options]
 * @returns {{ path: string, source: 'config' | 'pwsh' | 'powershell' }}
 */
export function resolvePwsh(config, options = {}) {
    const { env = process.env, platform = process.platform } = options;
    const configured = typeof config?.pwshPath === 'string' ? config.pwshPath : '';
    if (configured !== '') {
        if (!isFile(configured)) {
            throw new PathsError(`pwshPath does not exist: ${configured}`);
        }
        return { path: configured, source: 'config' };
    }
    const pwsh = findExecutable('pwsh', { env, platform });
    if (pwsh) return { path: pwsh, source: 'pwsh' };
    const powershell = findExecutable('powershell', { env, platform });
    if (powershell) return { path: powershell, source: 'powershell' };
    throw new PathsError(
        'no PowerShell found on PATH: install PowerShell 7 (pwsh) or make powershell.exe available, or set the `pwshPath` config key',
    );
}
