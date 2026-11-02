"""A stand-in nix-grpc-store for the client tests in ../server_tests.zig.

It speaks the services of ../../../../../iets/proto/nix_remote.proto through
grpcio's generic handlers, with the protobuf written by hand, so it needs only
python3 with grpcio (3.14 for compression.zstd). `server.py CERT KEY [CA]`
serves TLS, asking for a client certificate from CA when it is named. It
prints its port, then serves until stdin closes.
"""

import hashlib
import sys
import threading
from concurrent import futures

import grpc
from compression import zstd


def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def fbytes(tag, b):
    if isinstance(b, str):
        b = b.encode()
    return varint(tag << 3 | 2) + varint(len(b)) + b


def fvarint(tag, n):
    return varint(tag << 3) + varint(n)


def parse(b):
    """Field number to the list of its values: ints or bytes."""
    out, i = {}, 0
    while i < len(b):
        k, i = read_varint(b, i)
        tag, wt = k >> 3, k & 7
        if wt == 0:
            v, i = read_varint(b, i)
        elif wt == 2:
            n, i = read_varint(b, i)
            v, i = b[i : i + n], i + n
        else:
            raise ValueError("wire type %d" % wt)
        out.setdefault(tag, []).append(v)
    return out


def read_varint(b, i):
    v = shift = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7F) << shift
        if c < 0x80:
            return v, i
        shift += 7


def u64(n):
    return n.to_bytes(8, "little")


def wstr(s):
    if isinstance(s, str):
        s = s.encode()
    return u64(len(s)) + s + b"\0" * ((8 - len(s) % 8) % 8)


state = {"upload": None, "flaky": 0, "uploaded": False, "lock": threading.Lock()}


def store_info(req, ctx):
    return fvarint(1, 1)


def query_valid_paths(req, ctx):
    f = parse(req)
    paths = [p for p in f.get(1, []) if b"missing" not in p]
    return b"".join(fbytes(1, p) for p in paths)


def add_multiple(it, ctx):
    data = bytearray()
    first = True
    for msg in it:
        f = parse(msg)
        d = f.get(3, [b""])[0]
        if first and d:
            ctx.abort(grpc.StatusCode.INVALID_ARGUMENT, "the first message carries only flags")
        first = False
        data += d
    raw = zstd.decompress(bytes(data))
    with state["lock"]:
        state["upload"] = (hashlib.sha256(raw).hexdigest(), len(raw))
        state["uploaded"] = True
    return b""


def query_missing(req, ctx):
    f = parse(req)
    target = f.get(1, [b""])[0]
    if target == b"flaky":
        with state["lock"]:
            state["flaky"] += 1
            n = state["flaky"]
        if n < 3:
            ctx.abort(grpc.StatusCode.UNAVAILABLE, "upstream connect error or disconnect/reset before headers")
        return fbytes(1, "after %d tries" % n)
    if target == b"denied":
        ctx.abort(grpc.StatusCode.PERMISSION_DENIED, "no access to 100% of it")
    if target == b"last-upload":
        h, n = state["upload"]
        return fbytes(1, h) + fbytes(2, str(n)) + fvarint(4, n)
    return b""


def fetch_nars(req, ctx):
    f = parse(req)
    c = zstd.ZstdCompressor()
    for i, p in enumerate(f.get(1, [])):
        payload = p * 20000
        third = len(payload) // 3
        parts = [payload[:third], payload[third : 2 * third], payload[2 * third :]]
        for j, part in enumerate(parts):
            z = c.compress(part) + c.flush(zstd.ZstdCompressor.FLUSH_BLOCK)
            yield fvarint(1, i) + fbytes(2, z) + (fvarint(3, 1) if j == 2 else b"")


def build_result(status, msg):
    return u64(status) + wstr(msg) + u64(1) + u64(0) + u64(1000) + u64(1042) + u64(0) + u64(0) + u64(0)


def build_derivation(req, ctx):
    f = parse(req)
    drv = f.get(1, [b""])[0].decode()
    md = dict(ctx.invocation_metadata())
    if drv.endswith("needs-upload.drv") and not state["uploaded"]:
        ctx.abort(grpc.StatusCode.NOT_FOUND, "the worker lacks " + drv)
    if f.get(4, [0])[0] != (1 << 8 | 37):
        ctx.abort(grpc.StatusCode.INVALID_ARGUMENT, "protocol")
    yield fbytes(1, "building %s on %s for %s\n" % (drv, md.get("x-nix-worker"), md.get("x-nix-system")))
    yield fbytes(3, "buildPhase")
    status = 3 if "fails" in drv else 0
    yield fbytes(2, fbytes(1, build_result(status, "builder failed" if status else "")))


def schedule(it, ctx):
    for msg in it:
        out = b""
        for cm in parse(msg).get(1, []):
            want = parse(cm).get(1)
            if not want:
                continue
            drv = parse(want[0]).get(1, [b""])[0]
            if b"cached" in drv:
                out += fbytes(1, fbytes(2, fbytes(1, drv)))
            else:
                out += fbytes(1, fbytes(1, fbytes(1, drv) + fbytes(2, "w1:1") + fvarint(3, 7)))
        yield out


class Handler(grpc.GenericRpcHandler):
    def service(self, hcd):
        m = hcd.method
        unary = {
            "/nix.remote.NixRemote/StoreInfo": store_info,
            "/nix.remote.NixRemote/QueryValidPaths": query_valid_paths,
            "/nix.remote.NixRemote/QueryMissing": query_missing,
        }
        if m in unary:
            return grpc.unary_unary_rpc_method_handler(unary[m])
        if m == "/nix.remote.NixRemote/AddMultipleToStore":
            return grpc.stream_unary_rpc_method_handler(add_multiple)
        if m == "/nix.remote.NixRemote/FetchNars":
            return grpc.unary_stream_rpc_method_handler(fetch_nars)
        if m == "/nix.remote.NixRemote/BuildDerivation":
            return grpc.unary_stream_rpc_method_handler(build_derivation)
        if m == "/nix.remote.Scheduler/Schedule":
            return grpc.stream_stream_rpc_method_handler(schedule)
        return None


def main():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=16))
    server.add_generic_rpc_handlers([Handler()])
    if len(sys.argv) > 2:
        # cert key [client-ca]: TLS, and a client certificate when a CA is named
        cert, key = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
        ca = open(sys.argv[3], "rb").read() if len(sys.argv) > 3 else None
        creds = grpc.ssl_server_credentials([(key, cert)], root_certificates=ca, require_client_auth=ca is not None)
        port = server.add_secure_port("127.0.0.1:0", creds)
    else:
        port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    print(port, flush=True)
    sys.stdin.read()
    server.stop(0)


main()
