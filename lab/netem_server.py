"""Lab-only controller sharing the server network namespace, never published."""
from aiohttp import web
from netem import configure


async def command(request):
    body = await request.json()
    await configure(body["destination"], body["profile"])
    return web.json_response({"ok": True})


app = web.Application(client_max_size=1024)
app.router.add_post("/command", command)
app.router.add_get("/health", lambda _: web.json_response({"ok": True}))

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=9001)
