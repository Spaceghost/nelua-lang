  loadApplication(source) {
    if (this.poisoned) throw new WorkerError('kernel retired after trap', 'WASM_TRAP');
    if (typeof source !== 'string') throw new WorkerError('application requires immutable text source', 'SOURCE');
    if (this.appId) {
      if (this.appSource !== source) throw new WorkerError('new source requires explicit eviction or a new worker', 'VERSION');
      return this.appId;
    }
    const code = bounded(source, LIMIT, 'source');
    const id = this.e.wa_open();
    if (!id) throw new WorkerError('application already resident', 'CAPACITY');
    try {
      const seed = crypto.getRandomValues(new Uint32Array(1))[0];
      const result = this.withBytes([code], (p, n) => this.e.wa_load(id, p, n, seed));
      if (result !== 0) {
        const message = decoder.decode(new Uint8Array(this.e.memory.buffer, this.e.wa_error_data(), this.e.wa_error_size()));
        throw new WorkerError(message, 'APP_LOAD');
      }
      this.appId = id; this.appSource = source;
      return id;
    } catch (error) {
      if (error instanceof WebAssembly.RuntimeError) this.poisoned = true;
      if (!this.poisoned && this.e.wa_release(id) !== 0) throw new WorkerError('application cleanup failed', 'CLEANUP');
      throw error;
    }
  }
  unloadApplication() {
    if (this.poisoned) throw new WorkerError('trapped instance requires outer recycling', 'WASM_TRAP');
    if (this.admitted || this.outstanding || this.e.wa_pending()) throw new WorkerError('cannot evict an active worker', 'BUSY');
    if (this.appId && this.e.wa_release(this.appId) !== 0) throw new WorkerError('application cleanup failed', 'CLEANUP');
    this.appId = 0; this.appSource = null;
  }
  collectApplication() {
    if (this.admitted || this.outstanding || this.e.wa_collect(this.appId) !== 0) throw new WorkerError('application is busy or absent', 'BUSY');
  }
