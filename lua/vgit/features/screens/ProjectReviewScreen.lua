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
local section_headings = require('vgit.ui.views.StatusListView.section_headings')
local file_navigation = require('vgit.features.screens.file_navigation')
local visual_selection = require('vgit.features.screens.visual_selection')

--[[
  ProjectReviewScreen is the base class for the review screens
  (ProjectReviewByFileScreen and ProjectReviewByCommitScreen). Marks are edits
  to an approved content snapshot (see ReviewModel), so hunk
  indices in a section shift as hunks are marked, and s/u also work on visual
  selections (line-level marking, current pane only in split layout).

  Every motion picks a target entry id, then select(id) reveals its list row
  (expanding its commit and folders) and shows it in the diff. Navigation
  order is the list's fold tree, collapsed folds included, so it always
  follows the display.

  Keys run as jobs through one queue (see enqueue).

  Subclasses set model, setting and list_view, then call init_views. They may
  override jump_section (J/K in the list) and resolve_list_width.
]]

local ProjectReviewScreen = Object:extend()

function ProjectReviewScreen:constructor()
  return {
    name = 'Project Review Screen',
    scene = Scene(),
    app_bar_view = nil,
    diff_view = nil,
    -- Set by the by-commit subclass in left/right layouts
    commit_message_view = nil,
    -- List column width while the list/diff boundary is draggable
    list_cols = nil,
    source_win_id = nil,
    -- Keypress jobs not yet run, and whether the runner is draining them
    _jobs = {},
    _running = false,
    _drag_detach = nil,
    _destroyed = false,
  }
end

-- Initialize views (called by subclass after setting model and setting)
function ProjectReviewScreen:init_views(diff_plot)
  local model = self.model
  local setting = self.setting

  self.app_bar_view = KeyHelpBarView(self.scene, {
    keymaps = function()
      local keymaps = setting:get('keymaps')
      return {
        { 'Mark hunk/lines',   keymaps['mark_hunk'] },
        { 'Mark file',         keymaps['mark_file'] },
        { 'Unmark hunk/lines', keymaps['unmark_hunk'] },
        { 'Unmark file',       keymaps['unmark_file'] },
        { 'Reset',             keymaps['reset'] },
        { 'Next',              keymaps['next'] },
        { 'Previous',          keymaps['previous'] },
        { 'Jump section',      keymaps['jump_section_next'] },
      }
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
  }, diff_plot, {
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

-- Index into `files` of the entry shown in the diff
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

-- J/K in the list: jump between crate-level folder headings (see
-- vgit.ui.views.StatusListView.section_headings for the rule). Wraps.
function ProjectReviewScreen:jump_section(direction)
  local component = self.list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()
  local delta = direction == 'next' and 1 or -1
  local headings = section_headings(self.list_view.state.folds)

  for offset = 1, count do
    local target_lnum = ((current_lnum - 1 + offset * delta) % count) + 1
    if headings[self.list_view:get_list_item(target_lnum)] then return self.list_view:set_lnum(target_lnum) end
  end
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
  -- Marking may have loaded contents through git
  loop.free_textlock()
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

  -- Where the marked region begins, in new-side lines: the top of the last
  -- selection's hunk (the bottom of a visual range)
  local from_top = 0
  local last = selections and selections[#selections]
  local diff = last and self.diff_view:get_diff()
  local mark = diff and diff.marks[last.index]
  if mark then from_top = mark.top_relative end

  local next_id = file_navigation.next_of_type(self.list_view:file_nodes(), entry.id, entry.type)
  self:apply_mark(entry, mark_as_seen, selections)

  local remaining = self.model:lookup(entry.id)
  if remaining then
    diff = self.model:get_diff_for(remaining)
    loop.free_textlock()
    local hunk = diff and file_navigation.hunk_past_position(diff.marks, from_top)
    if hunk and self:select(entry.id, hunk) then return end
  end
  if self:select(next_id, 1) or self:select(remaining and entry.id, 1) then return end
  self:select(self.model:sibling_id(entry), 1)
end

-- s/u act only on the section their hunks come from. `selections` is a
-- visual range's, else the hunk under the cursor; a hunkless diff (a marked
-- pure rename) has none and marks the whole file.
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
  loop.free_textlock()
  self.list_view:render()

  -- Everything is unseen again: stay on this file
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

-- CursorMoved in the list. Moves while a job runs are that job's own.
function ProjectReviewScreen:handle_list_move()
  if self._running then return end
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
  if self._destroyed then return end
  self._jobs[#self._jobs + 1] = { fn = fn, args = { n = select('#', ...), ... } }
  if self._running then return end

  self._running = true
  loop.coroutine(function()
    while #self._jobs > 0 and not self._destroyed do
      local job = table.remove(self._jobs, 1)
      local ok, err = pcall(job.fn, unpack(job.args, 1, job.args.n))
      -- A job cut short by destroy() fails on the closed windows
      if not ok and not self._destroyed then console.error(tostring(err)) end
    end
    self._jobs = {}
    self._running = false
  end)()
end

function ProjectReviewScreen:setup_keymaps()
  local keymaps = self.setting:get('keymaps')
  local function job(fn)
    return function(...)
      self:enqueue(fn, ...)
    end
  end

  local toggle_focus = job(function() self:toggle_focus() end)
  local mark_file = job(function() self:mark(true) end)
  local unmark_file = job(function() self:mark(false) end)
  local reset = job(function() self:reset_marks() end)

  self.list_view:set_keymap({
    { mode = 'n', mapping = keymaps.toggle_focus, handler = toggle_focus },
    -- `mark_hunk` (`s`) has no target in the list pane, so bind it to an explicit
    -- no-op to keep it from falling through to a global mapping.
    {
      mode = 'n',
      mapping = { key = keymaps.mark_hunk.key, desc = 'No-op (mark hunk is diff-pane only)' },
      handler = function() end,
    },
    { mode = 'n', mapping = keymaps.mark_file, handler = mark_file },
    { mode = 'n', mapping = keymaps.unmark_file, handler = unmark_file },
    { mode = 'n', mapping = keymaps.reset, handler = reset },
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
    { mode = 'n', mapping = keymaps.mark_hunk, handler = job(function() self:mark_hunk(true) end) },
    { mode = 'n', mapping = keymaps.unmark_hunk, handler = job(function() self:mark_hunk(false) end) },
    { mode = 'n', mapping = keymaps.mark_file, handler = mark_file },
    { mode = 'n', mapping = keymaps.unmark_file, handler = unmark_file },
    { mode = 'n', mapping = keymaps.reset, handler = reset },
    { mode = 'n', mapping = keymaps.toggle_focus, handler = toggle_focus },
    { mode = 'n', mapping = keymaps.next, handler = job(function() self:step_hunk('next') end) },
    { mode = 'n', mapping = keymaps.previous, handler = job(function() self:step_hunk('prev') end) },
    -- In the diff pane, J/K jump to the last/first hunk in the current file,
    -- then cross into the next/prev FILE once already on that hunk (not the
    -- list's section headers, which only make sense in the list pane). Wraps.
    { mode = 'n', mapping = keymaps.jump_section_next, handler = job(function() self:jump_to_file_edge('next') end) },
    { mode = 'n', mapping = keymaps.jump_section_prev, handler = job(function() self:jump_to_file_edge('prev') end) },
    {
      mode = 'n',
      mapping = { key = '<enter>', desc = 'Open buffer' },
      handler = job(function() self:open_file() end),
    },
  })

  self:setup_visual_keymaps(keymaps, job)
end

-- Visual-mode s/u: line-level marking. The selection endpoints must be read
-- while still in visual mode, so the handlers capture them before
-- enqueueing. In split layout only the current (right) pane accepts
-- selections; the previous pane notifies instead (its rows show old
-- content, and every change is addressable from the current pane).
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

-- By-commit sizes the list column to the fetched commits
function ProjectReviewScreen:resolve_list_width() end

-- Reconfigure all width-dependent windows for a new list column width
-- (mouse drag on the list/diff boundary, left-list layout only). Cheap:
-- window re-plots only; content re-renders once on release.
function ProjectReviewScreen:apply_list_width(cols)
  local total = dimensions.global_width()
  cols = math.max(20, math.min(cols, total - 40))
  if cols == self.list_cols then return end
  self.list_cols = cols

  local function replot(window, col, width)
    local win_id = window and window.win_id
    if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
    local row = vim.api.nvim_win_get_config(win_id).row
    vim.api.nvim_win_set_config(win_id, { relative = 'editor', row = row, col = col, width = width })
  end

  local function replot_component(component, col, width)
    if not component then return end
    replot(component.window, col, width)
    local header = component.elements and component.elements.header
    if header then replot(header.window, col, width) end
  end

  replot_component(self.scene:get('list'), 0, cols)

  if self.commit_message_view then
    -- Future CommitMessageView:resize() calls re-derive geometry from the plot
    self.commit_message_view.plot.width = cols
    replot_component(self.scene:get('commit_message'), 0, cols)
  end

  local rest = total - cols
  if self.model:get_layout_type() == 'split' then
    local half = math.ceil(rest / 2)
    replot_component(self.scene:get('previous'), cols, half)
    replot_component(self.scene:get('current'), cols + half, rest - half)
  else
    replot_component(self.scene:get('current'), cols, rest)
  end
end

-- Re-render width-dependent content (void filler, message wrap height) after
-- a drag completes, and remember the width for screens opened later this
-- session.
function ProjectReviewScreen:finish_list_resize()
  self.setting:set('list_width', self.list_cols)

  self.diff_view:save_viewport()
  self.diff_view:render()

  if self.commit_message_view then
    self.commit_message_view.current_height = nil
    self.commit_message_view:render()
  end
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
-- hold the line (the latest is closest to the working copy), else the latest
-- unseen one, else the latest seen one.
function ProjectReviewScreen:source_entry_id(filepath, lnum)
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
      loop.free_textlock()
      for _, mark in ipairs(diff and diff.marks or {}) do
        if lnum >= mark.top_relative and lnum <= mark.bot_relative then return entry.id end
      end
    end
  end
  return unseen or seen
end

-- Entry to open on, and whether it is the source buffer's file: that file
-- (see source_entry_id), else the saved position (preferring its section
-- and commit), else the first unseen entry
function ProjectReviewScreen:initial_entry_id(buffer, lnum)
  -- Entries are repo-relative, whatever the cwd
  local name = buffer:get_name()
  local source_id = name ~= '' and self:source_entry_id(fs.make_relative(self.model:get_reponame(), name), lnum)
  if source_id then return source_id, true end

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
  local saved_id = filepath
    and (find(function(entry)
      return in_section(entry) and (not entry.commit or entry.commit.message == position.commit_message)
    end) or find(in_section) or find(function() return true end))
  return saved_id or self:first_entry_id(), false
end

function ProjectReviewScreen:create(args)
  local base_branch = (args or {})[1]
  local buffer = Buffer(0)
  -- Capture the source position before mounting any views
  local source_lnum, source_col, source_winline = vim.fn.line('.'), vim.fn.col('.'), vim.fn.winline()
  self.source_win_id = vim.api.nvim_get_current_win()

  local data, err = self.model:fetch(base_branch)
  loop.free_textlock()

  if err then
    console.debug.error(err).error(err)
    return false
  end

  if utils.object.is_empty(data) then
    console.info('No changes to review')
    return false
  end

  self:resolve_list_width()

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
-- and this coroutine never resumes; nothing waits on it.
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
  self.scene:destroy()
end

return ProjectReviewScreen
