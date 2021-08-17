import sys
import random
import argparse

from http.server import HTTPServer, BaseHTTPRequestHandler

parser = argparse.ArgumentParser(description='Demo app for rollouts.')
parser.add_argument('-p', '--port', dest='port',
                    type=int, default=8080,
                    help='port to listen')
parser.add_argument('-c', '--color', dest='color',
                    type=str, default="green",
                    help='color sending as response')
parser.add_argument('-e', '--error', dest='error',
                    type=int, default=0,
                    help='error rate, min 0, max 100')
parser.add_argument('--error-code', dest='error_code',
                    type=int, default=500,
                    help='error code')
cfg = parser.parse_args()

class MyHandler(BaseHTTPRequestHandler):
    def send_result(self, code, message):
        self.send_response(code)
        self.send_header("Content-type", "text/plain")
        self.end_headers()
        self.wfile.write(message.encode("utf8"))
    def do_GET(self):
        if random.randint(1, 100) > cfg.error:
            self.send_result(200, cfg.color + "\n")
        else:
            self.send_result(cfg.error_code, "ERROR\n")

HTTPServer(('', cfg.port), MyHandler).serve_forever()
