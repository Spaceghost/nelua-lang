// Read-only in-memory fixture, not a durable database or Workers KV emulator.
const data = new Map([['greeting', 'Hello from Lua 5.5']]);
export default { fetch(request) {
  const key = decodeURIComponent(new URL(request.url).pathname.slice(1));
  return data.has(key) ? new Response(data.get(key)) : new Response(null, { status: 404 });
} };
