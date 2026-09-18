"""Exercise pinned real CLIs against loopback-only deterministic API responses.

Run inside the packaged image with --network none; no provider account is used.
The fixture asks each CLI to execute a real shell tool and return structured JSON.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

sys.path.insert(0, '/code')
from agentmill.adapters import get_adapter
from agentmill.contracts import ProcessOutput, REPLY_SCHEMA, SessionRequest

REPLY = {'status': 'done', 'summary': 'Wrote the fixture marker.', 'next_step': None, 'question': None}



class API(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    calls = 0
    backend = None

    def log_message(self, *args):
        pass

    def send_json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_json({'data':[],'models':[]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path.endswith('/count_tokens'):
            self.send_json({'input_tokens':10})
            return
        if '/messages' in self.path:
            self.claude(body)
        elif self.path.endswith('/responses'):
            self.codex(body)
        else:
            self.send_json({})

    def claude(self, body):
        tools = {t['name']:t for t in body.get('tools',[])}
        count = type(self).calls
        type(self).calls += 1
        if count == 0:
            content = [{'type':'tool_use','id':'tool_fixture_bash','name':'Bash',
                        'input':{'command':'printf native > proof.txt','description':'Write fixture marker'}}]
            stop = 'tool_use'
        elif count == 1 and 'StructuredOutput' in tools:
            content = [{'type':'tool_use','id':'tool_fixture_schema','name':'StructuredOutput','input':REPLY}]
            stop = 'tool_use'
        else:
            content = [{'type':'text','text':json.dumps(REPLY)}]
            stop = 'end_turn'
        response = {'id':f'msg_{count}','type':'message','role':'assistant','model':body.get('model','fixture'),
                    'content':content,'stop_reason':stop,'stop_sequence':None,
                    'usage':{'input_tokens':10,'output_tokens':10}}
        if not body.get('stream'):
            self.send_json(response)
            return
        events = [('message_start', {'type':'message_start','message':{**response,'content':[],'stop_reason':None}})]
        for index, block in enumerate(content):
            start = {**block, 'input':{}} if block['type']=='tool_use' else {**block,'text':''}
            events.append(('content_block_start',{'type':'content_block_start','index':index,'content_block':start}))
            delta = {'type':'input_json_delta','partial_json':json.dumps(block['input'])} if block['type']=='tool_use' else {'type':'text_delta','text':block['text']}
            events.append(('content_block_delta',{'type':'content_block_delta','index':index,'delta':delta}))
            events.append(('content_block_stop',{'type':'content_block_stop','index':index}))
        events += [('message_delta',{'type':'message_delta','delta':{'stop_reason':stop,'stop_sequence':None},'usage':{'output_tokens':10}}),
                   ('message_stop',{'type':'message_stop'})]
        self.sse(events)

    def codex(self, body):
        count = type(self).calls
        type(self).calls += 1
        if count == 0:
            names = {t.get('name') for t in body.get('tools',[])}
            name = next((n for n in ('exec_command','shell_command','shell') if n in names), None)
            if name is None:
                raise AssertionError(f'No native shell tool in {names}')
            args = {'cmd':'printf native > proof.txt'} if name=='exec_command' else {'command':'printf native > proof.txt'}
            if name=='shell':
                args['command']=['bash','-lc','printf native > proof.txt']
            item = {'type':'function_call','id':'fc_fixture','call_id':'call_fixture','name':name,'arguments':json.dumps(args)}
        else:
            item = {'type':'message','id':'msg_fixture','role':'assistant','status':'completed',
                    'content':[{'type':'output_text','text':json.dumps(REPLY),'annotations':[]}]}
        self.sse([
            ('response.created',{'type':'response.created','response':{'id':f'resp_{count}'}}),
            ('response.output_item.done',{'type':'response.output_item.done','output_index':0,'item':item}),
            ('response.completed',{'type':'response.completed','response':{'id':f'resp_{count}',
                'status':'completed','output':[item], 'usage':{'input_tokens':10,'output_tokens':10,'total_tokens':20}}}),
        ])

    def sse(self, events):
        data = ''.join(f'event: {name}\ndata: {json.dumps(event)}\n\n' for name,event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type','text/event-stream')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    server = ThreadingHTTPServer(('127.0.0.1',0), API)
    thread = threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{server.server_port}'
    root = Path('/home/agentmill/native-smoke')
    root.mkdir(parents=True)
    Path('/inputs/reply.schema.json').write_text(json.dumps(REPLY_SCHEMA))
    for backend in ('codex','claude'):
        API.calls = 0
        home = root / backend
        home.mkdir()
        env = {**os.environ,'HOME':str(home),'CODEX_HOME':str(home / '.codex'),
               'ANTHROPIC_BASE_URL':base,'ANTHROPIC_API_KEY':'fixture-only','CODEX_API_KEY':'fixture-only',
               'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1'}
        if backend=='codex':
            (home / '.codex').mkdir()
            (home / '.codex/config.toml').write_text(
                'model="fixture"\nmodel_provider="fixture"\n'
                '[model_providers.fixture]\nname="Fixture"\n'
                f'base_url="{base}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n')
        adapter = get_adapter(backend)
        argv = list(adapter.build_command(SessionRequest()).argv)
        subprocess.run(['git','init','-q','/workspace'],check=True)
        proof = Path('/workspace/proof.txt')
        proof.unlink(missing_ok=True)
        result = subprocess.run(argv,input='Use Bash to write native to proof.txt, then return the structured reply.',
                                cwd='/workspace',env=env,capture_output=True,text=True,timeout=60)
        if result.returncode:
            print(f'{backend} exit {result.returncode}:\n{result.stdout}\n{result.stderr}',flush=True)
        output_dir = Path(os.environ.get('FIXTURE_OUTPUT_DIR', str(root)))
        native = output_dir / f'{backend}-success.jsonl'
        native.write_text(result.stdout)
        error_log = root / f'{backend}.stderr.log'
        error_log.write_text(result.stderr)
        reply, telemetry = adapter.parse_result(ProcessOutput(result.returncode, native, error_log, 0))
        assert reply.status == 'done'
        assert telemetry['usage'] is not None
        assert result.returncode==0, backend
        assert proof.read_text()=='native', backend
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        if backend=='claude':
            assert events[-1]['type']=='result' and events[-1]['subtype']=='success'
            assert events[-1]['structured_output']==REPLY
        else:
            assert events[-1]['type']=='turn.completed'
            assert json.loads(Path('/scratch/reply.json').read_text())==REPLY
        print(f'PASS real {backend}: shell tool, structured terminal reply, isolated permissions',flush=True)
    server.shutdown()


if __name__=='__main__':
    main()
