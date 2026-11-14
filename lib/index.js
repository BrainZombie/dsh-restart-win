/**
 * dsh-restart-win — safe, verified restart of a DSH Web host on Windows.
 *
 * The engine is `scripts/dsh-restart.ps1`; this entry point only wires it to the
 * host: normalize the config (fail closed), resolve the four tool definitions,
 * register them, and remove them again on plugin unload.
 */
import { readFileSync } from 'node:fs';
import { ROUTE, createApi } from './api.js';
import { normalizeConfig } from './config.js';
import { loadHostModule } from './host.js';
import {
    engineScriptPath,
    isFile,
    launcherScriptPath,
    resolveDshHome,
    resolveStateDir,
} from './paths.js';
import { createToolDefinitions } from './tools.js';

/** Version reported by the panel (the same source the engine reads). */
function packageVersion() {
    try {
        return JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version ?? '';
    } catch {
        return '';
    }
}

/** Cordis plugin name (must match the patch row id). */
export const name = 'dsh-restart-win';

/** Services this plugin needs before `apply` runs. */
// `webServer` is required by Cordis before a service may be read; the panel API
// lives on it. Hosts without a web server (headless) cannot load this plugin —
// that is the same trade-off dsh-card-library makes for its own panel.
export const inject = ['tools', 'webServer'];

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx host context
 * @param {Record<string, unknown>} [rawConfig] row config from `cordis.patch.yml`
 * @returns {Promise<void>}
 */
export async function apply(ctx, rawConfig = {}) {
    const config = normalizeConfig(rawConfig);
    const paths = Object.freeze({
        dshHome: resolveDshHome(config),
        stateDir: resolveStateDir(config),
        engineScript: engineScriptPath(),
        launcherScript: launcherScriptPath(),
    });
    if (!isFile(paths.engineScript)) {
        console.warn(`[dsh-restart-win] engine script is missing: ${paths.engineScript} (tools will report this per call)`);
    }
    const { defineTool } = await loadHostModule('@deepseek-ai/dsh-tools', { profile: config.profile });
    if (typeof defineTool !== 'function') {
        throw new TypeError('dsh-restart-win: @deepseek-ai/dsh-tools did not export defineTool');
    }
    const definitions = createToolDefinitions({ defineTool, config, paths });
    const disposers = [];
    try {
        for (const definition of definitions) {
            const dispose = ctx.tools.register(definition);
            if (typeof dispose === 'function') disposers.push(dispose);
        }
    } catch (error) {
        // A partially registered set must not linger: undo what already landed.
        while (disposers.length > 0) {
            try {
                disposers.pop()();
            } catch {
                // Keep unwinding.
            }
        }
        throw error;
    }
    // One line per host start: makes "did the tools actually register?" observable in
    // the host log instead of inferred from the absence of an error.
    console.log(`[dsh-restart-win] tools registered: ${definitions.map((definition) => definition.name).join(', ')} (hostKind=${config.hostKind})`);
    // Panel API. Registered only when the host exposes a web server; a headless
    // host keeps the four tools and simply has no panel.
    try {
        const server = ctx.webServer;
        if (server && typeof server.register === 'function') {
            const api = createApi({ config, paths, tools: definitions, version: packageVersion() });
            const disposeRoute = server.register({
                kind: 'prefix',
                path: ROUTE,
                handler: (req, res) => api.handle(req, res),
            });
            if (typeof disposeRoute === 'function') disposers.push(disposeRoute);
            console.log(`[dsh-restart-win] panel API mounted at ${ROUTE}/api (client half: dsh.client)`);
        } else {
            console.warn('[dsh-restart-win] no webServer service: panel API not mounted (tools still work)');
        }
    } catch (error) {
        console.warn('[dsh-restart-win] panel API was not mounted:', error instanceof Error ? error.message : String(error));
    }

    const disposeAll = () => {
        while (disposers.length > 0) {
            const dispose = disposers.pop();
            try {
                dispose();
            } catch {
                // A rejected disposer must not block the others.
            }
        }
    };
    if (typeof ctx.effect === 'function') ctx.effect(() => disposeAll);
    else return disposeAll;
}
