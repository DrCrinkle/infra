// edge-lab hello Bun service. Minimal HTTP server, no dependencies.
// Reverse-proxied by Caddy under /api/. Listens on PORT (default 3000), bound
// to loopback — only Caddy talks to it.
const port = Number(process.env.PORT ?? 3000);

Bun.serve({
  hostname: "127.0.0.1",
  port,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/api/hello" || url.pathname === "/hello") {
      return Response.json({
        service: "edge-lab hello-bun",
        ok: true,
        runtime: `Bun ${Bun.version}`,
        time: new Date().toISOString(),
      });
    }
    return new Response("not found\n", { status: 404 });
  },
});

console.log(`hello-bun listening on 127.0.0.1:${port}`);
