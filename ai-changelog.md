# AI Changelog

Summaries of substantial AI-assisted changes: what was built, why, and the
design decisions behind it. Newest entries first.

## 2026-07-13 — Indexed review screens (IndexedFileReviewScreen / IndexedCommitReviewScreen)

### The problem

The classic review screens (ProjectReviewByFileScreen / ProjectReviewByCommitScreen)
track review progress as per-hunk "seen" marks, keyed by a content hash of each
hunk (FNV-1a of the hunk diff + 5 context lines). Two workflows broke down
under that model:

1. **Fixup-absorb invalidates approvals.** A commit that adds a whole file is
   a single hunk. Approve it, later absorb a one-line fixup into that commit,
   and the hunk's content hash changes — the *entire file* shows up as unseen
   again, with no way to tell what actually changed beyond the approval.
2. **No incremental progress within a hunk.** A whole-file add can only be
   approved all-or-nothing. There was no way to review a large file a piece at
   a time without losing progress whenever anything in the file changed.

### The insight: an index

Both problems are solved by the same idea, borrowed directly from git's index:
instead of persisting marks on hunks, persist an **approved content snapshot**
per file (the "index"). Three contents exist per review entry:

- **base** — what the review diffs against (merge-base version for by-file;
  commit parent version for by-commit)
- **approved** — the index; no record means approved == base (nothing seen)
- **current** — HEAD version (by-file) or the commit's version (by-commit)

Everything falls out of two derived diffs:

- **Unseen view** = diff(approved, current) — what you haven't reviewed yet
- **Seen view** = diff(base, approved) — what you've signed off on
- **Mark hunk seen** = apply that hunk onto the approved snapshot (`git add -p`)
- **Mark lines seen** (visual select + `s`) = apply only the selected rows
- **Unmark** = reverse-apply hunks of the seen diff (`git reset -p`)
- **Mark/unmark file** = approved := current / approved := base

After an absorb, diff(approved, new current) is exactly the fixup's delta —
the file shows one small unseen hunk instead of the whole file. Partial
approvals survive any change anywhere in the file, because the index is
content, not hunk identity.

### Goals and constraints

- **Don't touch the classic screens.** The indexed flows are full copies
  (models, base screen, state, settings) so the hunk-mark implementation
  remains intact as a fallback. State stores are separate
  (`by_file_indexed.json` / `by_commit_indexed.json` vs the classic files);
  neither flow can corrupt the other. No migration — indexed reviews start
  fresh.
- **Keep the keying.** by-commit mark keys stay `fnv1a(subject):filepath`
  (rebase-stable: hashes change on rebase, subjects usually don't), by-file
  stays `filepath`, and branch resolution keeps the detached-HEAD
  subject-overlap logic (extended to also scan indexed state).

### Architecture

- `features/screens/hunk_apply.lua` — the patch engine. Applies/reverse-applies
  GitHunks onto line arrays, full or per-row. Row r of a hunk pairs
  removed[r]/added[r] (the pairing both diff layouts render); a selected row
  takes the new side. Multi-hunk selections apply bottom-up so header
  positions stay valid.
- `features/screens/IndexedBaseReviewModel.lua` — shared model. Fetches base +
  current contents (two `git show`s per entry, parallel preload), computes all
  diffs in-process via `git_hunks.live` (vim.diff/xdiff), owns mark/unmark and
  seen/unseen categorization. After the initial fetch, marking never shells out.
- `features/screens/IndexedReviewState.lua` + `IndexedReviewPersistence.lua` —
  session store and disk persistence. Snapshots are stored content-addressed
  (`$XDG_DATA_HOME/vgit/<repo>/<branch>/objects/<sha256>`), referenced from the
  review-type JSON, deduped across entries, swept on save, and removed with the
  branch by the existing LRU eviction.
- `features/screens/IndexedReviewScreen.lua` — base screen (fork of
  ProjectReviewScreen). Post-mark navigation is simpler than the classic
  screen's content-id hunting: marked hunks vanish from the unseen diff and
  later hunks slide into their slot, so "next target" is the same index clamped
  to the new count. Adds visual-mode `s`/`u` for line-level marking (split
  layout: current/right pane only; the left pane shows old content and every
  change is addressable from the right).
- `IndexedFileReviewScreen/`, `IndexedCommitReviewScreen/` — thin subclasses
  mirroring the classic ones (StatusListView vs CommitListView + commit
  message box). Commands: `:VGit indexed_file_review` /
  `:VGit indexed_commit_review`.

### Semantics and trade-offs

- Content-only equality: an approved record equals base/current iff the lines
  match. Presence flags (deleted/missing) only matter for rendering — every
  empty-vs-empty pairing (rolled-back add vs absent base, approved deletion vs
  deleted current) is correctly "equal" since an empty diff has nothing to
  review. (A flag-sensitive comparison left phantom empty Seen entries; caught
  by integration testing.)
- The Seen view is the *recombined* diff(base, approved), not a replay of
  historical mark steps — adjacent approvals merge, and `u` operates on the
  recombined hunks (like `git reset -p`). It renders the approved snapshot's
  content, so its line numbers can drift from the working file after fixups.
- Selecting a row of a change hunk takes the whole pair (added line + its
  aligned deletion) — you can't take an addition while keeping the old line.
- Commits with identical subjects share an index entry (same trade-off the
  classic by-commit screen documents for its mark keys).
- Hunk boundaries come from xdiff (`vim.diff`) rather than the git CLI, so
  splits can occasionally differ slightly from `git diff`.

### Verification

- `tests/unit/features/screens/hunk_apply_spec.lua`: 24 cases — apply/reverse
  round trips (incl. 100 randomized diffs), partial-row semantics, incremental
  convergence.
- Integration tests against real temp repos (both modes): fetch → line-level
  marking → rollback → full approval → persist → **amend a line into the
  commit** → fresh-process refetch → unseen diff is exactly the one-line delta
  → re-approve → unmark-all → record removed, object store swept clean. The
  by-commit run confirmed the subject-keyed snapshot survives hash-changing
  amends.

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
