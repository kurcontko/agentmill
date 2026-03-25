#!/usr/bin/env bash
# setup-opencode-config.sh — Generate opencode.json for autonomous agent mode
#
# Reads env vars and generates project-level opencode.json with:
#   - Custom openai-compatible provider when LOCAL_ENDPOINT is set
#   - Permissive permissions for autonomous operation
#   - MCP server config (if host config available)

set -euo pipefail

CONFIG_FILE="${1:-.}/opencode.json"

# Build config using Python (stdlib json, no deps)
python3 -c "
import json, os, sys

config = {}

# Model
model = os.environ.get('MODEL', '')
if model:
    config['model'] = model

# Permissions — allow everything for autonomous operation
config['permission'] = {
    'bash': 'allow',
    'edit': 'allow',
    'read': 'allow',
    'write': 'allow',
    'glob': 'allow',
    'grep': 'allow',
    'list': 'allow',
    'webfetch': 'allow',
    'websearch': 'allow',
    'task': 'allow',
    'question': 'deny',
    'plan_enter': 'deny',
    'plan_exit': 'deny',
}

# Custom provider for local models (vLLM, llama.cpp, etc.)
local_endpoint = os.environ.get('LOCAL_ENDPOINT', '')
local_api_key = os.environ.get('LOCAL_API_KEY', 'dummy')
if local_endpoint:
    config['provider'] = {
        'openai-compatible': {
            'api': local_endpoint,
            'npm': '@ai-sdk/openai-compatible',
            'options': {
                'baseURL': local_endpoint,
                'apiKey': local_api_key,
                'timeout': 600000,
            },
        }
    }

# MCP servers — port from host Claude config if available
host_config = os.environ.get('HOST_CLAUDE_CONFIG', '/home/agent/.host-claude.json')
if os.path.isfile(host_config):
    try:
        with open(host_config) as f:
            host = json.load(f)
        mcp_servers = host.get('mcpServers', {})
        if mcp_servers:
            config['mcp'] = {}
            for name, srv in mcp_servers.items():
                entry = {'type': 'local'}
                if 'command' in srv:
                    cmd = srv['command']
                    args = srv.get('args', [])
                    entry['command'] = [cmd] + args
                if 'env' in srv:
                    entry['environment'] = srv['env']
                config['mcp'][name] = entry
    except (json.JSONDecodeError, KeyError):
        pass

# Merge extra config from env (escape hatch)
extra = os.environ.get('OPENCODE_EXTRA_CONFIG', '')
if extra:
    try:
        config.update(json.loads(extra))
    except json.JSONDecodeError:
        print(f'WARNING: OPENCODE_EXTRA_CONFIG is not valid JSON, ignoring', file=sys.stderr)

json.dump(config, sys.stdout, indent=2)
print()
" > "$CONFIG_FILE"

echo "[setup-opencode] Config written to $CONFIG_FILE"
