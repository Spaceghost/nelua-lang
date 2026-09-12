using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "lua", worker = (
      compatibilityDate = "2026-09-01",
      modules = [
        (name = "workerd.mjs", esModule = embed "host/workerd.mjs"),
        (name = "runtime.mjs", esModule = embed "host/runtime.mjs"),
        (name = "kernel.wasm", wasm = embed "dist/kernel.wasm"),
        (name = "app.lua", text = embed "examples/hello.lua")
      ],
      bindings = [(name = "CONFIG", service = "config"), (name = "UPSTREAM", service = "upstream")]
    )),
    (name = "config", worker = (compatibilityDate = "2026-09-01", modules = [(name = "config.mjs", esModule = embed "examples/config.mjs")])),
    (name = "upstream", worker = (compatibilityDate = "2026-09-01", modules = [(name = "upstream.mjs", esModule = embed "examples/upstream.mjs")]))
  ],
  sockets = [(name = "http", address = "127.0.0.1:8787", http = (), service = "lua")]
);
