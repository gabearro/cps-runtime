# Nim Todo (GUI + Nim Bridge)

This example validates Nim-owned GUI actions routed through the embedded bridge.
It includes:

- professional two-pane desktop layout sized for macOS productivity
- configurable window chrome (`showTitleBar: true|false`)
- custom task creation with draft status + priority selectors
- due-date entry and overdue highlighting (`YYYY-MM-DD`)
- dynamic unbounded task list with scrollable overflow
- direct row-click selection using payload action dispatch
- inline selected-task editing (rename + due-date updates)
- selected-task reordering controls (`Move Up` / `Move Down`)
- status transitions (`Backlog`, `In Progress`, `Blocked`, `Done`)
- completion, reopen, removal, clear-completed, demo-data, and reset flows
- task filters (`All`, `Open`, `Done`, `Blocked`) and text search
- sort modes (`Newest`, `Due Soonest`, `Priority`)
- persisted board + view preferences in `~/.cpsimpl_nim_todo_state_v2.json`
- Nim-owned state patching for deterministic UI updates from bridge logic
- macro-driven window sizing via the same `.gui` module (`guiFile(...)`)

## Files

- `app.gui`: SwiftUI GUI DSL app definition.
- `bridge.nim`: Nim application logic for task create/update/complete/remove/reset.
- `macro_entry.nim`: macro-surface binding using `guiFile(...)` for the same GUI.

## Run

```bash
nimble gui -- run examples/gui/todo/app.gui --out out
```

## Build only

```bash
nimble gui -- build examples/gui/todo/app.gui --out out --configuration Debug
```

The bridge builds into:

- `out/NimTodoGui/Bridge/Nim/libgui_bridge_latest.dylib` (macOS)

## Macro validation

```bash
nim c -r --path:src examples/gui/todo/macro_entry.nim
```
