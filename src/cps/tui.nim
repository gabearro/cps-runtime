## CPS TUI Library
##
## Terminal User Interface library built on the CPS runtime.
## Re-exports all TUI submodules for convenient single-import usage.
##
## Usage:
##   import cps/tui
##
## This gives you access to:
##   - style: Colors, text attributes, ANSI escape sequences, border styles
##   - cell: CellBuffer (2D grid of styled cells), double buffering, diff rendering
##   - input: Terminal input parsing (keys, mouse, resize), async reader
##   - layout: Flexbox-inspired layout engine (horizontal/vertical, flex/fixed/percent)
##   - widget: Composable widget tree (text, border, input, list, table, tabs, etc.)
##   - renderer: Widget tree -> CellBuffer rendering
##   - textinput: Text editing state manager with history
##   - reactive: Reactive signals and computed values
##   - dsl: Macro DSL for declarative widget tree construction
##   - components: Split views, scrollable text, status bar, dialog, tree view, etc.
##   - app: Application framework with event loop integration

import cps/tui/[style, cell, input, layout, widget, renderer, textinput, reactive, dsl, components, app]
export style, cell, input, layout, widget, renderer, textinput, reactive, dsl, components, app
