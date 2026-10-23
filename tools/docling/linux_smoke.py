"""Opt-in real Docker smoke: synthetic PDF only, no host mounts or published ports."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid


# Reuse the reviewed two-page text/table fixture; one-line pages can be
# merged by Docling and correctly require manual review.
from smoke import synthetic_pdf


HTTP = """import http.client,sys
b=sys.stdin.buffer.read(); c=http.client.HTTPConnection('127.0.0.1',8080,timeout=135)
c.request('POST' if b else 'GET','/parse' if b else '/ready',body=b or None,headers={'Content-Type':'application/pdf','Content-Length':str(len(b))} if b else {})
r=c.getresponse(); body=r.read(4194305); assert len(body)<=4194304
sys.stdout.buffer.write(str(r.status).encode()+b'\\n'+body); c.close()
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--docker', default='docker')
    parser.add_argument('--image', default='studiquo-docling:linux-validation')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    name = 'studiquo-linux-smoke-' + uuid.uuid4().hex[:12]
    def docker(*command, data=None, timeout=150):
        return subprocess.run([args.docker, *command], input=data, capture_output=True, timeout=timeout, check=True).stdout
    result = {'syntheticOnly': True, 'platform': 'linux/amd64', 'network': 'none', 'hostMounts': False, 'publishedPorts': False}
    attempted = False
    try:
        # A lost docker run response does not prove the named container absent.
        attempted = True
        docker('run','-d','--platform','linux/amd64','--name',name,'--network','none','--read-only',
               '--tmpfs','/tmp:rw,noexec,nosuid,size=256m','--cap-drop','ALL','--security-opt','no-new-privileges',
               '--memory','2g','--cpus','2','--pids-limit','128',args.image)
        end = time.monotonic() + 30
        while True:
            try:
                ready = docker('exec','-i',name,'/opt/docling-env/bin/python','-c',HTTP,data=b'',timeout=3)
                if ready == b'204\n': break
            except subprocess.SubprocessError: pass
            if time.monotonic() >= end: raise RuntimeError('linux_readiness_failed')
            time.sleep(0.2)
        pdf = synthetic_pdf(); start = time.monotonic()
        response = docker('exec','-i',name,'/opt/docling-env/bin/python','-c',HTTP,data=pdf)
        status, body = response.split(b'\n',1); assert status == b'200', 'linux_parse_failed'
        manifest = json.loads(body); pages = [p for b in manifest['batches'] for p in b['pages']]
        assert len(pages)==2 and [p['pageNumber'] for p in pages]==[1,2]
        assert all(b['structure']['document']['pdfSha256']==hashlib.sha256(pdf).hexdigest() for b in manifest['batches'])
        result.update(parseSeconds=round(time.monotonic()-start,3), pages=2, manifestBytes=len(body), parsePosts=1)
        checks = """import os,pathlib,socket,json,platform
assert platform.machine()=='x86_64' and os.getuid()==10001
assert not list(pathlib.Path('/tmp/studiquo-docling-jobs').iterdir())
for p in ['/app/forbidden','/opt/docling-models/forbidden']:
 try: pathlib.Path(p).write_text('synthetic'); raise AssertionError('writable code or model')
 except (PermissionError,OSError): pass
try: socket.create_connection(('1.1.1.1',443),1); raise AssertionError('egress enabled')
except OSError: pass
peak=pathlib.Path('/sys/fs/cgroup/memory.peak')
print(json.dumps({'uid':os.getuid(),'architecture':platform.machine(),'jobRootEmpty':True,'codeModelsReadOnly':True,'egressBlocked':True,'memoryPeakBytes':int(peak.read_text()) if peak.exists() else None}))
"""
        result.update(json.loads(docker('exec',name,'/opt/docling-env/bin/python','-c',checks)))
        invalid = docker('exec','-i',name,'/opt/docling-env/bin/python','-c',HTTP,data=b'%PDF-synthetic-invalid')
        assert invalid.split(b'\n',1)[0] in (b'400',b'500',b'503'), 'invalid_pdf_accepted'
        result['invalidPDFRejected'] = True
        docker('exec',name,'/opt/docling-env/bin/python','-c',"from pathlib import Path;assert not list(Path('/tmp/studiquo-docling-jobs').iterdir())")
        cancellation = """import sys,threading,json
from pathlib import Path
sys.path.insert(0,'/app/services/docling-processor')
import runner
b=sys.stdin.buffer.read();root=Path('/tmp/synthetic-stop-checks');root.mkdir(mode=0o700)
p=runner.PDFProcessor(python_executable='/opt/docling-env/bin/python',artifacts_directory='/opt/docling-models',temporary_root=root)
event=threading.Event();timer=threading.Timer(0.3,event.set);timer.start()
try:
 try:p.run_pdf(b,cancel_event=event);raise AssertionError('cancel accepted')
 except runner.ProcessorError as e:assert e.code=='cancelled'
finally:timer.cancel()
assert not list(root.iterdir())
# Shorten only this test process's deadline; serving remains fixed at 120s.
runner.DEADLINE_SECONDS=0.3
try:p.run_pdf(b);raise AssertionError('deadline accepted')
except runner.ProcessorError as e:assert e.code=='timeout'
assert not list(root.iterdir());root.rmdir()
print(json.dumps({'realChildCancelled':True,'shortenedDeadlineReaped':True,'stopJobDirectoriesRemoved':True}))
"""
        result.update(json.loads(docker('exec','-i',name,'/opt/docling-env/bin/python','-c',cancellation,data=pdf)))
        docker('stop','--time','10',name,timeout=20)
        state = json.loads(docker('inspect','--format','{{json .State}}',name))
        assert not state['Running'] and state['ExitCode']==0, 'sigterm_cleanup_failed'
        result.update(sigtermCleanExit=True, imageId=json.loads(docker('image','inspect',args.image))[0]['Id'])
    finally:
        if attempted:
            try: docker('rm','-f',name,timeout=20)
            except subprocess.CalledProcessError as error:
                if b'No such container:' not in error.stderr:
                    raise RuntimeError('linux_container_cleanup_unconfirmed') from None
    args.report.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
