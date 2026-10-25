#!/usr/bin/env python3
"""Optional real gRPC echo server; install grpcio in a disposable virtual environment."""

from concurrent import futures

try:
    import grpc
except ImportError:
    raise SystemExit(
        "Optional dependency missing. Follow README.md: create a venv, then pip install grpcio."
    )


def unary(request, context):
    return request


def server_stream(request, context):
    for _ in range(3):
        if context.is_active():
            yield request


def client_stream(requests, context):
    last = b""
    for index, request in enumerate(requests):
        if index >= 100:
            context.abort(grpc.StatusCode.RESOURCE_EXHAUSTED, "100 messages maximum")
        last = request
    return last


def bidi(requests, context):
    for index, request in enumerate(requests):
        if index >= 100:
            context.abort(grpc.StatusCode.RESOURCE_EXHAUSTED, "100 messages maximum")
        yield request


if __name__ == "__main__":
    server = grpc.server(
        futures.ThreadPoolExecutor(max_workers=4),
        options=[
            ("grpc.max_receive_message_length", 1048576),
            ("grpc.max_send_message_length", 1048576),
        ],
        maximum_concurrent_rpcs=8,
    )
    server.add_generic_rpc_handlers(
        (
            grpc.method_handlers_generic_handler(
                "rill.kit.Echo",
                {
                    "Unary": grpc.unary_unary_rpc_method_handler(unary),
                    "ServerStream": grpc.unary_stream_rpc_method_handler(server_stream),
                    "ClientStream": grpc.stream_unary_rpc_method_handler(client_stream),
                    "Bidi": grpc.stream_stream_rpc_method_handler(bidi),
                },
            ),
        )
    )
    if server.add_insecure_port("127.0.0.1:18994") == 0:
        raise SystemExit("Port 18994 unavailable")
    server.start()
    print(
        "gRPC echo ready at 127.0.0.1:18994 (plaintext, proto supplied, no reflection). Ctrl+C stops.",
        flush=True,
    )
    try:
        server.wait_for_termination()
    except KeyboardInterrupt:
        server.stop(0).wait()
