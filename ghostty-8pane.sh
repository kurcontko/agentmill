#!/bin/bash
# Launch 8 tmux panes each running Claude Code
# Usage: ./ghostty-8pane.sh [target-dir] [delay-seconds]
#   ./ghostty-8pane.sh ~/repos/my-project
#   ./ghostty-8pane.sh ~/repos/my-project 2

TARGET_DIR="${1:-$(pwd)}"
DELAY="${2:-1}"
SESSION="claude-8"

# Kill existing session if any
tmux kill-session -t "$SESSION" 2>/dev/null

# Create session
tmux new-session -s "$SESSION" -d -c "$TARGET_DIR"

# Create 2 rows
tmux split-window -v -t "$SESSION" -c "$TARGET_DIR"

# Split top row into 4 columns
tmux select-pane -t "$SESSION:0.0"
tmux split-window -h -t "$SESSION:0.0" -c "$TARGET_DIR"
tmux split-window -h -t "$SESSION:0.0" -c "$TARGET_DIR"
tmux split-window -h -t "$SESSION:0.2" -c "$TARGET_DIR"

# Split bottom row into 4 columns
tmux select-pane -t "$SESSION:0.4"
tmux split-window -h -t "$SESSION:0.4" -c "$TARGET_DIR"
tmux split-window -h -t "$SESSION:0.4" -c "$TARGET_DIR"
tmux split-window -h -t "$SESSION:0.6" -c "$TARGET_DIR"

# Launch claude in each pane with staggered delay
for i in $(seq 0 7); do
  SLEEP_TIME=$((i * DELAY))
  tmux send-keys -t "$SESSION:0.$i" "sleep $SLEEP_TIME && claude" Enter
done

tmux select-pane -t "$SESSION:0.0"
tmux attach-session -t "$SESSION"
