/**
 * Resolve host-provided packages (`@deepseek-ai/dsh-*`) without assuming where
 * the plugin physically lives.
 *
 * A plugin installed as a copy resolves them by walking up to
 * `<profile>/node_modules/@deepseek-ai`. A plugin installed as a link/junction
 * resolves against its *real* directory instead, where no such tree exists — so
 * try the bare specifier first, then the profile trees, then the CLI's own
 * `node_modules`.
 */
import { readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const cache = new Map();

/**
 * pnpm keeps every package under `node_modules/.pnpm/<name>@<version>/`. A profile
 * that installed DSH itself (not a global CLI) exposes the host packages only
 * there, so enumerate matching store entries.
 *
 * @param {string} root directory that may contain `node_modules/.pnpm`
 * @param {string} specifier e.g. `@deepseek-ai/dsh-tools`
 * @returns {string[]} file URLs, newest version first
 */
function pnpmStoreCandidates(root, specifier) {
    const store = join(root, 'node_modules', '.pnpm');
    const prefix = `${specifier.replace('/', '+')}@`;
    let entries;
    try {
        entries = readdirSync(store).filter((name) => name.startsWith(prefix));
    } catch {
        return [];
    }
    return entries
        .sort()
        .reverse()
        .map((entry) => pathToFileURL(join(store, entry, 'node_modules', specifier, 'lib', 'index.js')).href);
}

/**
 * @param {Record<string, string | undefined>} [env]
 * @returns {string} `$DSH_HOME`, or `<user home>/.dsh`
 */
export function dshHomePath(env = process.env) {
    const configured = env.DSH_HOME;
    if (typeof configured === 'string' && configured.trim() !== '') return configured.trim();
    const profile = env.USERPROFILE;
    return join(typeof profile === 'string' && profile.trim() !== '' ? profile.trim() : homedir(), '.dsh');
}

/**
 * @param {string} specifier e.g. `@deepseek-ai/dsh-tools`
 * @param {{ env?: Record<string, string | undefined>, profile?: string, execPath?: string }} [options]
 *   `execPath` overrides the running executable used to locate a DSH Desktop installation (tests).
 * @returns {string[]} candidate import specifiers, most specific first
 */
export function hostModuleCandidates(specifier, options = {}) {
    const { env = process.env, profile = '' } = options;
    const dshHome = dshHomePath(env);
    const home = env.USERPROFILE?.trim() || homedir();
    const candidates = [specifier];
    // DSH Desktop runs its host from an Electron installation; its own packages
    // live inside `<app>\resources\app.asar\dsh\node_modules`, which no profile
    // or global npm tree contains. Resolve them against the running executable
    // first (Electron's asar-aware loader is what makes this importable at all).
    const execPath = typeof options.execPath === 'string' && options.execPath !== ''
        ? options.execPath
        : process.execPath;
    if (typeof execPath === 'string' && execPath !== '') {
        const appRoot = dirname(execPath);
        candidates.push(pathToFileURL(join(appRoot, 'resources', 'app.asar', 'dsh', 'node_modules', specifier, 'lib', 'index.js')).href);
        candidates.push(pathToFileURL(join(appRoot, 'resources', 'app', 'node_modules', specifier, 'lib', 'index.js')).href);
    }
    if (profile) {
        candidates.push(pathToFileURL(join(dshHome, 'profiles', profile, 'node_modules', specifier, 'lib', 'index.js')).href);
        candidates.push(...pnpmStoreCandidates(join(dshHome, 'profiles', profile), specifier));
    }
    candidates.push(
        pathToFileURL(join(dshHome, 'profiles', 'node_modules', specifier, 'lib', 'index.js')).href,
        pathToFileURL(join(dshHome, 'node_modules', specifier, 'lib', 'index.js')).href,
        ...pnpmStoreCandidates(dshHome, specifier),
        pathToFileURL(join(home, 'AppData', 'Roaming', 'npm', 'node_modules', '@deepseek-ai', 'dsh', 'node_modules', specifier, 'lib', 'index.js')).href,
    );
    return candidates.filter(Boolean);
}

/**
 * Import one host package.
 *
 * @param {string} specifier e.g. `@deepseek-ai/dsh-tools`
 * @param {{ env?: Record<string, string | undefined>, profile?: string }} [options]
 * @returns {Promise<Record<string, unknown>>}
 */
export async function loadHostModule(specifier, options = {}) {
    const key = `${specifier}::${options.profile ?? ''}`;
    if (cache.has(key)) return cache.get(key);
    const failures = [];
    for (const candidate of hostModuleCandidates(specifier, options)) {
        try {
            const loaded = await import(candidate);
            cache.set(key, loaded);
            return loaded;
        } catch (error) {
            failures.push(`${candidate}: ${error instanceof Error ? error.message.split('\n')[0] : String(error)}`);
        }
    }
    throw new Error(`dsh-restart-win: cannot resolve host package ${specifier}:\n${failures.join('\n')}`);
}
