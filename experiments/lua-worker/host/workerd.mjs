// SPDX-License-Identifier: MIT
import module from './kernel.wasm';
import application from './app.lua';
import { LuaRuntime, readBounded } from './runtime.mjs';
// Exported only to trusted host-side contract tests, never through the Lua API.
export const runtime = new LuaRuntime(module);
export function capabilities(env) {
  return {
    async get(key, { signal }) {
      // Read-only CONFIG protocol: 200 bytes, 404 absent; no writes or consistency claims.
      const response = await env.CONFIG.fetch(`https://config.invalid/${encodeURIComponent(key)}`, { signal, redirect: 'manual' });
      if (response.status === 404) { await response.body?.cancel(); return null; }
      if (response.status !== 200) { await response.body?.cancel(); throw new Error('CONFIG unavailable'); }
      return readBounded(response.body, signal);
    },
    fetch(path, { signal }) { return env.UPSTREAM.fetch(`https://upstream.invalid${path}`, { signal, redirect: 'manual' }); },
    log(message) { console.log(JSON.stringify({ source: 'lua', message })); }
  };
}
export function runWithContext(source, request, host, ctx, options) {
  const task = runtime.run(source, request, host, options);
  // Keep bounded cleanup alive even if the HTTP caller abandons its response.
  // This is a host lifecycle responsibility, not a guest waitUntil capability.
  ctx.waitUntil(task.then(() => {}, () => {}));
  return task;
}
export default {
  async fetch(request, env, ctx) {
    try { return await runWithContext(application, request, capabilities(env), ctx); }
    catch (error) {
      console.error(JSON.stringify({ source: 'lua', code: error.code, traceback: error.message }));
      const status = error.code === 'TIMEOUT' ? 504 : error.code === 'CAPACITY' ? 503 : error.code === 'BODY_LIMIT' ? 413 : 500;
      return new Response('Lua worker failed; see host logs.', { status });
    }
  }
};
