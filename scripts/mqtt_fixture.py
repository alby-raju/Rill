"""Small independently authored MQTT 3.1.1/5 loopback broker fixture, not a production broker."""

import socketserver
import struct


def variable(value):
    result = bytearray()
    while True:
        next_byte = value % 128
        value //= 128
        result.append(next_byte | (128 if value else 0))
        if not value:
            return bytes(result)


def packet(header, body=b""):
    return bytes([header]) + variable(len(body)) + body


def text(value):
    value = value.encode()
    return struct.pack("!H", len(value)) + value


class Reader:
    def __init__(self, data):
        self.data = data
        self.position = 0

    def take(self, count):
        result = self.data[self.position : self.position + count]
        if len(result) != count:
            raise ValueError("Truncated")
        self.position += count
        return result

    def byte(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("!H", self.take(2))[0]

    def string(self):
        return self.take(self.u16()).decode()

    def variable(self):
        result = 0
        for index in range(4):
            byte = self.byte()
            result += (byte & 127) << (7 * index)
            if not byte & 128:
                return result
        raise ValueError("Invalid length")

    def rest(self):
        return self.take(len(self.data) - self.position)


def session(read, write):
    subscriptions = []
    incoming_qos2 = {}
    version = None
    outbound = {}
    count = 100
    for _ in range(1000):
        header = read(1)[0]
        length = 0
        for index in range(4):
            byte = read(1)[0]
            length += (byte & 127) << (7 * index)
            if not byte & 128:
                break
        else:
            raise ValueError("Length")
        if length > 1024 * 1024 + 16384:
            raise ValueError("Oversize")
        reader = Reader(read(length))
        kind = header >> 4
        if kind == 1:
            if reader.string() != "MQTT":
                raise ValueError("Protocol")
            version = reader.byte()
            flags = reader.byte()
            reader.u16()
            if version == 5:
                reader.take(reader.variable())
            client = reader.string()
            if flags & 128:
                reader.string()
            if flags & 64:
                reader.take(reader.u16())
            if client == "stall":
                continue
            reason = (
                0x87 if client == "reject" and version == 5 else (5 if client == "reject" else 0)
            )
            write(packet(0x20, bytes([0, reason]) + (b"\0" if version == 5 else b"")))
        elif kind == 8:
            identifier = reader.take(2)
            if version == 5:
                reader.take(reader.variable())
            topic = reader.string()
            qos = reader.byte()
            subscriptions.append((topic, qos))
            write(
                packet(
                    0x90,
                    identifier
                    + (b"\0" if version == 5 else b"")
                    + bytes([0x80 if topic == "reject/#" else qos]),
                )
            )
        elif kind == 3:
            topic = reader.string()
            qos = (header >> 1) & 3
            identifier = reader.take(2) if qos else None
            properties = reader.take(reader.variable()) if version == 5 else b""
            body = reader.rest()

            def deliver(
                topic=topic, qos=qos, body=body, properties=properties, retained=header & 1
            ):
                nonlocal count
                if not subscriptions:
                    return
                count += 1
                identifier = struct.pack("!H", count)
                outbound[identifier] = qos
                # Preserve format/content-type metadata and retain flag in fixture echo.
                write(
                    packet(
                        0x30 | (qos << 1) | retained,
                        text(topic)
                        + (identifier if qos else b"")
                        + (variable(len(properties)) + properties if version == 5 else b"")
                        + body,
                    )
                )

            if qos == 2:
                incoming_qos2[identifier] = deliver
                write(packet(0x50, identifier))
            else:
                if qos:
                    write(packet(0x40, identifier))
                deliver()
        elif kind == 6:
            identifier = reader.take(2)
            action = incoming_qos2.pop(identifier, None)
            write(packet(0x70, identifier))
            if action:
                action()
        elif kind == 5:
            write(packet(0x62, reader.take(2)))
        elif kind in (4, 7):
            outbound.pop(reader.take(2), None)
        elif kind == 12:
            write(packet(0xD0))
        elif kind == 14:
            return
        else:
            raise ValueError("Unexpected packet")


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)

        def read(count):
            data = self.rfile.read(count)
            if len(data) != count:
                raise EOFError()
            return data

        try:
            session(read, self.connection.sendall)
        except (OSError, ValueError, EOFError, IndexError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    Server(("127.0.0.1", 18756), Handler).serve_forever()
