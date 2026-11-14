#!/usr/bin/env node
/**
 * `dsh-restart-win` — forward arguments to the PowerShell engine.
 *
 * This is the command-line twin of the host tools: no config file, no
 * validation layer, exactly the engine's own switches and exit codes. Stdio is
 * inherited so a long restart prints live, the same way the old `.cmd` shim did.
 */
import { spawn } from 'node:child_process';
import { engineScriptPath, resolvePwsh } from '../lib/paths.js';
import { powershellPrefix } from '../lib/runner.js';

const forwarded = process.argv.slice(2);

let pwsh;
try {
    pwsh = resolvePwsh({ pwshPath: '' });
} catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(127);
}

const script = engineScriptPath();
const args = [...powershellPrefix(), '-File', script, ...forwarded];
const child = spawn(pwsh.path, args, { stdio: 'inherit', windowsHide: false });

child.once('error', (error) => {
    process.stderr.write(`dsh-restart-win: could not start ${pwsh.path}: ${error.message}\n`);
    process.exit(127);
});

child.once('close', (code, signal) => {
    if (typeof code === 'number') process.exit(code);
    process.stderr.write(`dsh-restart-win: engine terminated by ${signal ?? 'an unknown signal'}\n`);
    process.exit(1);
});
