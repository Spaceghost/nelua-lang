// SPDX-License-Identifier: MIT
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const strictDecoder = new TextDecoder('utf-8', { fatal: true });
export const LIMIT = 65536;
export class WorkerError extends Error {
  constructor(message, code = 'LUA_ERROR') { super(message); this.name = 'WorkerError'; this.code = code; }
}
const aborted = signal => signal.reason instanceof Error ? signal.reason : new WorkerError('invocation cancelled', 'CANCELLED');
function check(signal) { if (signal.aborted) throw aborted(signal); }
export function raceAbort(promise, signal) {
  check(signal);
  return new Promise((resolve, reject) => {
    const abort = () => { signal.removeEventListener('abort', abort); reject(aborted(signal)); };
    signal.addEventListener('abort', abort, { once: true });
    Promise.resolve(promise).then(
      value => { signal.removeEventListener('abort', abort); resolve(value); },
      error => { signal.removeEventListener('abort', abort); reject(error); });
  });
}
export async function readBounded(stream, signal) {
  check(signal);
  if (!stream) return new Uint8Array();
  const reader = stream.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener('abort', cancel, { once: true });
  const chunks = []; let length = 0;
  try {
    for (;;) {
      const { value, done } = await raceAbort(reader.read(), signal);
      if (done) break;
      length += value.byteLength;
      if (length > LIMIT) throw new WorkerError('body limit exceeded', 'BODY_LIMIT');
      chunks.push(value);
    }
    const body = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
    return body;
  } catch (error) { cancel(); throw error; }
  finally { signal.removeEventListener('abort', cancel); reader.releaseLock(); }
}
function bytes(value) {
  if (typeof value === 'string') return encoder.encode(value);
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  throw new WorkerError('host returned an invalid byte value', 'HOST_ERROR');
}
function bounded(value, max, label) {
  const b = bytes(value);
  if (b.length > max) throw new WorkerError(`${label} limit exceeded`, 'BODY_LIMIT');
  return b;
}
export class LuaRuntime {
  constructor(module) {
    // These libc imports are denied, not a filesystem, clock, or general WASI bridge.
    const denied = () => 8; // EBADF
    const wasi = { fd_close: denied, fd_seek: denied, fd_write: denied,
      environ_sizes_get: denied, environ_get: denied, clock_time_get: () => 52,
      proc_exit: code => { throw new WorkerError(`Wasm process exit ${code}`, 'WASM_TRAP'); } };
    const env = { emscripten_notify_memory_growth() {}, emscripten_date_now: () => 0 };
    for (const item of WebAssembly.Module.imports(module)) {
      if (!(item.module === 'env' && item.name in env) &&
          !(item.module === 'wasi_snapshot_preview1' && item.name in wasi))
        throw new Error(`unapproved Wasm import ${item.module}.${item.name}`);
    }
    this.e = new WebAssembly.Instance(module, { env, wasi_snapshot_preview1: wasi }).exports;
    this.e._initialize?.();
    if (this.e.lw_abi_version() !== 1) throw new Error('kernel ABI mismatch');
    this.admitted = 0; this.outstanding = 0; this.poisoned = false;
  }
  stats() { return { active: this.e.lw_active(), luaBytes: this.e.lw_bytes(),
    wasmBytes: this.e.memory.buffer.byteLength, admitted: this.admitted, outstanding: this.outstanding }; }
  copy(id) {
    return new Uint8Array(this.e.memory.buffer, this.e.lw_data(id), this.e.lw_size(id)).slice();
  }
  withBytes(values, fn) {
    const allocated = [];
    try {
      const args = [];
      for (const value of values) {
        const p = this.e.malloc(Math.max(value.length, 1));
        if (!p) throw new WorkerError('Wasm allocation limit', 'MEMORY_LIMIT');
        allocated.push(p);
        new Uint8Array(this.e.memory.buffer, p, value.length).set(value);
        args.push(p, value.length);
      }
      return fn(...args);
    } finally { for (const p of allocated) this.e.free(p); }
  }
  async operation(kind, argument, host, signal) {
    check(signal);
    if (this.outstanding >= 8) throw new WorkerError('host operation capacity reached', 'CAPACITY');
    this.outstanding++;
    try {
      const text = strictDecoder.decode(argument);
      if (kind === 1) {
        const value = await host.get(text, { signal });
        return { status: value === null ? 404 : 200, body: value === null ? new Uint8Array() : bounded(value, LIMIT, 'storage value') };
      }
      if (kind === 2) {
        // No absolute URLs, redirects to ambient fetch, credentials, or arbitrary JS bridge.
        const url = new URL(text, 'https://upstream.invalid');
        if (!text.startsWith('/') || text.startsWith('//') || url.origin !== 'https://upstream.invalid' || url.username || url.password)
          throw new WorkerError('UPSTREAM accepts same-origin paths only', 'CAPABILITY');
        const response = await host.fetch(url.pathname + url.search, { signal });
        if (!(response instanceof Response)) throw new WorkerError('invalid host response', 'HOST_ERROR');
        return { status: response.status, body: await readBounded(response.body, signal) };
      }
      if (kind === 3) { await host.log(text); return { status: 200, body: new Uint8Array() }; }
      throw new WorkerError('unknown operation', 'HOST_ERROR');
    } finally { this.outstanding--; }
  }
  async run(source, request, host, { signal = request.signal, timeoutMs = 2500 } = {}) {
    if (this.poisoned) throw new WorkerError('kernel retired after Wasm trap', 'WASM_TRAP');
    if (this.admitted >= 8) throw new WorkerError('invocation capacity reached', 'CAPACITY');
    for (const key of ['get', 'fetch', 'log']) if (typeof host[key] !== 'function') throw new Error(`missing capability: ${key}`);
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 60000) throw new Error('invalid timeout');
    this.admitted++;
    const controller = new AbortController();
    const cancel = () => controller.abort(signal?.reason ?? new WorkerError('invocation cancelled', 'CANCELLED'));
    signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) cancel();
    const timer = setTimeout(() => controller.abort(new WorkerError('invocation deadline exceeded', 'TIMEOUT')), timeoutMs);
    const local = controller.signal;
    let id = 0;
    try {
      check(local);
      const code = bounded(source, LIMIT, 'source');
      const method = bounded(request.method, 16, 'method');
      const url = bounded(request.url, 4096, 'URL');
      const body = await readBounded(request.body, local);
      check(local);
      id = this.e.lw_open();
      if (!id) throw new WorkerError('kernel capacity reached', 'CAPACITY');
      const seed = crypto.getRandomValues(new Uint32Array(1))[0];
      let state = this.withBytes([code, method, url, body], (...args) => this.e.lw_start(id, ...args, seed));
      while (state === 3) {
        const sequence = this.e.lw_sequence(id), kind = this.e.lw_kind(id);
        const argument = this.copy(id); // Never retain a live Wasm view across an await.
        let result, ok = 1;
        try { result = await raceAbort(this.operation(kind, argument, host, local), local); }
        catch (error) {
          check(local); // Cancellation never resumes Lua with a recoverable host error.
          ok = 0;
          // Do not pass backend exception text (possibly containing credentials) into Lua.
          result = { status: 502, body: encoder.encode(`host operation failed (${error instanceof WorkerError ? error.code : 'HOST_ERROR'})`) };
        }
        check(local);
        state = this.withBytes([result.body], (p, n) => this.e.lw_complete(id, sequence, ok, result.status, p, n));
      }
      if (state === 5) throw new WorkerError(decoder.decode(this.copy(id)));
      if (state !== 4) throw new WorkerError(`invalid kernel state ${state}`, 'PROTOCOL');
      const status = this.e.lw_status(id), response = this.copy(id);
      return new Response([204, 205, 304].includes(status) || request.method === 'HEAD' ? null : response,
        { status, headers: { 'content-type': 'text/plain; charset=utf-8' } });
    } catch (error) {
      if (error instanceof WebAssembly.RuntimeError) this.poisoned = true;
      throw error;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', cancel);
      controller.abort(new WorkerError('invocation finished', 'CANCELLED'));
      this.admitted--;
      if (id && !this.poisoned && this.e.lw_release(id) !== 0) throw new WorkerError('kernel cleanup accounting failure', 'CLEANUP');
    }
  }
}
