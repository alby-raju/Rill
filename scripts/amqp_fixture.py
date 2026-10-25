"""Independently authored AMQP 0-9-1 existing-queue loopback fixture."""
import socketserver
import struct

def u16(value): return struct.pack('!H', value)
def u32(value): return struct.pack('!I', value)
def u64(value): return struct.pack('!Q', value)
def short(value):
    data = value.encode(); return bytes([len(data)]) + data

def frame(kind, channel, data=b''): return bytes([kind]) + u16(channel) + u32(len(data)) + data + b'\xce'
def method(group, identifier, channel=0, data=b''): return frame(1, channel, u16(group) + u16(identifier) + data)
class Reader:
    def __init__(self, data): self.data = data; self.offset = 0
    def take(self, count):
        data = self.data[self.offset:self.offset+count]; self.offset += count
        if len(data) != count: raise ValueError('Truncated')
        return data
    def byte(self): return self.take(1)[0]
    def u16(self): return struct.unpack('!H', self.take(2))[0]
    def u32(self): return struct.unpack('!I', self.take(4))[0]
    def u64(self): return struct.unpack('!Q', self.take(8))[0]
    def short(self): return self.take(self.byte()).decode()

class Handler(socketserver.StreamRequestHandler):
    def exact(self, count):
        data = self.rfile.read(count)
        if len(data) != count: raise EOFError()
        return data
    def send(self, data):
        # Split every frame header across writes to exercise incremental decoding.
        self.connection.sendall(data[:3]); self.connection.sendall(data[3:])
    def handle(self):
        self.connection.settimeout(5)
        try: self.session()
        except (OSError, ValueError, EOFError): pass
    def session(self):
        if self.exact(8) != b'AMQP\x00\x00\x09\x01': return
        self.send(method(10, 10, data=b'\x00\x09' + u32(0) + u32(5) + b'PLAIN' + u32(5) + b'en_US'))
        sequence = 0; delivery = 0; consumer = None; publication = None
        for _ in range(1000):
            kind = self.exact(1)[0]; channel = struct.unpack('!H', self.exact(2))[0]; length = struct.unpack('!I', self.exact(4))[0]
            if length > 65528: raise ValueError('Frame limit')
            cursor = Reader(self.exact(length))
            if self.exact(1) != b'\xce': raise ValueError('End marker')
            if kind == 8: self.send(frame(8, 0)); continue
            if kind == 1:
                group, identifier = cursor.u16(), cursor.u16()
                if (group, identifier) == (10, 11):
                    cursor.take(cursor.u32()); mechanism = cursor.short(); credentials = cursor.take(cursor.u32())
                    if b'reject' in credentials:
                        self.send(method(10, 50, data=u16(403)+short('Rejected')+u16(0)+u16(0))); return
                    if mechanism != 'PLAIN': raise ValueError('Auth')
                    self.send(method(10, 30, data=u16(1)+u32(65536)+u16(30)))
                elif (group, identifier) == (10, 31): pass
                elif (group, identifier) == (10, 40): self.send(method(10, 41, data=short('')))
                elif (group, identifier) == (20, 10): self.send(method(20, 11, channel, u32(0)))
                elif (group, identifier) == (60, 10): self.send(method(60, 11, channel))
                elif (group, identifier) == (85, 10): self.send(method(85, 11, channel))
                elif (group, identifier) == (60, 20):
                    cursor.u16(); queue = cursor.short()
                    if queue != 'existing': self.send(method(20, 40, channel, u16(404)+short('No queue')+u16(60)+u16(20))); return
                    consumer = 'rill-fixture'; self.send(method(60, 21, channel, short(consumer)))
                elif (group, identifier) == (60, 40):
                    cursor.u16(); exchange = cursor.short(); queue = cursor.short(); cursor.byte()
                    if exchange: raise ValueError('Default exchange only')
                    sequence += 1; publication = {'queue':queue, 'body':bytearray(), 'sequence':sequence, 'size':None, 'header':None}
                elif (group, identifier) == (60, 80): pass
                else: raise ValueError('Unexpected method')
            elif kind == 2:
                if publication is None: raise ValueError('Unexpected header')
                publication['header'] = cursor.data
                if cursor.u16() != 60 or cursor.u16() != 0: raise ValueError('Header')
                publication['size'] = cursor.u64()
                if publication['size'] > 1024*1024: raise ValueError('Body limit')
            elif kind == 3:
                if publication is None or publication['size'] is None: raise ValueError('Unexpected body')
                publication['body'].extend(cursor.data)
            else: raise ValueError('Frame kind')
            if publication is not None and publication['size'] is not None and len(publication['body']) == publication['size']:
                if publication['queue'] != 'existing':
                    self.send(method(60, 50, 1, u16(312)+short('No route')+short('')+short(publication['queue'])))
                    self.send(frame(2, 1, publication['header']))
                    for offset in range(0, len(publication['body']), 4096): self.send(frame(3, 1, publication['body'][offset:offset+4096]))
                elif consumer:
                    delivery += 1
                    self.send(method(60, 60, 1, short(consumer)+u64(delivery)+b'\0'+short('')+short('existing')))
                    self.send(frame(2, 1, publication['header']))
                    for offset in range(0, len(publication['body']), 4096): self.send(frame(3, 1, publication['body'][offset:offset+4096]))
                self.send(method(60, 80, 1, u64(publication['sequence'])+b'\0'))
                publication = None
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
if __name__ == '__main__': Server(('127.0.0.1', 18757), Handler).serve_forever()
