"""Native envelope acceptance and rejection, independent of the runner."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from agentmill.adapters import get_adapter
from agentmill.contracts import AgentReply, ProcessOutput, RunSpec, RunStopped, SessionRequest

REPLY = {'status':'done','summary':'Finished','next_step':None,'question':None}


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def output(self, events, code=0):
        path = self.root / 'native.jsonl'
        path.write_text('\n'.join(json.dumps(e) for e in events))
        return ProcessOutput(code,path,self.root / 'stderr.log',1)

    def valid(self, backend):
        if backend=='claude':
            return [{'type':'system','subtype':'init'}, {'type':'result','subtype':'success','is_error':False,'structured_output':REPLY}]
        return [{'type':'thread.started','thread_id':'fixture'}, {'type':'turn.started'},
                {'type':'item.completed','item':{'type':'agent_message','text':json.dumps(REPLY)}},
                {'type':'turn.completed','usage':{'input_tokens':20,'output_tokens':10}}]

    def test_valid_terminal_and_unknown_usage(self):
        for backend in ('codex','claude'):
            reply, telemetry = get_adapter(backend).parse_result(self.output(self.valid(backend)))
            self.assertEqual(reply, AgentReply(**REPLY))
            self.assertIsNone(telemetry['cost_usd_estimate'])
            self.assertTrue(telemetry['source'].startswith(backend+'.'))

    def test_deeply_nested_native_json_is_a_protocol_failure(self):
        nested = '[' * 2000 + '0' + ']' * 2000
        output = self.output([])
        output.stdout.write_text(nested)
        for backend in ('codex', 'claude'):
            with self.subTest(backend=backend), self.assertRaisesRegex(RunStopped, 'invalid_native_output'):
                get_adapter(backend).parse_result(output)
        events = self.valid('codex')
        events[-2]['item']['text'] = nested
        with self.assertRaisesRegex(RunStopped, 'invalid_agent_reply'):
            get_adapter('codex').parse_result(self.output(events))

        # Some Python versions decode deeply nested JSON without recursion. Also
        # exercise the decoder's RecursionError explicitly on those runtimes.
        decode = json.loads
        def recursion_limit(text):
            if text == nested:
                raise RecursionError('decoder nesting limit')
            return decode(text)
        with patch('agentmill.adapters.json.loads', recursion_limit):
            output.stdout.write_text(nested)
            for backend in ('codex', 'claude'):
                with self.assertRaisesRegex(RunStopped, 'invalid_native_output'):
                    get_adapter(backend).parse_result(output)
            with self.assertRaisesRegex(RunStopped, 'invalid_agent_reply'):
                get_adapter('codex').parse_result(self.output(events))

    def test_real_packaged_native_terminal_fixtures(self):
        for backend in ('codex','claude'):
            path = Path(__file__).parent / 'fixtures' / f'{backend}-success.jsonl'
            reply, telemetry = get_adapter(backend).parse_result(ProcessOutput(0,path,self.root/'stderr',0))
            self.assertEqual(reply.status,'done')
            self.assertEqual(reply.summary,'Wrote the fixture marker.')
            self.assertGreater(telemetry['usage']['output_tokens'],0)

    def test_both_adapters_reject_missing_duplicate_or_trailing_terminal_and_bad_exit(self):
        for backend in ('codex','claude'):
            good = self.valid(backend)
            for events, code in (([],0), (good[:-1],0), (good+[good[-1]],0), (good+[{'type':'extra'}],0),
                                 (good,1), ([None],0), (['done'],0)):
                with self.subTest(backend=backend, events=events, code=code):
                    with self.assertRaises(RunStopped):
                        get_adapter(backend).parse_result(self.output(events,code))

    def test_codex_rejects_failed_turn_and_missing_start_or_reply(self):
        adapter = get_adapter('codex')
        for events in ([{'type':'error'}], [{'type':'turn.failed'}],
                       [{'type':'turn.completed'}], [{'type':'turn.started'}, {'type':'turn.completed'}],
                       [{'type':'turn.started'}, {'type':'turn.started'}]):
            with self.assertRaises(RunStopped):
                adapter.parse_result(self.output(events))

    def test_claude_rejects_error_envelope_despite_done_payload(self):
        for change in ({'is_error':True}, {'is_error':'false'}, {'subtype':'error_max_turns'}, {'structured_output':'done'}):
            events = self.valid('claude')
            events[-1].update(change)
            with self.assertRaises(RunStopped):
                get_adapter('claude').parse_result(self.output(events))

    def test_reply_types_and_keys_are_strict(self):
        for reply in (None, {}, {**REPLY,'status':True}, {**REPLY,'summary':None},
                      {**REPLY,'next_step':False}, {**REPLY,'question':5}, {**REPLY,'extra':1}):
            with self.assertRaises(RunStopped):
                AgentReply.parse(reply)

    def test_commands_use_native_stdin_and_explicit_container_permissions(self):
        codex = get_adapter('codex').build_command(SessionRequest('chosen-model','profile',True))
        self.assertEqual(codex.argv[0:2], ('codex','exec'))
        self.assertEqual(codex.argv[-1], '-')
        self.assertNotIn('--output-last-message', codex.argv)
        self.assertIn('danger-full-access',codex.argv)
        self.assertIn('profile',codex.argv)
        self.assertIn('chosen-model',codex.argv)
        claude = get_adapter('claude').build_command(SessionRequest('chosen-model',None,True))
        self.assertIn('dontAsk',claude.argv)
        self.assertIn('--strict-mcp-config',claude.argv)
        self.assertNotIn('--mcp-config',claude.argv)
        self.assertIn('/native/config',claude.argv)
        for command in (codex,claude):
            self.assertEqual(command.stdin,'/inputs/prompt.txt')
            self.assertNotIn('--resume',command.argv)

    def test_spec_rejects_unbounded_or_ambiguous_inputs(self):
        base = dict(source='/repo',task='task',checks=['true'])
        for values in ({'agent':'unknown'}, {'checks':[]}, {'checks':'true'}, {'task':''},
                       {'max_sessions':True}, {'max_duration':float('inf')}, {'check_timeout':0},
                       {'credential_env':['TOKEN=value']}, {'credential_env':['PATH']},
                       {'profile':'../escape'}, {'agent':'claude','auth_file':'auth.json'},
                       {'profile':'review'}, {'model':7}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                RunSpec(**{**base,**values})
        spec = RunSpec(**{**base,'credential_env':['TOKEN','TOKEN']})
        self.assertEqual(spec.credential_env,('TOKEN',))
        self.assertEqual(spec.checks,('true',))


if __name__=='__main__':
    unittest.main()
