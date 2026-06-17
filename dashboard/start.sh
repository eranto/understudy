#!/bin/bash
# Launches the Understudy dashboard on http://127.0.0.1:8765/.
# Opens the browser automatically. Ctrl+C to stop.
#
# The queue root is read from QUEUE_ROOT if set; otherwise the dashboard assumes
# it lives inside the queue root (i.e. <queue-root>/dashboard/). See .env.example.
cd "$(dirname "$0")"
exec python3 server.py
