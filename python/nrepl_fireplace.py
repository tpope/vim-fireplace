import os
import re
import select
import socket
import sys

try:
  from StringIO import StringIO
except ImportError:
  from io import StringIO

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
      if (0 <= ord(c) and ord(c) <= 31) or c == '"' or c == "\\":
        str_list.append("\\%03o" % ord(c))
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
    i = ''
    while True:
      char = f.read(1)
      if char == 'e':
        return int(i)
      i += char
  elif char.isdigit():
    i = int(char)
    while True:
      char = f.read(1)
      if char == ':':
        return f.read(i)
      i = 10 * i + int(char)
  elif char == '':
    raise EOFError("unexpected end of bencode data")
  else:
    raise TypeError("unexpected type "+char+"in bencode data")


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
    if sys.version_info[0] >= 3:
      self.socket.sendall(bytes(payload, 'UTF-8'))
    else:
      self.socket.sendall(payload)
    return ''

  def receive(self, char=None):
    f = self.socket.makefile()
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
    sys.stdout.write(vim_encode(dispatch(host, port, noop, keepalive, command, *[bdecode(StringIO(arg)) for arg in args])))
  except Exception:
    print((sys.exc_info()[1]))
    exit(1)

if __name__ == "__main__":
  main(*sys.argv[1:])
