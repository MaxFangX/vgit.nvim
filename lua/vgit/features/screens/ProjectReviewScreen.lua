local fs = require('vgit.core.fs')
local Scene = require('vgit.ui.Scene')
local loop = require('vgit.core.loop')
local event = require('vgit.core.event')
local utils = require('vgit.core.utils')
local Buffer = require('vgit.core.Buffer')
local Object = require('vgit.core.Object')
local Window = require('vgit.core.Window')
local console = require('vgit.core.console')
local DiffView = require('vgit.ui.views.DiffView')
local dimensions = require('vgit.ui.dimensions')
local drag_resize = require('vgit.ui.drag_resize')
local KeyHelpBarView = require('vgit.ui.views.KeyHelpBarView')
local file_navigation = require('vgit.features.screens.file_navigation')
local visual_selection = require('vgit.features.screens.visual_selection')

--[[
  ProjectReviewScreen is the base class for the review screens
  (ProjectReviewByFileScreen and ProjectReviewByCommitScreen). Marking edits
  the approved snapshot (see ReviewModel), so a section's hunks shift as
  hunks are marked. s/u also mark visual selections line by line, in split
  layout from the current pane only. A browse (see ReviewModel) has no mark
  keys.

  Every motion picks a target entry id, then select(id) reveals its list row
  (expanding its commit and folders) and shows it in the diff. Navigation
  order is the list's fold tree, collapsed folds included, so it always
  follows the display.

  Keys run as jobs through one queue (see enqueue). Mark keys typed while a
  mark ran wait for it to settle, and drop if a held key sent them (see
  mark_job). A job runs within one main-loop turn: it never yields, so no
  typed input lands mid-job and each job sees the state the keys before it
  left. Of the model's calls only fetch runs git, outside any job; the
  screen frees the textlock right after it. The views and the review
  state's saves leave a fast event context only when in one
  (loop.leave_fast_event).

  Subclasses set model, setting and list_view, call init_views, and
  implement plot_views. They may override jump_section (J/K in the list).
]]

local ProjectReviewScreen = Object:extend()

function ProjectReviewScreen:constructor()
  return {
    name = 'Project Review Screen',
    scene = Scene(),
    app_bar_view = nil,
    diff_view = nil,
    -- By-commit left/right layouts' message box, mounted last
    commit_message_view = nil,
    -- List column width while the list/diff boundary is draggable
    list_cols = nil,
    source_win_id = nil,
    _resize_autocmd = nil,
    -- Keypress jobs not yet run, and whether the runner is draining them
    _jobs = {},
    _running = false,
    -- The last mark's batch: the mark keys typed while it ran (see mark_job)
    _batch = nil,
    -- Whether the last batch with mark keys came from a held key
    _holding = false,
    _drag_detach = nil,
    _destroyed = false,
  }
end

function ProjectReviewScreen:init_views()
  local model = self.model
  local setting = self.setting

  self.app_bar_view = KeyHelpBarView(self.scene, {
    keymaps = function()
      local keymaps = setting:get('keymaps')
      local navigation = {
        { 'Next',              keymaps['next'] },
        { 'Previous',          keymaps['previous'] },
        { 'Jump section',      keymaps['jump_section_next'] },
      }
      if model:is_browse() then return navigation end
      return vim.list_extend({
        { 'Mark hunk/lines',   keymaps['mark_hunk'] },
        { 'Mark file',         keymaps['mark_file'] },
        { 'Unmark hunk/lines', keymaps['unmark_hunk'] },
        { 'Unmark file',       keymaps['unmark_file'] },
        { 'Reset',             keymaps['reset'] },
      }, navigation)
    end,
  })

  self.diff_view = DiffView(self.scene, {
    layout_type = function()
      return model:get_layout_type()
    end,
    filepath = function()
      return model:get_filepath()
    end,
    filetype = function()
      return model:get_filetype()
    end,
    diff = function()
      return model:get_diff()
    end,
  }, nil, {
    elements = {
      header = true,
      footer = false,
    },
  })
end

-- Views in mount order (the list is mounted over the diff). ipairs stops at
-- an absent commit message view, so it goes last.
function ProjectReviewScreen:views()
  return { self.diff_view, self.app_bar_view, self.list_view, self.commit_message_view }
end

-- Show entry `id` in the diff at hunk `hunk` (1 = first, 0 = last).
-- Re-showing the current entry keeps its viewport.
function ProjectReviewScreen:show_entry(id, hunk)
  local current = self.model:get_entry()
  if current and current.id == id then self.diff_view:save_viewport() end

  self.model:set_entry_id(id)
  self.diff_view:render()
  self.diff_view:move_to_hunk(hunk, 'smart')
end

-- Reveal entry `id` in the list and show it; false if it doesn't exist
function ProjectReviewScreen:select(id, hunk)
  if not id or not self.list_view:reveal(id) then return false end
  self:show_entry(id, hunk)
  return true
end

-- Index of file node `id` in `files`
local function index_of(files, id)
  for i, node in ipairs(files) do
    if node.id == id then return i end
  end
end

-- Select files[target], arriving from files[from] going `direction`, at its
-- first (next) or last (prev) hunk. After a wrap, keep that end of the list
-- in view.
function ProjectReviewScreen:select_file(files, from, target, direction)
  local is_next = direction == 'next'
  if not self:select(files[target].id, is_next and 1 or 0) then return end

  if is_next and target < from then
    self.list_view:scroll_to('top')
  elseif not is_next and target > from then
    self.list_view:scroll_to('bottom')
  end
end

-- The adjacent file in display order, wrapping. From the list, step from the
-- cursor row: from a header row, next lands on the header's first file.
-- From the diff, step from the entry it shows.
function ProjectReviewScreen:step_file(direction, from_list)
  local files = self.list_view:file_nodes()
  local from, on_header
  if from_list then
    from, on_header = self.list_view:cursor_file_index()
  else
    local entry = self.model:get_entry()
    from = entry and index_of(files, entry.id)
  end
  if not from then return end

  local target = from
  if not (on_header and direction == 'next') then
    target = (from - 1 + (direction == 'next' and 1 or -1)) % #files + 1
  end
  self:select_file(files, from, target, direction)
end

-- j/k in the diff: step one hunk, crossing files from the edge hunk or past it
function ProjectReviewScreen:step_hunk(direction)
  local index, total, position = self.diff_view:get_cursor_mark_position()
  local past_edge = position == (direction == 'next' and 'below' or 'above')
  if past_edge or file_navigation.should_cross_file(direction, index, total, position) then
    return self:step_file(direction)
  end

  if direction == 'next' then
    self.diff_view:next('smart')
  else
    self.diff_view:prev('smart')
  end
end

-- J/K in the diff: this file's last (next) / first (prev) hunk; from there,
-- the adjacent file's first / last hunk
function ProjectReviewScreen:jump_to_file_edge(direction)
  local index, total, position = self.diff_view:get_cursor_mark_position()
  if file_navigation.should_cross_file(direction, index, total, position) then
    return self:step_file(direction)
  end
  self.diff_view:move_to_hunk(direction == 'next' and 0 or 1, 'smart')
end

-- J/K in the list: jump between folder headings (see section_headings). The
-- by-commit screen jumps between commits instead.
function ProjectReviewScreen:jump_section(direction)
  self.list_view:jump_to_heading(direction)
end

-- Mark (or unmark) `selections` of entry, nil for the whole file, and
-- re-render the list
function ProjectReviewScreen:apply_mark(entry, mark_as_seen, selections)
  if not selections then
    if mark_as_seen then
      self.model:mark_file(entry)
    else
      self.model:unmark_file(entry)
    end
  elseif mark_as_seen then
    self.model:mark_selections(entry, selections)
  else
    self.model:unmark_selections(entry, selections)
  end
  self.list_view:render()
end

-- Apply `selections` of the current entry (nil: the whole file) to the
-- approved snapshot, then land on the next work in the section the entry
-- drains from, which loops:
--   1. this file's first hunk past the marked region
--   2. the section's next file (wrapping)
--   3. this file's remaining earlier hunks
--   4. the section is done: this file, now in the other section
-- Marking rewrites the diff (hunks shift, a partially marked hunk splits), so
-- step 1 goes by position: the first hunk starting below where the marked
-- region began. Earlier hunks wait for the wrap.
function ProjectReviewScreen:mark(mark_as_seen, selections)
  local entry = self.model:get_entry()
  if not entry then return end

  -- S/U from the destination section: the rest of the file joins this entry
  if entry.type == (mark_as_seen and 'seen' or 'unseen') then
    local hunk = self.diff_view:get_cursor_mark_position() or 1
    self:apply_mark(entry, mark_as_seen, nil)
    self:select(entry.id, hunk)
    return
  end

  -- Where the marked region begins, in the last selection's hunk (the
  -- bottom of a visual range): that hunk's new-side top, and on the old side
  -- the first selected line
  local from = { top = 0, old = 0 }
  local last = selections and selections[#selections]
  local marked_diff = last and self.diff_view:get_diff()
  local mark = marked_diff and marked_diff.marks[last.index]
  if mark then
    local picked = last.rows or last.lines and last.lines.removed or {}
    local first = next(picked) and math.min(unpack(vim.tbl_keys(picked))) or 1
    local previous = marked_diff.hunks[last.index]:parse_header()
    from = { top = mark.top_relative, old = previous[1] + first - 1 }
  end

  local next_id = file_navigation.next_of_type(self.list_view:file_nodes(), entry.id, entry.type)
  self:apply_mark(entry, mark_as_seen, selections)

  local remaining = self.model:lookup(entry.id)
  if remaining then
    local diff = self.model:get_diff_for(remaining)
    local hunk = diff and file_navigation.hunk_past_position(diff, from)
    if hunk and self:select(entry.id, hunk) then return end
  end
  if self:select(next_id, 1) then return end
  if remaining and self:select(entry.id, 1) then return end
  self:select(self.model:sibling_id(entry), 1)
end

-- s/u act only on the section their hunks come from. `selections` is a
-- visual range's, else the hunk under the cursor. A hunkless diff (e.g. a
-- marked pure rename) has no hunk there, so s/u mark the whole file.
function ProjectReviewScreen:mark_hunk(mark_as_seen, selections)
  local entry = self.model:get_entry()
  if not entry or entry.type ~= (mark_as_seen and 'unseen' or 'seen') then return end

  if not selections then
    local index = self.diff_view:get_cursor_mark_position()
    selections = index and { { index = index } }
  end
  self:mark(mark_as_seen, selections)
end

-- Visual s/u over diff rows [top, bot]. Unified marks exactly the selected
-- lines; split marks pair rows, as both halves of a row are on screen.
function ProjectReviewScreen:mark_range(mark_as_seen, top, bot)
  local diff = self.diff_view:get_diff()
  local selections
  if self.model:get_layout_type() == 'unified' then
    selections = visual_selection.lines_for_range(diff, top, bot)
  else
    selections = visual_selection.for_range(diff, 'split', top, bot)
  end
  if not selections then return self.diff_view:notify('No hunks in selection') end
  self:mark_hunk(mark_as_seen, selections)
end

-- The first unseen entry in display order, else the first entry
function ProjectReviewScreen:first_entry_id()
  local files = self.list_view:file_nodes()
  for _, node in ipairs(files) do
    if node.entry.type == 'unseen' then return node.id end
  end
  return files[1] and files[1].id
end

function ProjectReviewScreen:reset_marks()
  local decision = console.input('Reset all marks? (y/N) '):lower()
  if decision ~= 'yes' and decision ~= 'y' then return end

  local entry = self.model:get_entry()
  self.model:reset_marks()
  self.list_view:render()

  -- Everything is unseen again, so stay on this file's unseen entry
  local id = entry and (entry.type == 'unseen' and entry.id or self.model:sibling_id(entry))
  if not self:select(id, 1) then self:select(self:first_entry_id(), 1) end
end

function ProjectReviewScreen:toggle_focus()
  local list_component = self.scene:get('list')
  local diff_component = self.scene:get('current')

  if list_component:is_focused() then
    diff_component:focus()
  else
    list_component:focus()
  end
end

-- 'list' or 'diff'. Derived, since a mouse click switches panes too.
function ProjectReviewScreen:focused_pane()
  return self.scene:get('list'):is_focused() and 'list' or 'diff'
end

-- CursorMoved in the list. A job's own moves leave the cursor on the entry
-- it shows, so the queued show_list_item does nothing for them.
function ProjectReviewScreen:handle_list_move()
  self:enqueue(function() self:show_list_item() end)
end

-- Show the entry under the list cursor. Plain cursor movement (arrows,
-- clicks) never changes which commit is expanded, and header rows leave the
-- diff alone. The current entry isn't re-shown, which would reset the diff
-- cursor on spurious CursorMoved (focus changes).
function ProjectReviewScreen:show_list_item()
  local item = self.list_view:get_current_list_item()
  if not item or not item.id then return end

  local entry = self.model:get_entry()
  if entry and entry.id == item.id then return end
  self:show_entry(item.id, 1)
end

function ProjectReviewScreen:open_file()
  local filepath = self.model:get_abs_filepath()
  if not filepath then return end
  if not fs.exists(filepath) then return console.info('File has been deleted') end

  local diff = self.diff_view:get_diff()
  local mark = self.diff_view:get_current_mark_under_cursor() or (diff and diff.marks[1])

  self:destroy()
  fs.open(filepath)
  if mark then Window(0):set_lnum(mark.top_relative):position_cursor('center') end
  event.emit('VGitSync')
end

-- Run fn(...) after every job queued before it. Keymap callbacks only
-- enqueue, so presses run one at a time and in order however fast they
-- arrive, and each job reads cursor and model state when it runs. Jobs
-- still queued when the screen is destroyed are dropped.
function ProjectReviewScreen:enqueue(fn, ...)
  self:push_job({ fn = fn, args = { n = select('#', ...), ... } })
end

-- Queue `job` ({ fn, args, batch? }) and run the queue. A job with a batch
-- (see mark_job) waits, holding the jobs behind it, until the batch settles.
function ProjectReviewScreen:push_job(job)
  if self._destroyed then return end
  self._jobs[#self._jobs + 1] = job
  self:run_jobs()
end

function ProjectReviewScreen:run_jobs()
  if self._running then return end

  self._running = true
  loop.coroutine(function()
    while #self._jobs > 0 and not self._destroyed do
      local job = self._jobs[1]
      if job.batch and not job.batch.settled_at then break end
      table.remove(self._jobs, 1)
      local ok, err = pcall(job.fn, unpack(job.args, 1, job.args.n))
      -- A job cut short by destroy() fails on the closed windows
      if not ok and not self._destroyed then console.error(tostring(err)) end
    end
    self._running = false
  end)()
end

-- Key repeat is 30-40ms and taps come slower, so mark keys typed while a
-- mark ran that average closer together than this (ms) came from a held key
local HOLD_SPACING_MS = 60
-- At most this many taps typed while a mark ran still run
local QUEUED_TAPS_MAX = 5

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

-- Judge whether the complete `batch`'s mark keys were taps (see mark_job)
-- and run the jobs it held. A held key's last batch may hold a single
-- repeat, spaced like a tap, so once a batch is judged held, every batch
-- until a pause is too.
function ProjectReviewScreen:settle_batch(batch)
  batch.settled_at = now_ms()
  batch.taps = not self._holding and batch.settled_at - batch.started_at >= HOLD_SPACING_MS * batch.count
  if batch.count > 0 then self._holding = not batch.taps end
  self:run_jobs()
end

function ProjectReviewScreen:setup_keymaps()
  local keymaps = self.setting:get('keymaps')
  local function job(fn)
    return function(...)
      self:enqueue(fn, ...)
    end
  end
  local toggle_focus = job(function() self:toggle_focus() end)

  self.list_view:set_keymap({
    { mode = 'n', mapping = keymaps.toggle_focus, handler = toggle_focus },
    { mode = 'n', mapping = keymaps.next, handler = job(function() self:step_file('next', true) end) },
    { mode = 'n', mapping = keymaps.previous, handler = job(function() self:step_file('prev', true) end) },
    { mode = 'n', mapping = keymaps.jump_section_next, handler = job(function() self:jump_section('next') end) },
    { mode = 'n', mapping = keymaps.jump_section_prev, handler = job(function() self:jump_section('prev') end) },
    -- Replaces BaseListView's Enter, so the fold toggle runs in order too
    {
      mode = 'n',
      mapping = { key = '<enter>', desc = 'Enter item' },
      handler = job(function()
        local item = self.list_view:get_current_list_item()
        if not item then return end
        self.list_view:toggle_current_list_item()
        if item.id then self:open_file() end
      end),
    },
  })

  self.diff_view:set_keymap({
    { mode = 'n', mapping = keymaps.toggle_focus, handler = toggle_focus },
    { mode = 'n', mapping = keymaps.next, handler = job(function() self:step_hunk('next') end) },
    { mode = 'n', mapping = keymaps.previous, handler = job(function() self:step_hunk('prev') end) },
    { mode = 'n', mapping = keymaps.jump_section_next, handler = job(function() self:jump_to_file_edge('next') end) },
    { mode = 'n', mapping = keymaps.jump_section_prev, handler = job(function() self:jump_to_file_edge('prev') end) },
    {
      mode = 'n',
      mapping = { key = '<enter>', desc = 'Open buffer' },
      handler = job(function() self:open_file() end),
    },
  })

  if not self.model:is_browse() then self:setup_mark_keymaps(keymaps, job) end
end

-- The mark keys: s/u/S/U and reset, then the visual-mode s/u
function ProjectReviewScreen:setup_mark_keymaps(keymaps, job)
  -- A mark key's job. Neovim reads all typeahead before running timer
  -- callbacks, so the mark keys read before a mark's settle timer fires
  -- were typed while it ran. They wait for it as its batch, then run if
  -- spaced like taps, up to QUEUED_TAPS_MAX of them, and drop if spaced
  -- like a held key's repeats, which would mark hunks never shown and keep
  -- marking after release. So a held key marks one step per screen update.
  -- Keys from a macro run as typed.
  local function mark_job(fn)
    local function run(...)
      local batch = { started_at = now_ms(), count = 0 }
      fn(...)
      self._batch = batch
      vim.defer_fn(function() self:settle_batch(batch) end, 0)
    end
    return function(...)
      local batch = self._batch
      if batch and not batch.settled_at and vim.fn.reg_executing() == '' then
        batch.count = batch.count + 1
        local nth = batch.count
        return self:push_job({
          fn = function(...)
            if batch.taps and nth <= QUEUED_TAPS_MAX then run(...) end
          end,
          args = { n = select('#', ...), ... },
          batch = batch,
        })
      end

      -- A pause since the last mark means any held key was let go
      if batch and batch.settled_at and now_ms() - batch.settled_at >= HOLD_SPACING_MS then self._holding = false end
      self:enqueue(run, ...)
    end
  end

  local mark_hunk = mark_job(function() self:mark_hunk(true) end)
  local unmark_hunk = mark_job(function() self:mark_hunk(false) end)
  local mark_file = mark_job(function() self:mark(true) end)
  local unmark_file = mark_job(function() self:mark(false) end)
  local reset = job(function() self:reset_marks() end)

  self.list_view:set_keymap({
    -- `mark_hunk` has no target in the list, but a no-op keeps it from falling
    -- through to a global mapping
    {
      mode = 'n',
      mapping = { key = keymaps.mark_hunk.key, desc = 'No-op (mark hunk is diff-pane only)' },
      handler = function() end,
    },
    { mode = 'n', mapping = keymaps.mark_file, handler = mark_file },
    { mode = 'n', mapping = keymaps.unmark_file, handler = unmark_file },
    { mode = 'n', mapping = keymaps.reset, handler = reset },
  })

  self.diff_view:set_keymap({
    { mode = 'n', mapping = keymaps.mark_hunk, handler = mark_hunk },
    { mode = 'n', mapping = keymaps.unmark_hunk, handler = unmark_hunk },
    { mode = 'n', mapping = keymaps.mark_file, handler = mark_file },
    { mode = 'n', mapping = keymaps.unmark_file, handler = unmark_file },
    { mode = 'n', mapping = keymaps.reset, handler = reset },
  })

  self:setup_visual_keymaps(keymaps, job)
end

-- Visual-mode s/u: line-level marking. In split layout, the previous pane's
-- rows show old content, and every change is addressable from the current
-- pane, so only the current pane accepts selections. A held s leaves visual
-- mode at its first press, so these never see its repeats.
function ProjectReviewScreen:setup_visual_keymaps(keymaps, job)
  local current_component = self.scene:get('current')
  local mark_lines = job(function(top, bot) self:mark_range(true, top, bot) end)
  local unmark_lines = job(function(top, bot) self:mark_range(false, top, bot) end)

  current_component:set_keymap({
    mode = 'x',
    mapping = { key = keymaps.mark_hunk.key, desc = 'Mark selected lines seen' },
  }, visual_selection.make_handler(mark_lines))
  current_component:set_keymap({
    mode = 'x',
    mapping = { key = keymaps.unmark_hunk.key, desc = 'Unmark selected lines' },
  }, visual_selection.make_handler(unmark_lines))

  if self.model:get_layout_type() == 'split' then
    local previous_component = self.scene:get('previous')
    local function notify_wrong_pane()
      self.diff_view:notify('Select lines in the right pane to mark them')
    end
    previous_component:set_keymap({
      mode = 'x',
      mapping = { key = keymaps.mark_hunk.key, desc = 'No-op (select in current pane)' },
    }, notify_wrong_pane)
    previous_component:set_keymap({
      mode = 'x',
      mapping = { key = keymaps.unmark_hunk.key, desc = 'No-op (select in current pane)' },
    }, notify_wrong_pane)
  end
end

-- Set the views' plots for the editor's current size, with a `cols`-wide
-- list column (nil: the configured width), and set list_cols if the
-- list/diff boundary is draggable. Subclasses implement it.
function ProjectReviewScreen:plot_views(cols) end

-- Re-plot every window (see plot_views). Only the geometry changes.
function ProjectReviewScreen:replot(cols)
  self:plot_views(cols)
  for _, view in ipairs(self:views()) do
    view:replot()
  end
end

-- Re-show the current entry at the diff cursor's hunk, re-rendering its
-- width-dependent void filler
function ProjectReviewScreen:reshow_entry()
  local entry = self.model:get_entry()
  if entry then self:show_entry(entry.id, self.diff_view:get_cursor_mark_position() or 1) end
end

-- VimResized: floating windows keep their size, so re-plot them all
function ProjectReviewScreen:handle_resize()
  self:replot()
  self:reshow_entry()
end

-- Move the list/diff boundary while it's dragged. Content re-renders once
-- on release (finish_list_resize).
function ProjectReviewScreen:apply_list_width(cols)
  cols = dimensions.clamp_list_cols(cols)
  if cols ~= self.list_cols then self:replot(cols) end
end

-- After a drag, re-render the void filler, and remember the width for
-- screens opened later this session
function ProjectReviewScreen:finish_list_resize()
  self.setting:set('list_width', self.list_cols)
  self:reshow_entry()
end

-- Make the list/diff boundary mouse-draggable. Only active when the subclass
-- plotted a left-side list (list_cols set).
function ProjectReviewScreen:setup_drag_resize()
  if not self.list_cols then return end

  -- The handlers arrive via vim.schedule and can race destroy()
  self._drag_detach = drag_resize.attach({
    boundary = function()
      -- First screen column of the diff pane (screen columns are 1-based)
      return self.list_cols + 1
    end,
    on_drag = function(boundary)
      if not self._destroyed then self:apply_list_width(boundary - 1) end
    end,
    on_release = function()
      self:enqueue(function() self:finish_list_resize() end)
    end,
  })
end

-- Unseen entries source_entry_id diffs at most. A lockfile can be in every
-- commit of a long stack, and each diff of it costs a few ms.
local SOURCE_DIFFS_MAX = 10

-- The entry to open the source file on, the cursor at `lnum`. By-commit
-- lists a file once per commit: prefer the latest unseen entry whose hunks
-- hold the line (the latest is closest to the working copy), else
-- `resume_id`, else the latest unseen one, else the latest seen one.
function ProjectReviewScreen:source_entry_id(filepath, lnum, resume_id)
  local files = self.list_view:file_nodes()
  local unseen, seen
  local diffs = 0
  for i = #files, 1, -1 do
    local entry = self.model:lookup(files[i].id)
    if entry.filepath == filepath and entry.type == 'seen' then
      seen = seen or entry.id
    elseif entry.filepath == filepath and diffs < SOURCE_DIFFS_MAX then
      unseen = unseen or entry.id
      diffs = diffs + 1
      local diff = self.model:get_diff_for(entry)
      for _, mark in ipairs(diff and diff.marks or {}) do
        if lnum >= mark.top_relative and lnum <= mark.bot_relative then return entry.id end
      end
    end
  end
  return resume_id or unseen or seen
end

-- Entry to open on, and whether it is the source buffer's file: that file
-- (see source_entry_id, which resumes the saved position when it is an
-- unseen entry of the file), else the saved position (preferring its
-- section and commit), else the first unseen entry
function ProjectReviewScreen:initial_entry_id(buffer, lnum)
  -- Entries are repo-relative, whatever the cwd
  local name = buffer:get_name()
  local source_filepath = name ~= '' and fs.make_relative(self.model:get_reponame(), name)

  local position = self.model:get_review_state():get_position()
  local filepath = position.filepath
  local function find(pred)
    for _, node in ipairs(self.list_view:file_nodes()) do
      local entry = self.model:lookup(node.id)
      if entry.filepath == filepath and pred(entry) then return node.id end
    end
  end

  -- Commit subjects (not hashes) survive rebases
  local function in_section(entry)
    return entry.type == position.type
  end
  local function in_commit(entry)
    return in_section(entry) and (not entry.commit or entry.commit.message == position.commit_message)
  end
  local function any()
    return true
  end

  if source_filepath then
    local resume_id = source_filepath == filepath and position.type == 'unseen' and find(in_commit) or nil
    local source_id = self:source_entry_id(source_filepath, lnum, resume_id)
    if source_id then return source_id, true end
  end

  local saved_id = filepath and (find(in_commit) or find(in_section) or find(any))
  return saved_id or self:first_entry_id(), false
end

-- Open the review of HEAD against args[1] (nil: the detected base), or the
-- browse of the range args[1]
function ProjectReviewScreen:create(args)
  local base_or_range = (args or {})[1]
  local buffer = Buffer(0)
  -- Capture the source position before mounting any views
  local source_lnum, source_col, source_winline = vim.fn.line('.'), vim.fn.col('.'), vim.fn.winline()
  self.source_win_id = vim.api.nvim_get_current_win()

  local data, err = self.model:fetch(base_or_range)
  loop.free_textlock()

  if err then
    console.debug.error(err).error(err)
    return false
  end

  if utils.object.is_empty(data) then
    console.info('No changes to review')
    return false
  end

  self:plot_views()

  local views = self:views()
  for _, view in ipairs(views) do
    view:define()
  end
  for _, view in ipairs(views) do
    view:mount({
      event_handlers = {
        on_move = function()
          self:handle_list_move()
        end,
      },
    })
  end

  self.list_view:set_title(self.model:get_list_title())
  for _, view in ipairs(views) do
    view:render()
  end

  self:setup_keymaps()
  self:setup_drag_resize()
  self._resize_autocmd = vim.api.nvim_create_autocmd('VimResized', {
    callback = function()
      self:enqueue(function() self:handle_resize() end)
    end,
  })

  local id, from_buffer = self:initial_entry_id(buffer, source_lnum)
  self:select(id, 1)

  -- Focus explicitly: the commit message view may have taken it while mounting
  if self.model:get_review_state():get_position().focus == 'list' then
    self.scene:get('list'):focus()
  else
    self.scene:get('current'):focus()
  end

  -- After the focus change, which resets the diff to its first hunk
  if from_buffer then
    vim.schedule(function()
      if self._destroyed then return end
      self.diff_view:set_source_lnum(source_lnum, source_col, source_winline)
    end)
  end

  return true
end

-- The quit key, which screen_manager binds: quit once the keys pressed
-- before it have run. If the screen is destroyed first, the job is dropped
-- and this coroutine never resumes, which is fine since nothing waits on it.
function ProjectReviewScreen:on_quit()
  loop.suspend(function(done)
    self:enqueue(function()
      self:quit()
      done()
    end)
  end, 1)()
  return true
end

-- Close the screen, back onto the source file at the diff cursor's line
function ProjectReviewScreen:quit()
  local filepath = self.model:get_abs_filepath()
  local file_lnum, winline
  if self:focused_pane() == 'diff' then
    file_lnum = self.diff_view:get_file_lnum()
    winline = vim.fn.winline()
  end

  local source_win_id = self.source_win_id
  self:destroy()
  if not filepath or not fs.exists(filepath) then return end

  if source_win_id and vim.api.nvim_win_is_valid(source_win_id) then
    vim.api.nvim_set_current_win(source_win_id)
  end
  fs.open(filepath)

  if file_lnum then
    Window(0):set_lnum(file_lnum)
    local topline = file_lnum - winline + 1
    if topline >= 1 then vim.fn.winrestview({ topline = topline }) end
  end

  event.emit('VGitSync')
end

function ProjectReviewScreen:destroy()
  -- Quit paths can trigger destroy several times (on_quit, BufWinLeave,
  -- QuitPre); save and tear down only once.
  if self._destroyed then return end
  self._destroyed = true
  self._jobs = {}

  -- Save the position and marks, whichever way the screen closes
  local focus = self:focused_pane()
  local ok, err = pcall(function()
    local review_state = self.model:get_review_state()
    if not review_state then return end

    local entry = self.model:get_entry()
    if entry then
      review_state:set_position({
        type = entry.type,
        filepath = entry.filepath,
        commit_message = entry.commit and entry.commit.message,
        focus = focus,
      })
    end
    review_state:save()
  end)
  if not ok then
    console.warn(string.format('Failed to save review state: %s', tostring(err)))
  end

  if self._drag_detach then
    self._drag_detach()
    self._drag_detach = nil
  end
  if self._resize_autocmd then vim.api.nvim_del_autocmd(self._resize_autocmd) end
  self.scene:destroy()
end

return ProjectReviewScreen
