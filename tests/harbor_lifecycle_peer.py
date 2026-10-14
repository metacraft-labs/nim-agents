"""Controlled real HTTP peer for deterministic library concurrency barriers."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import sys
import time
root = Path(sys.argv[1])
class Peer(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/api/v1/sessions': self.reply({'session_id':'live'})
        elif self.path.endswith('/prompt'):
            with (root/'deliveries').open('a') as out: out.write('prompt\n')
            (root/'admitted').touch()
            deadline = time.monotonic()+10
            while not (root/'release-admission').exists():
                if time.monotonic()>deadline: raise TimeoutError('admission barrier')
                time.sleep(.002)
            self.reply({'accepted':True})
        elif self.path.endswith('/stop'):
            (root/'stopped').touch()
            self.reply({})
    def do_GET(self):
        if '/events/history' in self.path:
            self.reply({'events':[], 'total_count':0}); return
        if (root/'admitted').exists():
            (root/'streaming').touch()
            deadline = time.monotonic()+10
            while not (root/'release').exists():
                if time.monotonic()>deadline: raise TimeoutError('stream barrier')
                time.sleep(.002)
        terminal = (root/'terminal').read_text() if (root/'admitted').exists() else 'paused'
        data = ''.join('data: '+json.dumps({'type':'status','status':s})+'\n\n'
                       for s in ['running',terminal]).encode()
        self.send_response(200)
        self.send_header('Content-Type','text/event-stream')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers(); self.wfile.write(data)
server = ThreadingHTTPServer(('127.0.0.1',0),Peer)
print(server.server_port,flush=True)
server.serve_forever()
