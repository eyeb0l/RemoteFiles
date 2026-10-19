"""Loopback TCP proxy that adds half the requested RTT (and an optional bandwidth cap) to each direction.

Used by scripts/benchmark-latency.sh. It models fixed delay only: no loss, jitter or reordering.
"""
import argparse, asyncio

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--listen", type=int, required=True)
    p.add_argument("--target", type=int, required=True)
    p.add_argument("--rtt-ms", type=float, required=True)
    p.add_argument("--mbit", type=float, default=0, help="per-direction bandwidth cap; 0 = unlimited")
    a = p.parse_args()
    delay, rate = a.rtt_ms / 2000.0, a.mbit * 125_000  # bytes per second

    async def pipe(reader, writer):
        loop = asyncio.get_running_loop()
        queue = asyncio.Queue()
        async def receive():
            busy_until = 0.0
            while True:
                data = await reader.read(65536)
                now = loop.time()
                if rate and data:  # serialization delay before propagation
                    busy_until = max(now, busy_until) + len(data) / rate
                    now = busy_until
                queue.put_nowait((now + delay, data))
                if not data: return
        async def send():
            while True:
                due, data = await queue.get()
                await asyncio.sleep(max(0.0, due - loop.time()))
                if not data:
                    writer.close(); return
                writer.write(data); await writer.drain()
        await asyncio.gather(receive(), send(), return_exceptions=True)

    async def handle(client_reader, client_writer):
        try:
            server_reader, server_writer = await asyncio.open_connection("127.0.0.1", a.target)
        except OSError:
            client_writer.close(); return
        await asyncio.gather(pipe(client_reader, server_writer), pipe(server_reader, client_writer), return_exceptions=True)

    async def serve():
        server = await asyncio.start_server(handle, "127.0.0.1", a.listen)
        print(f"proxy ready {a.listen} -> {a.target} rtt={a.rtt_ms}ms mbit={a.mbit or 'unlimited'}", flush=True)
        async with server: await server.serve_forever()
    asyncio.run(serve())

if __name__ == "__main__":
    main()
