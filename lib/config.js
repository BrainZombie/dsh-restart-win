/**
 * Configuration normalization and validation for dsh-restart-win.
 *
 * Every value that can reach an engine argv array passes through this module
 * first. Two rules are absolute:
 *
 *   1. **Fail closed.** An invalid value raises `ConfigError` naming the field;
 *      it never silently falls back to a default. Defaults apply only when the
 *      key is absent.
 *   2. **Whitelist, not escape.** Values are matched against an allowed
 *      character set instead of being quoted for a shell. The runner builds an
 *      argv array and never concatenates a command string, so a value that
 *      fails the whitelist is a configuration error, not something to escape.
 */
import { homedir } from 'node:os';
import { isAbsolute, normalize, win32 } from 'node:path';

/** An invalid configuration or call argument. `field` is the dotted key path. */
export class ConfigError extends Error {
    /**
     * @param {string} field dotted key path, e.g. `port` or `tools.restart`
     * @param {string} detail what is wrong and what is accepted
     */
    constructor(field, detail) {
        super(`dsh-restart-win config: ${field}: ${detail}`);
        this.name = 'ConfigError';
        this.field = field;
    }
}

/** Tool registration switches (§4 `tools`). All on by default. */
export const TOOL_FLAGS = Object.freeze({
    restart: true,
    status: true,
    preflight: true,
    result: true,
});

/**
 * Defaults for every configuration key in CONTRACT §4. These reproduce the
 * behavior this machine had before the engine was packaged as a plugin.
 */
export const DEFAULTS = Object.freeze({
    profile: 'web',
    port: 3080,
    bindHost: '127.0.0.1',
    dshHome: '',
    stateDir: '',
    taskName: 'DSH Restart',
    pwshPath: '',
    readySec: 90,
    verifyReadySec: 150,
    graceSec: 3,
    portFreeSec: 30,
    restartDelayMs: 1500,
    toolTimeoutMs: 30000,
    verifyTimeoutMs: 600000,
    // Engine-side switch: when false, the plugin launches the engine with
    // DSH_RESTART_INJECT_HOST_ENV=0 so it skips injecting its own host-process
    // variables (DSH_UC_PROFILE_NODE_MODULES / NPM_CONFIG_LEGACY_PEER_DEPS).
    injectHostEnv: true,
    tools: TOOL_FLAGS,
});

/** Keys accepted in `cordis.patch.yml` / the plugin config object. */
export const CONFIG_KEYS = Object.freeze(Object.keys(DEFAULTS));

/**
 * Keys accepted as per-call overrides on the tools. `session` and `reason` are
 * resolved per call, never configured.
 */
export const CALL_KEYS = Object.freeze([
    'profile',
    'port',
    'bindHost',
    'dshHome',
    'stateDir',
    'taskName',
    'pwshPath',
    'readySec',
    'verifyReadySec',
    'graceSec',
    'portFreeSec',
    'waitIdleSec',
    'idleMaxSec',
    'delayMs',
    'session',
    'reason',
    'recordCommand',
    'recordWorkingDirectory',
    'verifyTempRoot',
    'fast',
    'forceUnverified',
    'viaTask',
    'tryCtrlC',
    'doNotTouchDshHome',
]);

/** Actions the tools can request from the engine (one per §3.1 capability). */
export const ACTIONS = Object.freeze([
    'restart',
    'start',
    'stop',
    'status',
    'dry_run',
    'record',
    'task_register',
    'task_unregister',
    'preflight',
    'verify_only',
]);

/** Actions that must run detached: they touch (or may kill) the calling host. */
export const DETACHED_ACTIONS = Object.freeze([
    'restart',
    'start',
    'stop',
    'preflight',
    'verify_only',
]);

const PROFILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const HOSTNAME_RE = /^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251})[A-Za-z0-9]$|^[A-Za-z0-9]$/;
const IPV6_RE = /^\[[0-9A-Fa-f:.]{2,45}\]$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
// Characters that either break a Windows path or would matter to a shell if any
// later layer ever concatenated one. Rejected by whitelist, not escaped. An
// apostrophe is legal in a Windows file name (e.g. "O'Brien") and harmless in an
// argv array, so it is allowed.
const PATH_FORBIDDEN_RE = /[<>"|?*;&`$\r\n]/;
const TASK_NAME_RE = /^[\p{L}\p{N}][\p{L}\p{N} ()._-]{0,63}$/u;

/**
 * Expand `%VAR%` (and `$env:`-free) placeholders plus a leading `~`.
 * A missing variable is an error: silently leaving `%NOPE%` in a path would
 * create a directory literally named `%NOPE%`.
 *
 * @param {string} value raw configured value
 * @param {string} field dotted key path used in the error
 * @returns {string}
 */
export function expandPath(value, field) {
    let out = value;
    out = out.replace(/%([A-Za-z_][A-Za-z0-9_]*)%/g, (_match, name) => {
        const resolved = process.env[name] ?? process.env[name.toUpperCase()];
        if (resolved === undefined) {
            throw new ConfigError(field, `environment variable %${name}% is not set`);
        }
        return resolved;
    });
    if (out === '~' || out.startsWith('~/') || out.startsWith('~\\')) {
        out = `${homedir()}${out.slice(1)}`;
    }
    return out;
}

/**
 * True when `value` is absolute for the current platform or for Windows.
 * The plugin targets Windows, so a `C:\...` value must count as absolute even
 * when the test suite runs elsewhere.
 *
 * @param {string} value
 * @returns {boolean}
 */
export function isAbsolutePath(value) {
    return isAbsolute(value) || win32.isAbsolute(value);
}

/**
 * @param {unknown} value
 * @param {string} field
 * @param {{ allowEmpty?: boolean, label?: string }} [options]
 * @returns {string} normalized absolute path, or `''` when allowed and empty
 */
export function asPathValue(value, field, options = {}) {
    const { allowEmpty = true } = options;
    if (value === undefined || value === null) {
        if (allowEmpty) return '';
        throw new ConfigError(field, 'must not be empty');
    }
    if (typeof value !== 'string') throw new ConfigError(field, 'expected a string path');
    if (CONTROL_RE.test(value)) throw new ConfigError(field, 'contains a control character');
    if (PATH_FORBIDDEN_RE.test(value)) {
        throw new ConfigError(field, 'contains a character not allowed in a path (< > " | ? * ; & ` or $)');
    }
    if (value === '') {
        if (allowEmpty) return '';
        throw new ConfigError(field, 'must not be empty');
    }
    if (value !== value.trim()) {
        throw new ConfigError(field, 'has leading or trailing whitespace');
    }
    const expanded = expandPath(value, field);
    if (!isAbsolutePath(expanded)) {
        throw new ConfigError(field, `must be an absolute path (got "${expanded}")`);
    }
    return win32.isAbsolute(expanded) ? win32.normalize(expanded) : normalize(expanded);
}

/**
 * @param {unknown} value
 * @param {string} field
 * @param {number} fallback
 * @param {{ min?: number, max?: number }} [range]
 * @returns {number}
 */
export function asInteger(value, field, fallback, range = {}) {
    if (value === undefined || value === null) return fallback;
    if (typeof value !== 'number' || !Number.isInteger(value)) {
        throw new ConfigError(field, 'expected an integer');
    }
    const { min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER } = range;
    if (value < min || value > max) {
        throw new ConfigError(field, `must be between ${min} and ${max} (got ${value})`);
    }
    return value;
}

/**
 * @param {unknown} value
 * @param {string} field
 * @param {boolean} fallback
 * @returns {boolean}
 */
export function asBooleanValue(value, field, fallback) {
    if (value === undefined || value === null) return fallback;
    if (typeof value !== 'boolean') throw new ConfigError(field, 'expected true or false');
    return value;
}

/**
 * @param {unknown} value
 * @param {string} field
 * @param {string} fallback
 * @returns {string}
 */
function asText(value, field, fallback) {
    if (value === undefined || value === null) return fallback;
    if (typeof value !== 'string') throw new ConfigError(field, 'expected a string');
    if (CONTROL_RE.test(value)) throw new ConfigError(field, 'contains a control character');
    return value;
}

/**
 * @param {unknown} value
 * @param {string} field
 * @param {string} fallback
 * @returns {string}
 */
export function asProfile(value, field = 'profile', fallback = DEFAULTS.profile) {
    const profile = asText(value, field, fallback);
    if (!PROFILE_RE.test(profile)) {
        throw new ConfigError(field, 'must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
    }
    return profile;
}

/**
 * @param {unknown} value
 * @param {string} field
 * @param {number} fallback
 * @returns {number}
 */
export function asPort(value, field = 'port', fallback = DEFAULTS.port) {
    return asInteger(value, field, fallback, { min: 1, max: 65535 });
}

/**
 * Validate a bind address: IPv4, IPv6 literal in brackets, or a hostname.
 *
 * @param {unknown} value
 * @param {string} field
 * @param {string} fallback
 * @returns {string}
 */
export function asBindHost(value, field = 'bindHost', fallback = DEFAULTS.bindHost) {
    const host = asText(value, field, fallback);
    const ipv4 = host.match(IPV4_RE);
    if (ipv4) {
        for (let index = 1; index <= 4; index += 1) {
            if (Number(ipv4[index]) > 255) {
                throw new ConfigError(field, `"${host}" has an octet above 255`);
            }
        }
        return host;
    }
    if (IPV6_RE.test(host)) return host;
    if (HOSTNAME_RE.test(host)) {
        if (host.split('.').some((label) => label === '' || label.length > 63)) {
            throw new ConfigError(field, `"${host}" is not a valid hostname`);
        }
        return host;
    }
    throw new ConfigError(field, 'must be an IPv4 address, a bracketed IPv6 literal, or a hostname');
}

/**
 * A scheduled-task name: letters/digits plus space, dot, underscore, dash,
 * parentheses. Windows rejects the rest anyway, and a name is passed as an argv
 * token so nothing else is safe to accept.
 *
 * @param {unknown} value
 * @param {string} field
 * @param {string} fallback
 * @returns {string}
 */
export function asTaskName(value, field = 'taskName', fallback = DEFAULTS.taskName) {
    const name = asText(value, field, fallback);
    if (!TASK_NAME_RE.test(name)) {
        throw new ConfigError(field, 'must start with a letter or digit and contain only letters, digits, space, ( ) . _ -');
    }
    return name;
}

/**
 * An executable override. Shape is validated here; existence is checked when
 * the engine is actually launched (so a plugin on a machine without PowerShell
 * still loads its tools and reports the problem per call).
 *
 * @param {unknown} value
 * @param {string} field
 * @returns {string} absolute `.exe` path, or `''` for auto-detection
 */
export function asExecutablePath(value, field = 'pwshPath') {
    const path = asPathValue(value, field, { allowEmpty: true });
    if (path !== '' && !/\.exe$/i.test(path)) {
        throw new ConfigError(field, 'must point to a .exe file');
    }
    return path;
}

/**
 * Free text that travels to the engine as one argv token and into
 * `pending-notice.json`. Newlines are rejected: they are never needed in a
 * notice and make log/JSON handling ambiguous.
 *
 * @param {unknown} value
 * @param {string} field
 * @param {number} max
 * @returns {string}
 */
export function asReason(value, field = 'reason', max = 500) {
    if (value === undefined || value === null) return '';
    if (typeof value !== 'string') throw new ConfigError(field, 'expected a string');
    if (CONTROL_RE.test(value)) throw new ConfigError(field, 'must be a single line without control characters');
    if (value.length > max) throw new ConfigError(field, `must be at most ${max} characters`);
    return value;
}

/**
 * A recorded launch command. It is data written to `boot-record.json`, passed as
 * one argv token; newlines and NUL are rejected.
 *
 * @param {unknown} value
 * @param {string} field
 * @param {number} max
 * @returns {string}
 */
export function asRecordCommand(value, field = 'recordCommand', max = 2000) {
    if (value === undefined || value === null) return '';
    if (typeof value !== 'string') throw new ConfigError(field, 'expected a string');
    if (value === '') return '';
    if (/[\u0000\r\n]/.test(value)) throw new ConfigError(field, 'must be a single line without NUL or newlines');
    if (value.length > max) throw new ConfigError(field, `must be at most ${max} characters`);
    return value;
}

/**
 * Normalize a DSH session id: accept `session-<id>` or the bare id, and reject
 * anything that is not a safe token. Returns `''` when there is no session.
 *
 * @param {unknown} value
 * @param {string} field
 * @returns {string}
 */
export function normalizeSessionId(value, field = 'session') {
    if (value === undefined || value === null || value === '') return '';
    if (typeof value !== 'string') throw new ConfigError(field, 'expected a string');
    const bare = value.replace(/^session-/, '');
    if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(bare)) {
        throw new ConfigError(field, 'must be a DSH session id (letters, digits, . _ : -)');
    }
    return bare;
}

/**
 * @param {unknown} value
 * @param {string} field
 * @returns {Readonly<Record<string, boolean>>}
 */
function asToolFlags(value, field) {
    if (value === undefined || value === null) return TOOL_FLAGS;
    if (typeof value !== 'object' || Array.isArray(value)) {
        throw new ConfigError(field, 'expected an object like { restart: true, status: true, preflight: true, result: true }');
    }
    const flags = { ...TOOL_FLAGS };
    for (const key of Object.keys(value)) {
        if (!Object.hasOwn(TOOL_FLAGS, key)) {
            throw new ConfigError(`${field}.${key}`, `unknown tool switch (accepted: ${Object.keys(TOOL_FLAGS).join(', ')})`);
        }
        flags[key] = asBooleanValue(value[key], `${field}.${key}`, TOOL_FLAGS[key]);
    }
    return Object.freeze(flags);
}

/**
 * Validate and freeze the plugin configuration (CONTRACT §4).
 *
 * @param {unknown} raw configuration object from `cordis.patch.yml`
 * @returns {Readonly<object>} every §4 key, defaults filled in
 */
export function normalizeConfig(raw) {
    if (raw === undefined || raw === null) raw = {};
    if (typeof raw !== 'object' || Array.isArray(raw)) {
        throw new ConfigError('config', 'expected an object');
    }
    for (const key of Object.keys(raw)) {
        if (!CONFIG_KEYS.includes(key)) {
            throw new ConfigError(key, `unknown configuration key (accepted: ${CONFIG_KEYS.join(', ')})`);
        }
    }
    const config = {
        profile: asProfile(raw.profile),
        port: asPort(raw.port),
        bindHost: asBindHost(raw.bindHost),
        dshHome: asPathValue(raw.dshHome, 'dshHome', { allowEmpty: true }),
        stateDir: asPathValue(raw.stateDir, 'stateDir', { allowEmpty: true }),
        taskName: asTaskName(raw.taskName),
        pwshPath: asExecutablePath(raw.pwshPath),
        readySec: asInteger(raw.readySec, 'readySec', DEFAULTS.readySec, { min: 5, max: 3600 }),
        verifyReadySec: asInteger(raw.verifyReadySec, 'verifyReadySec', DEFAULTS.verifyReadySec, { min: 5, max: 7200 }),
        graceSec: asInteger(raw.graceSec, 'graceSec', DEFAULTS.graceSec, { min: 0, max: 300 }),
        portFreeSec: asInteger(raw.portFreeSec, 'portFreeSec', DEFAULTS.portFreeSec, { min: 1, max: 600 }),
        restartDelayMs: asInteger(raw.restartDelayMs, 'restartDelayMs', DEFAULTS.restartDelayMs, { min: 0, max: 600000 }),
        toolTimeoutMs: asInteger(raw.toolTimeoutMs, 'toolTimeoutMs', DEFAULTS.toolTimeoutMs, { min: 1000, max: 600000 }),
        verifyTimeoutMs: asInteger(raw.verifyTimeoutMs, 'verifyTimeoutMs', DEFAULTS.verifyTimeoutMs, { min: 1000, max: 3600000 }),
        injectHostEnv: asBooleanValue(raw.injectHostEnv, 'injectHostEnv', DEFAULTS.injectHostEnv),
        tools: asToolFlags(raw.tools, 'tools'),
    };
    return Object.freeze(config);
}

/**
 * Merge per-call overrides over the plugin configuration and validate them.
 * This is the only place a tool argument becomes engine input.
 *
 * @param {Readonly<object>} config normalized configuration
 * @param {Record<string, unknown>} [call] tool arguments (already schema-validated)
 * @returns {Readonly<object>} the effective invocation
 */
export function resolveInvocation(config, call = {}) {
    if (call === undefined || call === null) call = {};
    if (typeof call !== 'object' || Array.isArray(call)) {
        throw new ConfigError('call', 'expected an object');
    }
    for (const key of Object.keys(call)) {
        if (!CALL_KEYS.includes(key)) {
            throw new ConfigError(key, `unknown call option (accepted: ${CALL_KEYS.join(', ')})`);
        }
    }
    const invocation = {
        profile: asProfile(call.profile, 'profile', config.profile),
        port: asPort(call.port, 'port', config.port),
        bindHost: asBindHost(call.bindHost, 'bindHost', config.bindHost),
        dshHome: asPathValue(call.dshHome, 'dshHome', { allowEmpty: true }) || config.dshHome,
        stateDir: asPathValue(call.stateDir, 'stateDir', { allowEmpty: true }) || config.stateDir,
        taskName: asTaskName(call.taskName, 'taskName', config.taskName),
        pwshPath: asExecutablePath(call.pwshPath, 'pwshPath') || config.pwshPath,
        readySec: asInteger(call.readySec, 'readySec', config.readySec, { min: 5, max: 3600 }),
        verifyReadySec: asInteger(call.verifyReadySec, 'verifyReadySec', config.verifyReadySec, { min: 5, max: 7200 }),
        graceSec: asInteger(call.graceSec, 'graceSec', config.graceSec, { min: 0, max: 300 }),
        portFreeSec: asInteger(call.portFreeSec, 'portFreeSec', config.portFreeSec, { min: 1, max: 600 }),
        waitIdleSec: asInteger(call.waitIdleSec, 'waitIdleSec', 0, { min: 0, max: 86400 }),
        idleMaxSec: asInteger(call.idleMaxSec, 'idleMaxSec', 300, { min: 0, max: 86400 }),
        delayMs: asInteger(call.delayMs, 'delayMs', config.restartDelayMs, { min: 0, max: 600000 }),
        session: normalizeSessionId(call.session),
        reason: asReason(call.reason),
        recordCommand: asRecordCommand(call.recordCommand),
        recordWorkingDirectory: asPathValue(call.recordWorkingDirectory, 'recordWorkingDirectory', { allowEmpty: true }),
        verifyTempRoot: asPathValue(call.verifyTempRoot, 'verifyTempRoot', { allowEmpty: true }),
        fast: asBooleanValue(call.fast, 'fast', false),
        forceUnverified: asBooleanValue(call.forceUnverified, 'forceUnverified', false),
        viaTask: asBooleanValue(call.viaTask, 'viaTask', false),
        tryCtrlC: asBooleanValue(call.tryCtrlC, 'tryCtrlC', false),
        doNotTouchDshHome: asBooleanValue(call.doNotTouchDshHome, 'doNotTouchDshHome', false),
    };
    return Object.freeze(invocation);
}

/**
 * Reject an action whose required input is missing, before anything is spawned.
 *
 * @param {string} action one of ACTIONS
 * @param {Readonly<object>} invocation result of {@link resolveInvocation}
 */
export function assertActionRequirements(action, invocation) {
    if (!ACTIONS.includes(action)) {
        throw new ConfigError('action', `unknown action "${action}" (accepted: ${ACTIONS.join(', ')})`);
    }
    if (action === 'record' && invocation.recordCommand === '') {
        throw new ConfigError('recordCommand', 'is required for action "record"');
    }
}
