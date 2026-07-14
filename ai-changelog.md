# AI Changelog

Summaries of substantial AI-assisted changes: what was built, why, and the
design decisions behind it. Newest entries first.

## 2026-07-14 — Visual line-level staging in ProjectDiffScreen

Visual-select lines in the diff pane and press `s`/`u` to stage/unstage just
those lines (the `git add -p` edit-hunk workflow, without the editing) —
the same interaction the indexed review screens ship for marking lines seen.

Mechanics: the shared range→per-hunk-rows mapping moved to
`features/screens/visual_selection.lua` (extracted from IndexedReviewScreen,
which now delegates). `GitHunk:select_rows(rows)` slices a hunk to the
selected pair rows and renumbers the header (partial selections of uneven
hunks degrade correctly to pure insertions/removals anchored by git's
"zero-count side numbers the line before" convention); the sub-hunk then
flows through the existing GitPatch → `git apply --cached --unidiff-zero`
pipeline. Multi-hunk selections apply bottom-up so earlier hunks' index
numbering stays valid. Split layout: selections in the current (right) pane
only, matching the indexed screens.

Fixed a pre-existing unstage bug this exposed: `git apply` positions a patch
by its old-side line numbers *even under `--reverse`*, so reverse-applying a
HEAD→index hunk mislocated the change in the index whenever earlier staged
hunks had shifted line counts — a staged deletion below staged additions was
silently restored in the wrong place (probed empirically with git's own
unmodified hunk). `Model:unstage_hunk` now forward-applies the inverse hunk
(`GitHunk:invert()`), which is numbered by the index side and lets git
validate the content it touches.

Verified: GitHunk unit specs (slice/invert/round-trip, anchor conventions);
integration against real repos — staging row subsets of change/add/remove
hunks yields byte-exact index content, inverse-unstage round trips, and the
misplacement regression; pty tests driving real visual-mode keypresses in
the screen for both partial stage and normal-mode unstage.

## 2026-07-13 — Rebase approved snapshots when the base changes

The indexed model's "after an absorb, diff(approved, new current) is exactly
the fixup's delta" property silently assumed a fixed parent chain. Inserting
or reordering a commit below an already-reviewed one shifts both base and
current of every descendant by that commit's delta while the approved
snapshots stay put — so each descendant's Unseen view showed the ancestor's
changes as new work, and its Seen view showed them *reversed*
(diff(new base → stale approved) un-does them). Observed in the wild as a
phantom `get_next_unused_address -> get_address` hunk after a rename commit
was added to the bottom of a stack.

Fix: records now store the base content they were approved against
(`{ approved, base }` object refs in the JSON, both content-addressed and
swept together). On first access with a mismatched live base, the model
rebases the index: `hunk_apply.rebase` re-plays diff(stored base → approved)
onto the new base, locating each hunk by exact content plus up to 3 context
lines (ties broken by proximity to the original position, matches kept in
order). Hunks that no longer apply are dropped *individually* — a conflicted
hunk reverts to unseen for re-review while the file's other approvals
survive. If everything drops, the record is removed. Legacy records without
a stored base keep the old behavior — and partial marks/unmarks on them stay
base-less: stamping the live base onto content derived from a stale snapshot
would freeze its base drift as approved forever (observed in the wild as
approved "reversions" of a base commit's endpoint-versioning changes). A
mark that lands exactly on the current content, like `mark_file`, heals the
record with a consistent base.

Tests: rebase cases in `hunk_apply_spec.lua` (drift, per-hunk conflict,
insertion relocation by context, repeated-content disambiguation, randomized
identity) and reconcile-level cases in `IndexedBaseReviewModel_spec.lua`
against a stub model, including the exact restack scenario above and the
legacy-record laundering cases.

## 2026-07-13 — Fixed 80-column file list, mouse-draggable boundary

The list/diff split was 25vw/75vw, so the file-list column width varied with
the terminal and commit messages rarely wrapped at their natural width. Now
every list+diff screen (classic + indexed reviews, project diff, stash) plots
the list at a fixed `list_width` columns — default 80, except 72 on the
by-commit screens so convention-wrapped commit message bodies fit the box
exactly.

The plot system is percentage-string based (and its relative math assumes
`col + width = 100vw`), so `dimensions.fixed_split(cols)` converts the fixed
width into vw strings nudged by -0.1 so `convert()`'s `math.ceil` lands
exactly on `cols` / `total - cols` — no horizontal overflow, hence no
compositor shift (the horizontal twin of the float bug fixed earlier).

On the indexed screens (left-list layout) the boundary is mouse-draggable:
`ui/drag_resize.lua` installs screen-lifetime `<LeftMouse>/<LeftDrag>/
<LeftRelease>` expr mappings; a press on the 2-column grab zone arms a drag
(clicks elsewhere fall through), drag events re-plot the seven affected
windows (list, message header/body, panes + headers) via `vim.schedule`, and
release re-renders width-dependent content (void filler, message wrap
height) and remembers the width in the setting for the session. Verified via
pty tests driving `nvim_input_mouse`: default geometry, drag 80→100 in split
and unified layouts, setting persistence, click fall-through, mapping
removal on quit, and an exhaustive `fixed_split` rounding sweep.

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
