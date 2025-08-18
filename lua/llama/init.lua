-- llama.vim translated to lua for neovim
-- Author: Gemini
-- Date: 2025-08-18

local M = {}

-- State holds all the runtime variables for the plugin
local state = {
  enabled = true,
  current_job = nil,
  cache_data = {}, -- Maps hash -> response
  cache_lru_order = {}, -- List of keys for LRU eviction
  ring_chunks = {}, -- Active context chunks
  ring_queued = {}, -- Chunks waiting to be processed
  ring_n_evict = 0,
  ring_timer = nil, -- Timer for background context processing
  fim_data = {},
  hint_shown = false,
  t_last_move = nil,
  indent_last = -1,
  timer_fim = nil,
  vt_namespace_id = vim.api.nvim_create_namespace('vt_fim'),
}

-- Default configuration
local default_config = {
  endpoint = 'http://127.0.0.1:8012/infill',
  api_key = '',
  n_prefix = 256,
  n_suffix = 64,
  n_predict = 128,
  stop_strings = {},
  t_max_prompt_ms = 500,
  t_max_predict_ms = 1000,
  show_info = 2, -- 0: disabled, 1: statusline, 2: inline
  auto_fim = true,
  max_line_suffix = 8,
  max_cache_keys = 250,
  ring_n_chunks = 16,
  ring_chunk_size = 64,
  ring_scope = 1024,
  ring_update_ms = 1000,
  keymap_trigger = "<C-F>",
  keymap_accept_full = "<Tab>",
  keymap_accept_line = "<S-Tab>",
  keymap_accept_word = "<C-B>",
  hl_hint_group = "llama_hl_hint",
  hl_info_group = "llama_hl_info",
}

M.config = {}

--- Merges user configuration with defaults.
function M.setup(user_config)
  user_config = user_config or {}
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user_config)

  -- Setup Highlights
  vim.api.nvim_set_hl(0, M.config.hl_hint_group, { fg = '#ff772f', ctermfg = 202, default = true })
  vim.api.nvim_set_hl(0, M.config.hl_info_group, { fg = '#77ff2f', ctermfg = 119, default = true })

  -- Setup Commands
  vim.api.nvim_create_user_command('LlamaEnable', M.init, {})
  vim.api.nvim_create_user_command('LlamaDisable', M.disable, {})
  vim.api.nvim_create_user_command('LlamaToggle', M.toggle, {})

  M.init()
end

--------------------------------------------------------------------------------
-- Local Helper Functions
--------------------------------------------------------------------------------

local function cache_get(key)
  if not state.cache_data[key] then return nil end
  for i, k in ipairs(state.cache_lru_order) do
    if k == key then
      table.remove(state.cache_lru_order, i)
      break
    end
  end
  table.insert(state.cache_lru_order, key)
  return state.cache_data[key]
end

local function cache_insert(key, value)
  if #state.cache_lru_order >= M.config.max_cache_keys then
    local lru_key = table.remove(state.cache_lru_order, 1)
    state.cache_data[lru_key] = nil
  end
  for i, k in ipairs(state.cache_lru_order) do
    if k == key then
      table.remove(state.cache_lru_order, i)
      break
    end
  end
  state.cache_data[key] = value
  table.insert(state.cache_lru_order, key)
end

local function rand(i0, i1)
  return math.random(i0, i1)
end

--- Computes Jaccard similarity between two chunks of text (lists of strings).
-- 0 - no similarity, 1 - high similarity
local function chunk_sim(c0, c1)
  if #c0 == 0 and #c1 == 0 then return 1.0 end
  if #c0 == 0 or #c1 == 0 then return 0.0 end

  local set0 = {}
  for _, line in ipairs(c0) do set0[line] = true end
  local set1 = {}
  for _, line in ipairs(c1) do set1[line] = true end

  local common = 0
  local set0_size = 0
  for line, _ in pairs(set0) do
    if set1[line] then
      common = common + 1
    end
    set0_size = set0_size + 1
  end

  local set1_size = 0
  for _ in pairs(set1) do set1_size = set1_size + 1 end

  local union = set0_size + set1_size - common
  return union > 0 and (common / union) or 1.0
end

--- Picks a random chunk of text and queues it for processing.
-- @param text (table) List of strings to pick from.
-- @param no_mod (boolean) If true, don't pick from modified buffers.
-- @param do_evict (boolean) If true, evict similar chunks.
local function pick_chunk(text, no_mod, do_evict)
  if no_mod and (vim.bo.modified or not vim.fn.buflisted(0) or vim.fn.filereadable(vim.fn.expand('%')) == 0) then
    return
  end

  if M.config.ring_n_chunks <= 0 then return end
  if #text < 3 then return end

  local chunk
  if #text + 1 < M.config.ring_chunk_size then
    chunk = text
  else
    local text_len = #text
    local chunk_size = M.config.ring_chunk_size / 2
    local l0_start = 1
    local l0_end = math.max(1, text_len - chunk_size)
    local l0 = rand(l0_start, l0_end)
    local l1 = math.min(l0 + chunk_size, text_len)
    chunk = {}
    for i = l0, l1 do
        table.insert(chunk, text[i])
    end
  end

  local chunk_str = table.concat(chunk, "\n") .. "\n"

  -- check if this chunk is already added
  for _, c in ipairs(state.ring_chunks) do
    if vim.deep_equal(c.data, chunk) then return end
  end
  for _, c in ipairs(state.ring_queued) do
    if vim.deep_equal(c.data, chunk) then return end
  end

  -- evict queued chunks that are very similar to the new one
  for i = #state.ring_queued, 1, -1 do
    if chunk_sim(state.ring_queued[i].data, chunk) > 0.9 then
      if do_evict then
        table.remove(state.ring_queued, i)
        state.ring_n_evict = state.ring_n_evict + 1
      else
        return
      end
    end
  end

  -- also from s:ring_chunks
  for i = #state.ring_chunks, 1, -1 do
    if chunk_sim(state.ring_chunks[i].data, chunk) > 0.9 then
      if do_evict then
        table.remove(state.ring_chunks, i)
        state.ring_n_evict = state.ring_n_evict + 1
      else
        return
      end
    end
  end

  -- if the queue is full, remove the oldest item
  if #state.ring_queued >= 16 then
    table.remove(state.ring_queued, 1)
  end

  table.insert(state.ring_queued, {
    data = chunk,
    str = chunk_str,
    time = vim.fn.reltime(),
    filename = vim.fn.expand('%')
  })
end

local function ring_update()
  -- update only if in normal mode or if the cursor hasn't moved for a while
  if vim.fn.mode() ~= 'n' and state.t_last_move and vim.fn.reltimefloat(vim.fn.reltime(state.t_last_move)) < 3.0 then
    return
  end

  if #state.ring_queued == 0 then
    return
  end

  -- move the first queued chunk to the ring buffer
  if #state.ring_chunks >= M.config.ring_n_chunks and #state.ring_chunks > 0 then
    table.remove(state.ring_chunks, 1)
  end

  table.insert(state.ring_chunks, table.remove(state.ring_queued, 1))

  -- send asynchronous job with the new extra context so that it is ready for the next FIM
  local extra_context = {}
  for _, chunk in ipairs(state.ring_chunks) do
    table.insert(extra_context, {
      text = chunk.str,
      time = chunk.time,
      filename = chunk.filename,
    })
  end

  local request = vim.json.encode({
    input_prefix = "",
    input_suffix = "",
    input_extra = extra_context,
    prompt = "",
    n_predict = 0,
    temperature = 0.0,
    stream = false,
    samplers = {},
    cache_prompt = true,
    t_max_prompt_ms = 1,
    t_max_predict_ms = 1,
    response_fields = {""},
  })

  local curl_command = { "curl", "--silent", "--no-buffer", "--request", "POST", "--url", M.config.endpoint, "--header", "Content-Type: application/json", "--data", "@-" }
  if M.config.api_key and M.config.api_key ~= "" then
      table.insert(curl_command, "--header")
      table.insert(curl_command, "Authorization: Bearer " .. M.config.api_key)
  end

  -- no callbacks because we don't need to process the response
  local job_id = vim.fn.jobstart(curl_command)
  if job_id and job_id > 0 then
    vim.fn.chansend(job_id, request)
    vim.fn.chanclose(job_id, 'stdin')
  end
end

local function on_move()
  state.t_last_move = vim.fn.reltime()
  M.fim_hide()
  local pos = vim.api.nvim_win_get_cursor(0)
  M.fim_try_hint(pos[2], pos[1])
end

local function fim_on_exit(job_id, exit_code, event)
  if exit_code ~= 0 then
    vim.schedule(function()
      vim.notify("llama.nvim job failed with exit code: " .. exit_code, vim.log.levels.WARN)
    end)
  end
  state.current_job = nil
end

local function fim_on_response(hashes, job_id, data, event)
  local raw_data = table.concat(data, "\n")
  if raw_data == "" then return end
  if not (string.find(raw_data, "^%s*{") and string.find(raw_data, '"content"%s*:')) then return end

  local ok, _ = pcall(vim.json.decode, raw_data)
  if not ok then return end

  for _, hash in ipairs(hashes) do cache_insert(hash, raw_data) end

  if not state.hint_shown or not (state.fim_data and state.fim_data.can_accept) then
    vim.schedule(function()
      local pos = vim.api.nvim_win_get_cursor(0)
      M.fim_try_hint(pos[2], pos[1])
    end)
  end
end

--------------------------------------------------------------------------------
-- Public API Functions
--------------------------------------------------------------------------------

--- Hides the completion hint.
function M.fim_hide()
  if not state.hint_shown then return end
  state.hint_shown = false
  vim.api.nvim_buf_clear_namespace(vim.api.nvim_get_current_buf(), state.vt_namespace_id, 0, -1)
  pcall(vim.keymap.del, 'i', M.config.keymap_accept_full, { buffer = true })
  pcall(vim.keymap.del, 'i', M.config.keymap_accept_line, { buffer = true })
  pcall(vim.keymap.del, 'i', M.config.keymap_accept_word, { buffer = true })
end

local function pick_chunk_around_cursor()
  local half_chunk = M.config.ring_chunk_size / 2
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local last_line = vim.api.nvim_buf_line_count(0)
  local start_line = math.max(1, cur_line - half_chunk)
  local end_line = math.min(last_line, cur_line + half_chunk)
  -- Get lines from current buffer (0)
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  pick_chunk(lines, true, true)
end

--- Initializes the plugin.
function M.init()
  if vim.fn.executable('curl') == 0 then
    vim.notify('llama.nvim requires "curl" to be available', vim.log.levels.ERROR)
    return
  end
  state.t_last_move = vim.fn.reltime()
  local augroup = vim.api.nvim_create_augroup("Llama", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup, pattern = "*",
    callback = function()
      vim.keymap.set('i', M.config.keymap_trigger, function() return M.fim_inline(false, false) end, { expr = true, silent = true, buffer = true })
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeavePre", { group = augroup, pattern = "*", callback = M.fim_hide })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = augroup, pattern = "*", callback = on_move })
  vim.api.nvim_create_autocmd({ "CompleteChanged", "CompleteDone" }, { group = augroup, pattern = "*", callback = M.fim_hide })

  if M.config.auto_fim then
    vim.api.nvim_create_autocmd("CursorMovedI", { group = augroup, pattern = "*",
      callback = function() M.fim(-1, -1, true, {}, true) end
    })
  end

  -- gather chunks upon yanking
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = augroup, pattern = "*",
    callback = function(ev)
      if ev.operator == 'y' then
        pick_chunk(ev.regcontents, false, true)
      end
    end,
  })

  -- gather chunks upon entering/leaving a buffer and saving
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup, pattern = "*",
    callback = function() vim.defer_fn(pick_chunk_around_cursor, 100) end,
  })
  vim.api.nvim_create_autocmd({"BufLeave", "BufWritePost"}, {
    group = augroup, pattern = "*",
    callback = pick_chunk_around_cursor,
  })


  if M.config.ring_n_chunks > 0 and not state.ring_timer then
    state.ring_timer = vim.loop.new_timer()
    state.ring_timer:start(100, M.config.ring_update_ms, vim.schedule_wrap(ring_update))
  end

  state.enabled = true
end

--- Disables the plugin.
function M.disable()
  M.fim_hide()
  vim.api.nvim_clear_autocmds({ group = "Llama" })
  pcall(vim.keymap.del, 'i', M.config.keymap_trigger)

  if state.ring_timer then
    state.ring_timer:stop()
    state.ring_timer:close()
    state.ring_timer = nil
  end

  state.enabled = false
end

function M.toggle() if state.enabled then M.disable() else M.init() end end

function M.fim_inline(is_auto, use_cache)
  if state.hint_shown and not is_auto then M.fim_hide() return '' end
  M.fim(-1, -1, is_auto, {}, use_cache)
  return ''
end

--- Main FIM call to the server.
function M.fim(pos_x, pos_y, is_auto, prev, use_cache)
    if pos_x < 0 then pos_x = vim.api.nvim_win_get_cursor(0)[2] end
    if pos_y < 0 then pos_y = vim.api.nvim_win_get_cursor(0)[1] end

    if state.current_job then
        if state.timer_fim then state.timer_fim:stop() end
        state.timer_fim = vim.defer_fn(function() M.fim(pos_x, pos_y, is_auto, prev, use_cache) end, 100)
        return
    end

    local ctx_local = M.fim_ctx_local(pos_x, pos_y, prev)
    if is_auto and #ctx_local.line_cur_suffix > M.config.max_line_suffix then return end

    -- Evict chunks from ring buffer that are too similar to the current context
    if M.config.ring_n_chunks > 0 then
      local half_chunk = M.config.ring_chunk_size / 2
      local last_line = vim.api.nvim_buf_line_count(0)
      local start_line = math.max(1, pos_y - half_chunk)
      local end_line = math.min(last_line, pos_y + half_chunk)
      local current_chunk_data = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

      for i = #state.ring_chunks, 1, -1 do
        if chunk_sim(state.ring_chunks[i].data, current_chunk_data) > 0.5 then
          table.remove(state.ring_chunks, i)
          state.ring_n_evict = state.ring_n_evict + 1
        end
      end
    end

    local hashes = { vim.fn.sha256(ctx_local.prefix .. ctx_local.middle .. 'Î' .. ctx_local.suffix) }
    local prefix_trim = ctx_local.prefix
    for _ = 1, 3 do
        prefix_trim = string.gsub(prefix_trim, '^[^\n]*\n', '', 1)
        if prefix_trim == "" then break end
        table.insert(hashes, vim.fn.sha256(prefix_trim .. ctx_local.middle .. 'Î' .. ctx_local.suffix))
    end

    if use_cache then
        for _, hash in ipairs(hashes) do if cache_get(hash) ~= nil then return end end
    end

    state.indent_last = ctx_local.indent

    -- Prepare extra context for the request
    local extra_context = {}
    if M.config.ring_n_chunks > 0 then
      for _, chunk in ipairs(state.ring_chunks) do
        table.insert(extra_context, {
          text = chunk.str,
          time = chunk.time,
          filename = chunk.filename,
        })
      end
    end

    local request = vim.json.encode({
        input_prefix = ctx_local.prefix, input_suffix = ctx_local.suffix, input_extra = extra_context,
        prompt = ctx_local.middle, n_predict = M.config.n_predict, stop = M.config.stop_strings,
        n_indent = ctx_local.indent, stream = false, samplers = {"top_k", "top_p", "infill"},
        cache_prompt = true, t_max_prompt_ms = M.config.t_max_prompt_ms,
        t_max_predict_ms = (#(prev or {}) == 0) and 250 or M.config.t_max_predict_ms,
        response_fields = {"content", "timings/prompt_n", "timings/prompt_ms", "timings/prompt_per_second", "timings/predicted_n", "timings/predicted_ms", "timings/predicted_per_second", "truncated", "tokens_cached"},
    })
    local curl_command = { "curl", "--silent", "--no-buffer", "--request", "POST", "--url", M.config.endpoint, "--header", "Content-Type: application/json", "--data", "@-" }
    if M.config.api_key and M.config.api_key ~= "" then
        table.insert(curl_command, "--header")
        table.insert(curl_command, "Authorization: Bearer " .. M.config.api_key)
    end

    if state.current_job then vim.fn.jobstop(state.current_job) end
    state.current_job = vim.fn.jobstart(curl_command, {
        on_stdout = function(...) fim_on_response(hashes, ...) end,
        on_exit = fim_on_exit, stdout_buffered = true,
    })
    vim.fn.chansend(state.current_job, request)
    vim.fn.chanclose(state.current_job, 'stdin')

    -- Gather more context on large cursor movements
    if M.config.ring_n_chunks > 0 and is_auto then
      if not vim.b.llama_last_pick_pos then
        vim.b.llama_last_pick_pos = pos_y
      end

      local delta_y = math.abs(pos_y - vim.b.llama_last_pick_pos)
      if delta_y > 32 then
        local max_y = vim.api.nvim_buf_line_count(0)
        -- expand the prefix even further
        local prefix_start = math.max(1, pos_y - M.config.ring_scope)
        local prefix_end = math.max(1, pos_y - M.config.n_prefix)
        if prefix_end > prefix_start then
          pick_chunk(vim.api.nvim_buf_get_lines(0, prefix_start - 1, prefix_end, false), false, false)
        end

        -- pick a suffix chunk
        local suffix_start = math.min(max_y, pos_y + M.config.n_suffix)
        local suffix_end = math.min(max_y, suffix_start + M.config.ring_chunk_size)
        if suffix_end > suffix_start then
          pick_chunk(vim.api.nvim_buf_get_lines(0, suffix_start - 1, suffix_end, false), false, false)
        end

        vim.b.llama_last_pick_pos = pos_y
      end
    end
end

--- Gathers local context around cursor.
function M.fim_ctx_local(pos_x, pos_y, prev)
    local bufnr = vim.api.nvim_get_current_buf()
    local max_y = vim.api.nvim_buf_line_count(bufnr)
    local line_cur, line_cur_prefix, line_cur_suffix, indent, lines_prefix, lines_suffix

    if not prev or #prev == 0 then
        -- Standard context gathering when there's no previous suggestion
        line_cur = vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)[1] or ""
        if line_cur:match('^%s*$') then
            line_cur_prefix, line_cur_suffix, indent = "", "", 0
        else
            line_cur_prefix = vim.fn.strpart(line_cur, 0, pos_x)
            line_cur_suffix = vim.fn.strpart(line_cur, pos_x)
            indent = #(line_cur:match('^%s*'))
        end
        lines_prefix = vim.api.nvim_buf_get_lines(bufnr, math.max(1, pos_y - M.config.n_prefix) - 1, pos_y - 1, false)
        lines_suffix = vim.api.nvim_buf_get_lines(bufnr, pos_y, math.min(max_y, pos_y + M.config.n_suffix), false)
    else
        -- Context gathering for speculative completion (with a previous suggestion)
        if #prev == 1 then
            line_cur = (vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)[1] or "") .. prev[1]
        else
            line_cur = prev[#prev]
        end

        line_cur_prefix = line_cur
        line_cur_suffix = ""

        lines_prefix = vim.api.nvim_buf_get_lines(bufnr, math.max(1, pos_y - M.config.n_prefix + #prev - 1) - 1, pos_y - 1, false)
        if #prev > 1 then
            table.insert(lines_prefix, (vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)[1] or "") .. prev[1])
            for i = 2, #prev - 1 do
                table.insert(lines_prefix, prev[i])
            end
        end

        lines_suffix = vim.api.nvim_buf_get_lines(bufnr, pos_y + 1, math.min(max_y, pos_y + M.config.n_suffix), false)
        indent = state.indent_last
    end

    return {
        prefix = table.concat(lines_prefix, "\n") .. "\n",
        middle = line_cur_prefix,
        suffix = line_cur_suffix .. "\n" .. table.concat(lines_suffix, "\n") .. "\n",
        indent = indent,
        line_cur = line_cur,
        line_cur_prefix = line_cur_prefix,
        line_cur_suffix = line_cur_suffix,
    }
end

--- Tries to find and show a hint from cache.
function M.fim_try_hint(pos_x, pos_y)
    if not vim.tbl_contains({'i', 'ic', 'ix'}, vim.fn.mode()) then return end
    local ctx = M.fim_ctx_local(pos_x, pos_y, {})
    local hash = vim.fn.sha256(ctx.prefix .. ctx.middle .. 'Î' .. ctx.suffix)
    local raw_response = cache_get(hash)

    if not raw_response then
        local pm = ctx.prefix .. ctx.middle
        for i = 1, 128 do
            if i+1 > #pm then break end
            local new_ctx_str = pm:sub(1, #pm - (i + 1)) .. 'Î' .. ctx.suffix
            local cached_resp = cache_get(vim.fn.sha256(new_ctx_str))
            if cached_resp then
                local ok, r = pcall(vim.json.decode, cached_resp)
                if ok and r.content and r.content:sub(1, i+1) == pm:sub(-(i + 1)) then
                    r.content = r.content:sub(i + 2)
                    if #r.content > 0 then raw_response = vim.json.encode(r) break end
                end
            end
        end
    end

    if raw_response then
        M.fim_render(pos_x, pos_y, raw_response)
        if state.hint_shown then M.fim(pos_x, pos_y, true, state.fim_data.content, true) end
    end
end

--- Renders the suggestion with deduplication and info.
function M.fim_render(pos_x, pos_y, data)
  if vim.fn.pumvisible() == 1 then return end

  local ok, response = pcall(vim.json.decode, data)
  if not ok or not response.content or response.content == "" then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local line_cur = vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)[1]
  local line_cur_suffix = line_cur:sub(pos_x + 1)

  local content_lines = vim.split(response.content, "\n", { trimempty = false })
  while #content_lines > 0 and content_lines[#content_lines] == "" do table.remove(content_lines) end
  if #content_lines == 0 then return end

  -- ### Deduplication Logic ###
  if #content_lines == 1 and (content_lines[1] == "" or content_lines[1] == line_cur_suffix) then return end
  if #content_lines > 1 and content_lines[1] == "" then
      local existing = vim.api.nvim_buf_get_lines(bufnr, pos_y, pos_y + #content_lines - 2, false)
      local suggestion_rest = {}
      for i = 2, #content_lines do table.insert(suggestion_rest, content_lines[i]) end
      if vim.deep_equal(suggestion_rest, existing) then return end
  end

  -- ### Info String Logic (Corrected) ###
  local info_string = ''
  if M.config.show_info > 0 and response["timings/prompt_n"] then
      local prefix = (M.config.show_info == 2) and '   ' or 'llama.nvim'
      info_string = string.format(
          "%s | c: %d, r: %d/%d, e: %d, q: %d/16, C: %d/%d | p: %d (%.2fms, %.2f t/s) | g: %d (%.2fms, %.2f t/s)",
          prefix,
          response.tokens_cached or 0,
          #state.ring_chunks, M.config.ring_n_chunks,
          state.ring_n_evict, #state.ring_queued,
          #state.cache_lru_order, M.config.max_cache_keys,
          response["timings/prompt_n"] or 0,
          response["timings/prompt_ms"] or 0.0,
          response["timings/prompt_per_second"] or 0.0,
          response["timings/predicted_n"] or 0,
          response["timings/predicted_ms"] or 0.0,
          response["timings/predicted_per_second"] or 0.0
      )
  end
  if M.config.show_info == 1 and info_string ~= '' then vim.o.statusline = info_string end

  -- ### Display Logic ###
  local virt_text = { { content_lines[1], M.config.hl_hint_group } }
  if M.config.show_info == 2 and info_string ~= '' then table.insert(virt_text, { info_string, M.config.hl_info_group }) end

  vim.api.nvim_buf_set_extmark(bufnr, state.vt_namespace_id, pos_y - 1, pos_x, { virt_text = virt_text, virt_text_pos = 'overlay' })

  if #content_lines > 1 then
      local virt_lines = {}
      for i = 2, #content_lines do table.insert(virt_lines, { { content_lines[i], M.config.hl_hint_group } }) end
      vim.api.nvim_buf_set_extmark(bufnr, state.vt_namespace_id, pos_y - 1, 0, { virt_lines = virt_lines })
  end

  state.hint_shown = true
  state.fim_data = { pos_x = pos_x, pos_y = pos_y, line_cur = line_cur, can_accept = true, content = content_lines }

  vim.keymap.set('i', M.config.keymap_accept_full, function() M.fim_accept('full') end, { buffer = true, silent = true })
  vim.keymap.set('i', M.config.keymap_accept_line, function() M.fim_accept('line') end, { buffer = true, silent = true })
  vim.keymap.set('i', M.config.keymap_accept_word, function() M.fim_accept('word') end, { buffer = true, silent = true })
end

--- Accepts the current suggestion.
function M.fim_accept(accept_type)
    if not (state.fim_data.can_accept and state.fim_data.content and #state.fim_data.content > 0) then M.fim_hide() return end
    local d = state.fim_data
    local bufnr = vim.api.nvim_get_current_buf()
    local first_line = (accept_type == 'word') and (d.content[1]:match("^%s*[%S]+") or "") or d.content[1]
    vim.api.nvim_buf_set_lines(bufnr, d.pos_y - 1, d.pos_y, true, { d.line_cur:sub(1, d.pos_x) .. first_line })
    if accept_type == 'full' and #d.content > 1 then
        local rest = {}
        for i = 2, #d.content do table.insert(rest, d.content[i]) end
        vim.api.nvim_buf_set_lines(bufnr, d.pos_y, d.pos_y, true, rest)
    end
    local cur_y, cur_x
    if accept_type == 'word' then
        cur_y, cur_x = d.pos_y, d.pos_x + #first_line
    elseif accept_type == 'line' or #d.content == 1 then
        cur_y, cur_x = d.pos_y, d.pos_x + #first_line
    else
        cur_y = d.pos_y + #d.content - 1
        cur_x = #d.content[#d.content]
    end
    vim.api.nvim_win_set_cursor(0, { cur_y, cur_x })
    M.fim_hide()
end

return M
