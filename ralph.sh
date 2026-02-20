#!/bin/bash

# Ralph Loop - Iterative task runner for pi
# Runs pi in a loop, picking one task at a time from individual task files
# Use ralph_prepare.sh first to generate tasks from a work document

set -euo pipefail

RALPH_DIR=".ralph"
TASKS_DIR="$RALPH_DIR/tasks"
COMPLETE_DIR="$RALPH_DIR/complete"
SESSIONS_DIR="$RALPH_DIR/sessions"
mkdir -p "$TASKS_DIR" "$COMPLETE_DIR" "$SESSIONS_DIR"

# Ensure there are tasks to work on
if ! ls "$TASKS_DIR"/*.md &>/dev/null; then
    echo "No task files found in $TASKS_DIR/. Provide a work document or add task files manually." >&2
    exit 1
fi

echo "=== Ralph Loop Starting ==="
echo "Tasks dir: $TASKS_DIR"
echo "Complete dir: $COMPLETE_DIR"
echo "Sessions dir: $SESSIONS_DIR"
echo ""

i=1
while true; do
    # Find the next task file
    TASK_FILE=$(ls "$TASKS_DIR"/*.md 2>/dev/null | head -n 1 || true)

    if [[ -z "$TASK_FILE" ]]; then
        echo ""
        echo "=============================================="
        echo "  MEGA! All tasks complete!"
        echo "  Completed in $((i - 1)) iterations"
        echo "=============================================="
        exit 0
    fi

    TASK_NAME=$(basename "$TASK_FILE" .md)

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Iteration $i — Task: $TASK_NAME"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    PROMPT="You have a task to complete. Read the task file at '$TASK_FILE'.

INSTRUCTIONS:
1. Read the task file carefully
2. Complete the work described in it (make the necessary code changes)
3. Verify the acceptance criteria are met
4. When finished, move the task file to '$COMPLETE_DIR/' using: mv '$TASK_FILE' '$COMPLETE_DIR/'

IMPORTANT — Your final line of output MUST be exactly:
- 'DONE' if you completed the task successfully
- 'FAIL' if you could not complete the task

Focus on quality. Do the task well rather than rushing."

    # Run pi with a session named after the task
    pi --session-dir "$SESSIONS_DIR/$TASK_NAME" -p "$PROMPT" 2>&1 | tee -a "$RALPH_DIR/ralph.log"
    echo ""

    # Check if task was moved to complete
    if [[ -f "$COMPLETE_DIR/$TASK_NAME.md" ]]; then
        echo "✓ Task '$TASK_NAME' completed and moved to $COMPLETE_DIR/"
    else
        echo "⚠ Task '$TASK_NAME' was not moved to complete. Moving it now."
        mv "$TASK_FILE" "$COMPLETE_DIR/"
    fi

    echo ""
    ((i++))
done
