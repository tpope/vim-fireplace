import sys
import select
import socket
import re

def noop():
  pass

def vim_encode(data):
  if isinstance(data, list):
    return "[" + ",".join([vim_encode(x) for x in data]) + "]"
  elif isinstance(data, dict):
    return "{" + ",".join([vim_encode(x)+":"+vim_encode(y) for x,y in data.items()]) + "}"
  elif isinstance(data, str):
    str_list = []
    for c in data:
      if (000 <= ord(c) and ord(c) <= 037) or c == '"' or c == "\\":
        str_list.append("\\{0:03o}".format(ord(c)))
      else:
        str_list.append(c)
    return '"' + ''.join(str_list) + '"'
  elif isinstance(data, int):
    return str(data)
  else:
    raise TypeError("can't encode a " + type(data).__name__)

def bdecode(f, char=None):
    if char == None:
      char = f.read(1)
    if char == 'l':
      l = []
      while True:
        char = f.read(1)
        if char == 'e':
          return l
        l.append(bdecode(f, char))
    elif char == 'd':
      d = {}
      while True:
        char = f.read(1)
        if char == 'e':
          return d
        key = bdecode(f, char)
        d[key] = bdecode(f)
    elif char == 'i':
      i = 0
      while True:
        char = f.read(1)
        if char == 'e':
          return i
        i = 10 * i + int(char)
    else:
      i = int(char)
      while True:
        char = f.read(1)
        if char == ':':
          return f.read(i)
        i = 10 * i + int(char)


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
      exit(0)

  def close(self):
    return self.socket.close()

  def send(self, payload):
    self.socket.sendall(payload)
    return ''

  def receive(self, char=None):
    while len(select.select([self.socket], [], [], 0.1)[0]) == 0:
      self.poll()
    f = self.socket.makefile()
    try:
      return bdecode(f)
    finally:
      f.close()

  def call(self, payload):
    self.send(payload)
    responses = []
    while True:
      responses.append(self.receive())
      if 'status' in responses[-1] and 'done' in responses[-1]['status']:
        return responses

def dispatch(host, port, poll, keepalive, command, *args):
  conn = Connection(host, port, poll, keepalive)
  try:
    return getattr(conn, command)(*args)
  finally:
    conn.close()

def main(host, port, keepalive, command, *args):
  try:
    sys.stdout.write(vim_encode(dispatch(host, port, noop, keepalive, command, *args)))
  except Exception, e:
    print(e)
    exit(1)

if __name__ == "__main__":
  main(*sys.argv[1:])
