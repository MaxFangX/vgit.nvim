local loop = require('vgit.core.loop')

local review = {}

-- Points XDG_DATA_HOME at a fresh temp dir around each spec of the enclosing
-- describe, restored (and the dir deleted) even when an assertion fails.
-- Returns a table whose `root` is the current spec's data home.
function review.use_temp_data_home()
  local data_home, saved = {}, nil
  before_each(function()
    saved = vim.env.XDG_DATA_HOME
    data_home.root = vim.fn.tempname()
    vim.env.XDG_DATA_HOME = data_home.root
  end)
  after_each(function()
    vim.env.XDG_DATA_HOME = saved
    vim.fn.delete(data_home.root, 'rf')
  end)
  return data_home
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
