import sys
import select
import socket
import re

def repl_send(host, port, payload, callback):
  buffer = ''
  s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  s.settimeout(8)
  try:
    s.connect((host, port))
    s.setblocking(1)
    s.sendall(payload)
    while True:
      while len(select.select([s], [], [], 0.1)[0]) == 0:
        callback()
      body = s.recv(8192)
      if re.search("=> $", body) != None:
        raise Exception("not an nREPL server: upgrade to Leiningen 2")
      buffer += body
      if re.search('6:statusl(5:error|14:session-closed)?4:done', body):
        break
    return buffer
  finally:
    s.close()

def noop():
  pass

def main(host, port, payload):
  try:
    sys.stdout.write(repl_send(host, int(port), payload, noop))
  except Exception, e:
    print(e)
    exit(1)

if __name__ == "__main__":
  main(*sys.argv[1:])
