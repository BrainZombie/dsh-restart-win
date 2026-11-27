/**
 * Two HTTP faces for `test/probe-hostport.ps1`, on ports chosen by the caller.
 *
 *   node face-server.mjs <portA> <portB> <modeB: 401|404> <delayMs> <delayCount>
 *
 * Face A is always the host's *router fallback*: 404 + `content-type: application/json`,
 * answered in microseconds — the shape that used to win `-Status` whenever the real
 * face timed out.
 *
 * Face B is the host's own panel face: 401 (or 404 in `plain` mode) with `text/plain`.
 * The first `delayCount` requests are held for `delayMs` before answering, which is how
 * a busy host looks to a 5 s probe: the socket connects, then nothing comes back.
 *
 * Prints one line — `READY <portA> <portB>` — and stays up until killed.
 */
import { createServer } from 'node:http';

const [portA, portB, modeB = '401', delayMs = '0', delayCount = '0'] = process.argv.slice(2);
const delay = Number(delayMs) || 0;
let remainingSlow = Number(delayCount) || 0;

function faceA(req, res) {
    res.writeHead(404, { 'content-type': 'application/json', connection: 'close' });
    res.end('{"error":"not registered yet"}');
}

function faceB(req, res) {
    const answer = () => {
        res.writeHead(Number(modeB), { 'content-type': 'text/plain', connection: 'close' });
        res.end(modeB === '401' ? 'dsh web authentication required' : 'not found');
    };
    if (remainingSlow > 0) {
        remainingSlow -= 1;
        setTimeout(answer, delay);
    } else {
        answer();
    }
}

const a = createServer(faceA);
const b = createServer(faceB);

a.listen(Number(portA), '127.0.0.1', () => {
    b.listen(Number(portB), '127.0.0.1', () => {
        process.stdout.write(`READY ${portA} ${portB}\n`);
    });
});

for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => {
        a.close();
        b.close();
        process.exit(0);
    });
}
