#!/usr/bin/env python3
"""jeeves-ollama-bridge

Ollama on this host listens only on 127.0.0.1:11434 (locked down via a systemd
override: OLLAMA_HOST=127.0.0.1). The n8n container is on the default docker
bridge and therefore cannot reach host loopback. This tiny TCP relay listens on
the docker-bridge gateway address (172.17.0.1:11434) and forwards to Ollama on
127.0.0.1:11434, so containers can reach Ollama at http://172.17.0.1:11434
WITHOUT exposing Ollama on any public interface and WITHOUT modifying Ollama.

This mirrors the existing jeeves-bridge pattern (a host python3 process bound to
172.17.0.1). It touches nothing that already existed.
"""
import asyncio

LISTEN_HOST = "172.17.0.1"
LISTEN_PORT = 11434
TARGET_HOST = "127.0.0.1"
TARGET_PORT = 11434


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while not reader.at_eof():
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer):
    try:
        server_reader, server_writer = await asyncio.open_connection(
            TARGET_HOST, TARGET_PORT
        )
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(
        pipe(client_reader, server_writer),
        pipe(server_reader, client_writer),
    )


async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
