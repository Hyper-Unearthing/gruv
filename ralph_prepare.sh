#!/bin/bash

# Ralph Prepare - Two-phase task generation from a work document
# Phase 1: Generate a todo.md with all tasks needed
# Phase 2: Loop over todo items, creating a detailed task file for each
# Usage: ralph_prepare.sh <work-document>

set -euo pipefail

RALPH_DIR=".ralph"
TASKS_DIR="$RALPH_DIR/tasks"
COMPLETE_DIR="$RALPH_DIR/complete"
SESSIONS_DIR="$RALPH_DIR/sessions"
TODO_FILE="$RALPH_DIR/todo.md"
WORK_DOC=${1:-}

if [[ -z "$WORK_DOC" ]]; then
    echo "Usage: ralph_prepare.sh <work-document>" >&2
    exit 1
fi

if [[ ! -f "$WORK_DOC" ]]; then
    echo "Document not found: $WORK_DOC" >&2
    exit 1
fi

mkdir -p "$TASKS_DIR" "$COMPLETE_DIR" "$SESSIONS_DIR"

# ── Phase 1: Generate todo.md ──────────────────────────────────────────

echo "=== Phase 1: Generating todo.md from $WORK_DOC ==="

TODO_PROMPT="You are a senior engineer. Read the document at '$WORK_DOC'.

Break the work described into individual tasks needed to complete the project. Write them to '$TODO_FILE' as a markdown checklist.

Rules:
- Treat 'recipes/architecture.md' as the primary architecture source of truth.
- Before creating tasks, read and follow related docs referenced in recipes/ (cross-references are part of the spec).
- Tasks must be framed as extensions to the existing codebase in this repository, not a new standalone app.
- Each line is a checkbox item: '- [ ] <task-name> — <one-line description>'
- The <task-name> MUST be lowercase kebab-case (e.g. 'setup-database-schema', 'add-auth-middleware')
- Order tasks logically — dependencies first, then features, then polish
- Aim for 3-15 tasks, each a meaningful chunk of work
- Each task description should reference likely existing files/modules to modify when possible.
- Do not generate “bootstrap a new project/app” tasks unless architecture.md explicitly requires it.
- Do NOT create any task files yet, ONLY write '$TODO_FILE'

Example format:
\`\`\`
# Todo

- [ ] setup-project-structure — Initialize the project with config files and directory layout
- [ ] implement-data-models — Create the core data models and database schema
- [ ] add-api-endpoints — Build the REST API routes for CRUD operations
\`\`\`

Do NOT output anything else. Just create the todo file."

pi --session-dir "$SESSIONS_DIR/generate-todo" -p "$TODO_PROMPT" 2>&1 | tee "$RALPH_DIR/phase1.log"

if [[ ! -f "$TODO_FILE" ]]; then
    echo "Failed to generate $TODO_FILE" >&2
    exit 1
fi

echo ""
echo "Todo generated:"
cat "$TODO_FILE"
echo ""

# ── Phase 2: Create task files from todo items ─────────────────────────

echo "=== Phase 2: Creating task files from todo.md ==="

i=1
while IFS= read -r line <&3; do
    # Extract task name from lines like: - [ ] task-name — description
    TASK_NAME=$(echo "$line" | sed -n 's/^- \[ \] \([a-z0-9-]*\).*/\1/p')

    if [[ -z "$TASK_NAME" ]]; then
        continue
    fi

    PADDED=$(printf "%03d" "$i")
    TASK_FILE="$TASKS_DIR/${PADDED}-${TASK_NAME}.md"

    # Skip if task file already exists (check with any numeric prefix)
    EXISTING=$(ls "$TASKS_DIR"/*-"$TASK_NAME".md 2>/dev/null || true)
    if [[ -n "$EXISTING" ]]; then
        TASK_FILE="$EXISTING"
        echo "⏭  Task file already exists: $TASK_FILE — skipping"
        ((i++))
        continue
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Task $i: $TASK_NAME"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    TASK_PROMPT="You are a senior engineer. Read the work document at '$WORK_DOC' and the todo at '$TODO_FILE'.

Your job is to create a detailed task file for this specific todo item:
$line

Write the task file to '$TASK_FILE'.

Rules for file content:
- Treat 'recipes/architecture.md' as authoritative and align all details to it.
- Start with a '# Task: <title>' heading
- Include a clear '## Objective' section describing what needs to be done
- Include a '## Existing Code to Extend' section listing concrete files/modules in this repository that should be modified.
- Include a '## Integration Notes' section explaining how this task connects to current code flow.
- Include a '## Details' section with all relevant context extracted from the source document that someone would need to complete this task (specs, constraints, examples, file paths, etc.)
- Include a '## Acceptance Criteria' section with a checklist of what 'done' looks like
- Be specific and self-contained — someone should be able to complete the task reading only this file
- When recipes docs are referenced by architecture.md, incorporate those constraints explicitly in this task.
- Reference other tasks from the todo if there are dependencies, but don't duplicate their work
- Do not describe work as creating a separate standalone application unless explicitly required by architecture.md.

Do not write any code
Do NOT output anything else. Just create the task file."

    pi --session-dir "$SESSIONS_DIR/prepare-$TASK_NAME" -p "$TASK_PROMPT" 2>&1 | tee -a "$RALPH_DIR/phase2.log"
    echo ""

    if [[ -f "$TASK_FILE" ]]; then
        echo "✓ Created $TASK_FILE"
    else
        echo "⚠ Failed to create $TASK_FILE"
    fi

    echo ""
    ((i++))
done 3< "$TODO_FILE"

echo "=============================================="
echo "  Preparation complete!"
echo "  Todo: $TODO_FILE"
echo "  Task files:"
ls "$TASKS_DIR/"
echo "=============================================="
