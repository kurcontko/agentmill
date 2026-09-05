#!/bin/bash
# Unprivileged adapter. The supervisor fixes the helper executable, uid, and
# clean environment; the client never gains privileges itself.
exec /usr/bin/python3 -I /usr/local/bin/reviewer-rpc exec "$@"
