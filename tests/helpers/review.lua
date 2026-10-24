local loop = require('vgit.core.loop')

local review = {}

-- Point XDG_DATA_HOME and XDG_STATE_HOME at fresh temp dirs, so nothing
-- touches the real ones. Returns the dirs ({ data, state }) and a function
-- that restores both variables and deletes the dirs.
function review.enter_temp_homes()
  local homes, saved = { data = vim.fn.tempname(), state = vim.fn.tempname() }, {}
  for _, name in ipairs({ 'XDG_DATA_HOME', 'XDG_STATE_HOME' }) do
    saved[name] = vim.env[name]
  end
  vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = homes.data, homes.state

  return homes, function()
    vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = saved.XDG_DATA_HOME, saved.XDG_STATE_HOME
    vim.fn.delete(homes.data, 'rf')
    vim.fn.delete(homes.state, 'rf')
  end
end

-- Temp XDG homes (see enter_temp_homes) around each spec of the enclosing
-- describe, restored even when an assertion fails. Returns a table holding
-- the current spec's `data` and `state` dirs.
function review.use_temp_homes()
  local homes, restore = {}, nil
  before_each(function()
    local dirs
    dirs, restore = review.enter_temp_homes()
    homes.data, homes.state = dirs.data, dirs.state
  end)
  after_each(function() restore() end)
  return homes
end

-- Save and load yield through free_textlock, so run `fn` in a vgit coroutine
-- and block until it finishes.
function review.run(fn)
  local done, ok, err = false, true, nil
  loop.coroutine(function()
    ok, err = pcall(fn)
    done = true
  end)()
  assert(vim.wait(5000, function() return done end, 10), 'coroutine did not finish')
  assert(ok, err)
end

-- A deterministic random integer generator: rand(n) is in 1..n. An LCG's
-- low bits cycle quickly, so this takes the high ones.
function review.random(seed)
  return function(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return math.floor(seed / 65536) % n + 1
  end
end

-- A ReviewState class with an empty session store, as in a new nvim session
function review.fresh_review_state()
  package.loaded['vgit.features.screens.ReviewState'] = nil
  return require('vgit.features.screens.ReviewState')
end

return review
