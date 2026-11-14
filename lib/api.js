/**
 * HTTP API behind the DSH panel.
 *
 * The panel is a client half of this plugin; it is served by the host and talks
 * to these routes on the same origin (so the host's session cookie / token auth
 * already applies). Every route delegates to the **same tool definitions** the
 * agent uses — one code path, no second source of truth.
 *
 * The dispatcher is pure with respect to HTTP: `dispatch({ method, url, body })`
 * takes plain values and returns the tool's canonical object. `handle(req,res)`
 * is the thin adapter, which is what the host registers.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/** Route prefix the host mounts and the client calls. */
export const ROUTE = '/dsh-restart-win';

/** Request bodies are tiny JSON objects; anything larger is a mistake. */
const MAX_BODY_BYTES = 8192;

/** Actions the panel may trigger. `task_*` and `record` stay CLI/agent-only. */
const PANEL_ACTIONS = Object.freeze(['restart', 'stop', 'start', 'dry_run', 'preflight']);

/**
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {unknown} payload
 */
function send(res, status, payload) {
    let text;
    try {
        text = JSON.stringify(payload);
    } catch (error) {
        text = JSON.stringify({ ok: false, error: `response is not serialisable: ${String(error?.message ?? error)}` });
        status = 500;
    }
    try {
        res.statusCode = status;
        res.setHeader('content-type', 'application/json; charset=utf-8');
        res.setHeader('cache-control', 'no-store');
        res.end(text);
    } catch {
        // The client went away (a restart killed the host mid-response). Nothing to do.
    }
}

/**
 * Same-origin guard.
 *
 * The host itself only listens on loopback, so `Host` must be a loopback
 * authority. The renderer is not always an http origin:
 *   - the web UI sends `Origin: http://127.0.0.1:<port>` (or no Origin on a
 *     same-origin GET);
 *   - the desktop shell renders from the `dsh-app://` custom scheme, whose
 *     requests carry `Origin: null` (opaque origin). Rejecting that broke every
 *     mutating call in the app; a remote page can never produce `null` here
 *     because a JSON POST from another origin needs a CORS preflight the host
 *     never grants.
 *
 * @param {import('node:http').IncomingMessage} req
 * @returns {boolean}
 */
export function isSameOrigin(req) {
    const host = String(req.headers?.host ?? '');
    if (!/^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i.test(host)) return false;
    const origin = req.headers?.origin;
    if (!origin) return true;
    if (origin === 'null') return true;
    try {
        const url = new URL(origin);
        if (url.host && url.host.toLowerCase() === host.toLowerCase()) return true;
        return url.protocol === 'dsh-app:' || url.protocol === 'file:';
    } catch {
        return false;
    }
}

/**
 * @param {import('node:http').IncomingMessage} req
 * @returns {Promise<Record<string, unknown>>}
 */
async function readJsonBody(req) {
    let size = 0;
    const chunks = [];
    for await (const chunk of req) {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
            const error = new Error(`request body exceeds ${MAX_BODY_BYTES} bytes`);
            error.status = 413;
            throw error;
        }
        chunks.push(chunk);
    }
    if (size === 0) return {};
    let value;
    try {
        value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch {
        const error = new Error('request body must be JSON');
        error.status = 400;
        throw error;
    }
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        const error = new Error('request body must be a JSON object');
        error.status = 400;
        throw error;
    }
    return value;
}

/** @param {string} message @param {number} status */
function httpError(message, status) {
    const error = new Error(message);
    error.status = status;
    return error;
}

/**
 * Compact one restart-history record for the panel: the audit file keeps 16+
 * fields, the panel only needs the ones it renders.
 *
 * @param {Record<string, unknown>} record
 */
function historyEntry(record) {
    return {
        ts: typeof record.ts === 'string' ? record.ts : null,
        result: typeof record.result === 'string' ? record.result : null,
        rc: typeof record.rc === 'number' ? record.rc : null,
        hostKind: typeof record.host_kind === 'string' ? record.host_kind : null,
        mainPid: Number.isInteger(record.main_pid) ? record.main_pid : null,
        newMainPid: Number.isInteger(record.new_main_pid) ? record.new_main_pid : null,
        targetPid: Number.isInteger(record.target_pid) ? record.target_pid : null,
        newPid: Number.isInteger(record.new_pid) ? record.new_pid : null,
        port: Number.isInteger(record.resolved_port) ? record.resolved_port : null,
        url: typeof record.url === 'string' ? record.url : null,
    };
}

/**
 * @param {{
 *   config: Readonly<Record<string, unknown>>,
 *   paths: { dshHome: string, stateDir: string },
 *   tools: Array<{ name: string, execute: (args: Record<string, unknown>, exec?: unknown) => Promise<unknown> }>,
 *   version?: string,
 * }} options
 */
export function createApi(options) {
    const { config, paths, tools, version = '' } = options;
    if (!Array.isArray(tools)) throw new TypeError('createApi: tools must be an array');
    const byName = new Map(tools.map((tool) => [tool.name, tool]));
    const required = ['win_restart', 'win_restart_status', 'win_restart_result'];
    for (const name of required) {
        if (!byName.has(name)) throw new TypeError(`createApi: tool ${name} is not registered`);
    }

    /** @param {Record<string, unknown>} args */
    async function run(toolName, args) {
        const tool = byName.get(toolName);
        return tool.execute(args, {});
    }

    function meta() {
        return {
            ok: true,
            version,
            profile: config.profile,
            hostKind: config.hostKind,
            dshHome: paths.dshHome,
            stateDir: paths.stateDir,
        };
    }

    /** @param {number} limit */
    function history(limit) {
        const count = Number.isInteger(limit) ? Math.min(Math.max(limit, 1), 20) : 5;
        const file = join(paths.stateDir, 'restart-history.jsonl');
        let text = '';
        try {
            text = readFileSync(file, 'utf8');
        } catch {
            return { ok: true, entries: [], file };
        }
        const lines = text.split('\n').filter((line) => line.trim() !== '').slice(-count);
        const entries = [];
        for (const line of lines) {
            try {
                entries.push(historyEntry(JSON.parse(line)));
            } catch {
                // A truncated last line (the host died mid-write) is skipped, not fatal.
            }
        }
        return { ok: true, entries: entries.reverse(), file };
    }

    /** @param {Record<string, unknown>} body */
    async function action(body) {
        const requested = typeof body.action === 'string' ? body.action : '';
        if (!PANEL_ACTIONS.includes(requested)) {
            throw httpError(`unknown action "${requested}" (accepted: ${PANEL_ACTIONS.join(', ')})`, 400);
        }
        const args = { action: requested };
        if (requested === 'restart') {
            if (body.fast === true) args.fast = true;
            if (body.forceUnverified === true) args.forceUnverified = true;
            if (typeof body.reason === 'string' && body.reason.trim() !== '') args.reason = body.reason.trim().slice(0, 500);
        }
        return run('win_restart', args);
    }

    /** @param {URLSearchParams} query */
    async function result(query) {
        const runId = (query.get('runId') ?? '').trim();
        const waitMs = Number(query.get('waitMs') ?? '0');
        const args = {};
        if (runId !== '') args.runId = runId;
        if (Number.isFinite(waitMs) && waitMs > 0) args.waitMs = Math.min(Math.floor(waitMs), 120000);
        return run('win_restart_result', args);
    }

    /**
     * @param {{ method: string, url: URL, body: Record<string, unknown>, headers?: Record<string, string> }} request
     */
    async function dispatch(request) {
        const { method, url, body } = request;
        const path = url.pathname.replace(/\/+$/, '');
        if (method === 'GET' && path === `${ROUTE}/api/status`) return run('win_restart_status', {});
        if (method === 'GET' && path === `${ROUTE}/api/meta`) return meta();
        if (method === 'GET' && path === `${ROUTE}/api/result`) return result(url.searchParams);
        if (method === 'GET' && path === `${ROUTE}/api/history`) {
            const raw = Number(url.searchParams.get('limit') ?? '5');
            return history(Number.isFinite(raw) ? Math.floor(raw) : 5);
        }
        if (method === 'POST' && path === `${ROUTE}/api/action`) return action(body);
        throw httpError(`unknown ${method} ${path}`, 404);
    }

    /**
     * @param {import('node:http').IncomingMessage} req
     * @param {import('node:http').ServerResponse} res
     */
    async function handle(req, res) {
        try {
            if (!isSameOrigin(req)) throw httpError('只接受同源请求（Origin 不匹配）', 403);
            const url = new URL(req.url ?? '/', 'http://127.0.0.1');
            const body = req.method === 'POST' ? await readJsonBody(req) : {};
            const value = await dispatch({ method: req.method ?? 'GET', url, body, headers: req.headers });
            send(res, 200, value);
        } catch (error) {
            send(res, Number.isInteger(error?.status) ? error.status : 500, {
                ok: false,
                error: String(error?.message ?? error),
            });
        }
    }

    return { handle, dispatch, meta, history };
}
