"""Loopback TCP to mounted Unix socket. Works with Docker --network none."""
import os
import json
import select
import shutil
import socket
import socketserver
import subprocess
import sys
import threading

class Bridge(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as upstream:
            upstream.connect('/zap/wrk/gateway.sock')
            peers = [self.request, upstream]
            while True:
                readable, _, _ = select.select(peers, [], [], 30)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is self.request else self.request).sendall(data)

def write_status(stage, exit_code=None, error_type=None):
    status = {'stage': stage}
    if exit_code is not None:
        status['exitCode'] = exit_code
    if error_type is not None:
        status['errorType'] = error_type
    with open('/zap/wrk/scanner-status.json', 'w') as output:
        json.dump(status, output)


def main():
    server = None
    stage = 'initializing'
    try:
        write_status(stage)
        # Scanner UID matches host socket owner, rather than image user zap.
        home = '/zap/wrk/zap-home'
        os.makedirs(os.path.join(home, 'policies'), mode=0o700, exist_ok=True)
        shutil.copyfile('/home/zap/.ZAP/policies/API-Minimal.policy', os.path.join(home, 'policies', 'API-Minimal.policy'))
        # api-scan loads the bundled read-only HTTP sender scripts from their
        # official absolute /home/zap/.ZAP_D/scripts/scripts/httpsender paths.
        server = socketserver.ThreadingTCPServer(('127.0.0.1', 8090), Bridge)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        stage = 'scanner-running'
        write_status(stage)
        # -silent prevents api-scan's automatic add-on installs and updates.
        result = subprocess.run([
            'zap-api-scan.py', '-t', '/zap/wrk/openapi.json', '-f', 'openapi',
            '-J', 'raw.json', '-T', '10', '--hook', '/zap/wrk/scan_proof.py',
            '-z', '-silent -dir /zap/wrk/zap-home -config scanner.threadPerHost=1 -config scanner.maxScanDurationInMins=5 -config scanner.maxRuleDurationInMins=1 -config connection.timeoutInSecs=10',
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        stage = 'scanner-completed' if result.returncode in (0, 1, 2) else 'scanner-failed'
        write_status(stage, result.returncode)
        return result.returncode
    except subprocess.TimeoutExpired:
        write_status('scanner-timeout', 70, 'TimeoutExpired')
        return 70
    except Exception as error:
        safe_type = type(error).__name__ if isinstance(error, (FileNotFoundError, PermissionError, OSError)) else 'RuntimeError'
        write_status(stage, 71, safe_type)
        return 71
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    sys.exit(main())
