import json
import os
import re
import socket
import sys
import traceback
import threading

def bencode(data, f):
    if isinstance(data, list):
        f.write(b'l')
        for x in data:
            bencode(x, f)
        f.write(b'e')
    elif isinstance(data, dict):
        f.write(b'd')
        for x in sorted(data.keys()):
            bencode(x, f)
            bencode(data[x], f)
        f.write(b'e')
    elif isinstance(data, int) or isinstance(data, bool):
        f.write(b'i')
        f.write(str(int(data)).encode('UTF-8'))
        f.write(b'e')
    elif isinstance(data, str) or type(data).__name__ == 'unicode':
        data = data.encode('UTF-8')
        f.write(str(len(data)).encode('UTF-8'))
        f.write(b':')
        f.write(data)
    else:
        raise TypeError("can't bencode a " + type(data).__name__)

def binread(f, count=1):
    buf = f.read(count)
    length = len(buf)
    while len(buf) != count and length > 0:
        more = f.read(count - len(buf))
        length = len(more)
        buf += more
    return buf

def bdecode(f, char=None):
    if char == None:
        char = binread(f)
    if char == b'l':
        l = []
        while True:
            char = binread(f)
            if char == b'e':
                return l
            l.append(bdecode(f, char))
    elif char == b'd':
        d = {}
        while True:
            char = binread(f)
            if char == b'e':
                return d
            key = bdecode(f, char)
            d[key] = bdecode(f)
    elif char == b'i':
        i = b''
        while True:
            char = binread(f)
            if char == b'e':
                return int(i)
            i += char
    elif char.isdigit():
        i = int(char)
        while True:
            char = binread(f)
            if char == b':':
                return binread(f, i).decode('UTF-8')
            i = 10 * i + int(char)
    elif char == b'':
        raise EOFError("unexpected end of bencode data")
    else:
        raise TypeError("unexpected type "+char.decode('UTF-8')+" in bencode data")

def quickfix(t, e, tb):
    items = []
    stack = traceback.extract_tb(tb)
    for frame in stack:
        (filename, lineno, name, line) = frame
        module = ''
        if filename and filename[0] == '<':
            module = filename
            filename = ''
        items.append({
            'filename': filename,
            'lnum': lineno,
            'module': module,
            'text': line})
    return {'title': str(e), 'items': items}

class Connection:
    def __init__(self, host, port, keepalive_file=None):
        self.keepalive_file = keepalive_file
        self.connected = False
        self.host = host
        self.port = int(port)

    def socket(self):
        if not self.connected:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(8)
            s.connect((self.host, self.port))
            s.setblocking(1)
            self._socket = s
            self.connected = True
        return self._socket

    def close(self):
        if self.connected:
            return self.socket().close()

    def send(self, payload):
        f = self.socket().makefile('wb')
        try:
            if isinstance(payload, dict):
                bencode(payload, f)
            else:
                f.write(payload.encode('UTF-8'))
        finally:
            f.close()
        return ''

    def receive(self, char=None):
        f = self.socket().makefile('rb', False)
        try:
            return bdecode(f)
        finally:
            f.close()

    def notify(self, data, i = 0):
        json.dump([i, data], sys.stdout)
        sys.stdout.write("\n")
        sys.stdout.flush()

    def tunnel_socket_to_stdout(self):
        socket_in = self.socket().makefile('rb', False)
        try:
            while True:
                msg = self.receive()
                self.notify(msg)
        except EOFError:
            os._exit(0)
        except Exception:
            self.notify(["exception", quickfix(*sys.exc_info())])
            os._exit(4)
        finally:
            socket_in.close()

    def tunnel(self):
        try:
            self.socket()
            t = threading.Thread(target = self.tunnel_socket_to_stdout)
            t.daemon = True
            t.start()
            self.notify(["status", ""])
            line = sys.stdin.readline()
            while len(line) > 0:
                try:
                    obj = json.loads(line)
                    if isinstance(obj, list):
                        obj = obj[1]
                    self.send(obj)
                except Exception:
                    self.notify(["exception", quickfix(*sys.exc_info())])
                line = sys.stdin.readline()
            t.join(0.1)
        except socket.error as e:
            self.notify(["status", e.strerror])
            os._exit(2)
        except Exception as e:
            self.notify(["status", str(e)])
            self.notify(["exception", quickfix(*sys.exc_info())])
            os._exit(3)

def main(host = None, port = None, *args):
    try:
        match = re.search('//([^:/@]+)(?::(\d+))?', host)
        if match:
            host = match.groups()[0]
            port = match.groups()[1]
        conn = Connection(host, int(port or 7888))
        try:
            conn.tunnel()
        finally:
            conn.close()
    except Exception:
        json.dump([0, ["exception", quickfix(*sys.exc_info())]], sys.stdout)
        exit(1)

if __name__ == "__main__":
    main(*sys.argv[1:])
