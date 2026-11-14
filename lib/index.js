/**
 * dsh-restart-win — safe, verified restart of a DSH Web host on Windows.
 *
 * The engine is `scripts/dsh-restart.ps1`; this entry point only wires it to the
 * host: normalize the config (fail closed), resolve the four tool definitions,
 * register them, and remove them again on plugin unload.
 */
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

/** Cordis plugin name (must match the patch row id). */
export const name = 'dsh-restart-win';

/** Services this plugin needs before `apply` runs. */
export const inject = ['tools'];

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
