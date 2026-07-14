# AI Changelog

Summaries of substantial AI-assisted changes: what was built, why, and the
design decisions behind it. Newest entries first.

## 2026-07-13 — Root-cause fix for float off-by-one rendering (padding hack removed)

`dimensions.global_height()` said `vim.o.lines`, but floats can't extend into
the cmdline (or a drawn tabline) — nvim shifts overflowing floats up, sliding
the first content rows under the header floats. A content-padding hack
(blank buffer lines + `± padding` in all cursor/extmark math, keyed on
`showtabline > 0`) had compensated since 2025-12 and drifted out of sync with
reality (default `showtabline=1` draws no tabline with one tab page).

Fixed the height math at the root and deleted the hack from DiffView,
FoldableListComponent, CommitMessageView, ComponentPlot, and RowLayout.
Buffer row == content row everywhere now. Verified with pty screen-snapshot
tests (`vim.fn.screenstring`) across classic + indexed review screens and
DiffScreen, tabline hidden and drawn. Details and the debugging method:
`notes/FLOATING_WINDOW_POSITIONING.md`.
