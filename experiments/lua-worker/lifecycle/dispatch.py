"""Selected resident adapter optimization, verified by the dispatch shootouts."""

def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'candidate source drift: {old[:100]!r}')
    return text.replace(old, new, 1)


def completion(source):
    # Routine completion is not an error: preserve the public reason fields but
    # avoid capturing an otherwise unused request stack on every successful call.
    source = once(source, 'const aborted = signal =>',
        "const FINISHED = Object.freeze(new WorkerError('invocation finished', 'CANCELLED'));\nconst aborted = signal =>")
    return once(source, "controller.abort(new WorkerError('invocation finished', 'CANCELLED'));", 'controller.abort(FINISHED);')


def optimize(source):
    source = completion(source)
    source = once(source, '''    const controller = new AbortController();
    const cancel = () => controller.abort(signal?.reason ?? new WorkerError('invocation cancelled', 'CANCELLED'));
    signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) cancel();
    const timer = setTimeout(() => controller.abort(new WorkerError('invocation deadline exceeded', 'TIMEOUT')), timeoutMs);
    const local = controller.signal;''', '''    // Allocate asynchronous cancellation machinery only when I/O is possible.
    // The deadline originates at admission, not at the first I/O operation.
    // Like the old timer, it cannot preempt synchronous Wasm; the VM hook and
    // external CPU/wall-time enforcement remain responsible for that work.
    const deadline = Date.now() + timeoutMs;
    let controller, timer, cancel, local = signal;
    const enableIO = () => {
      if (controller) return;
      controller = new AbortController();
      cancel = () => controller.abort(signal?.reason ?? new WorkerError('invocation cancelled', 'CANCELLED'));
      signal?.addEventListener('abort', cancel, { once: true });
      if (signal?.aborted) cancel();
      local = controller.signal;
      timer = setTimeout(() => controller.abort(new WorkerError('invocation deadline exceeded', 'TIMEOUT')),
        Math.max(0, deadline - Date.now()));
    };''')
    source = once(source, '      check(local);\n      const app = this.loadApplication(source);',
        '      if (local) check(local);\n      const app = this.loadApplication(source);')
    source = once(source, '''      const body = await readBounded(request.body, local);
      check(local);''', '''      let body;
      if (request.body) {
        enableIO();
        body = await readBounded(request.body, local);
      } else body = new Uint8Array();
      if (local) check(local);''')
    source = once(source, '      while (state === 3) {', '      while (state === 3) {\n        enableIO();')
    source = once(source, '''      clearTimeout(timer);
      signal?.removeEventListener('abort', cancel);
      controller.abort(FINISHED);''', '''      if (controller) {
        clearTimeout(timer);
        signal?.removeEventListener('abort', cancel);
        controller.abort(FINISHED);
      }''')
    return source
