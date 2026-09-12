// SPDX-License-Identifier: MIT
// Coarse external lifetime bound. This is NOT a per-request or tenant sandbox.
// Unlike a Worker timer, this process remains able to kill a wedged Wasm/C call.
import { spawn } from 'node:child_process';
const [limit, command, ...args] = process.argv.slice(2);
const ms = Number(limit);
if (!command || !Number.isSafeInteger(ms) || ms < 1) throw new Error('usage: supervise.mjs MILLISECONDS COMMAND [ARGS...]');
const child = spawn(command, args, { stdio: 'inherit' });
let expired = false, killer;
const timer = setTimeout(() => {
  expired = true; child.kill('SIGTERM');
  killer = setTimeout(() => child.kill('SIGKILL'), 250);
}, ms);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('error', error => { console.error(error.message); clearTimeout(timer); process.exitCode = 127; });
child.on('exit', code => { clearTimeout(timer); clearTimeout(killer); process.exitCode = expired ? 124 : (code ?? 1); });
