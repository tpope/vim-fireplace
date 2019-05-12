import os
import select
import socket
import sys
import json

try:
    from StringIO import StringIO
except ImportError:
    from io import StringIO

def noop():
    pass

def binread(f, count=1):
    return f.read(count)

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

def decode_string(s):
    if s[0] in ['{', '[', '"']:
        return json.loads(s)
    elif s[0] in ['d', 'l', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9']:
        return bdecode(StringIO(s))
    else:
        raise TypeError("bad json/bencode argument " + s)

class Connection:
    def __init__(self, host, port, custom_poll=noop, keepalive_file=None):
        self.custom_poll = custom_poll
        self.keepalive_file = keepalive_file
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(8)
        s.connect((host, int(port)))
        s.setblocking(1)
        self.socket = s

    def poll(self):
        self.custom_poll()
        if self.keepalive_file and not os.path.exists(self.keepalive_file):
            sys.exit(0)

    def close(self):
        return self.socket.close()

    def send(self, payload):
        f = self.socket.makefile('w')
        try:
            f.write(payload)
        finally:
            f.close()
        return ''

    def receive(self, char=None):
        f = self.socket.makefile('rb', False)
        while len(select.select([f], [], [], 0.1)[0]) == 0:
            self.poll()
        try:
            return bdecode(f)
        finally:
            f.close()

    def call(self, payload, terminators, selectors):
        self.send(payload)
        responses = []
        while True:
            response = self.receive()
            for key in selectors:
                if response[key] != selectors[key]:
                    continue
            responses.append(response)
            if 'status' in response and set(terminators) & set(response['status']):
                return responses

def dispatch(host, port, poll, keepalive, command, *args):
    conn = Connection(host, port, poll, keepalive)
    try:
        return getattr(conn, command)(*args)
    finally:
        conn.close()

def main(host, port, keepalive, command, *args):
    try:
        result = dispatch(host, port, noop, keepalive, command, *[decode_string(arg) for arg in args])
        if result is not None:
            json.dump(result, sys.stdout)
    except Exception:
        print((sys.exc_info()[1]))
        exit(1)

if __name__ == "__main__":
    main(*sys.argv[1:])
