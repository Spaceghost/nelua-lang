// Configured subrequest fixture. No public-network dependency in contract tests.
export default { async fetch(request) {
  const name = new URL(request.url).pathname.split('/').at(-1);
  await new Promise(resolve => setTimeout(resolve, name === 'slow' ? 100 : 5));
  return new Response(name);
} };
