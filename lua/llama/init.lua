-- llama.vim translated to lua for neovim
-- Author: Gemini
-- fixed by Dimitar Atanassov
-- Date: 2025-08-18

-- Module definition
local Llama = {}
local H = {}
local Job = require("plenary.job")

-- Helper data - moved from state to H
H.enabled = true
H.current_job = nil
H.cache_data = {} -- Maps hash -> response
H.cache_lru_order = {} -- List of keys for LRU eviction (renamed from cache_order)
H.ring_chunks = {} -- Active context chunks
H.ring_queued = {} -- Chunks waiting to be processed
H.ring_n_evict = 0
H.ring_timer = nil -- Timer for background context processing
H.fim_data = {}
H.hint_shown = false
H.t_last_move = nil
H.indent_last = -1
H.timer_fim = nil
H.vt_namespace_id = vim.api.nvim_create_namespace("vt_fim")

-- Structured configuration (from backup pattern)
Llama.config = {
    options = {
        endpoint = "http://127.0.0.1:8012/infill",
        api_key = "",
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
        ring_max_queued_chunks = 16,
        ring_chunk_similarity_threshold = 0.9,
        ring_eviction_similarity_threshold = 0.5,
        ring_update_idle_s = 3.0,
        fim_debounce_ms = 100,
        fim_large_move_line_threshold = 32,
    },
    mappings = {
        keymap_trigger = "<C-F>",
        keymap_accept_full = "<Tab>",
        keymap_accept_line = "<S-Tab>",
        keymap_accept_word = "<C-B>",
    },
    highlight = {
        hl_hint_group = "llama_hl_hint",
        hl_info_group = "llama_hl_info",
    },
}

-- Default configuration
H.default_config = vim.deepcopy(Llama.config)

--- Merges user configuration with defaults.
Llama.setup = function(user_config)
    _G.Llama = Llama

    user_config = H.setup_config(user_config)

    H.apply_config(user_config)

    Llama.init()
end

H.setup_config = function(config)
    H.check_type("config", config, "table", true)
    config = vim.tbl_deep_extend("force", vim.deepcopy(H.default_config), config)

    H.check_type("options", config.options, "table")
    H.check_type("options.endpoint", config.options.endpoint, "string")
    H.check_type("options.api_key", config.options.api_key, "string")
    H.check_type("options.n_prefix", config.options.n_prefix, "number")
    H.check_type("options.n_suffix", config.options.n_suffix, "number")
    H.check_type("options.n_predict", config.options.n_predict, "number")
    H.check_type("options.stop_strings", config.options.stop_strings, "table")
    H.check_type("options.t_max_prompt_ms", config.options.t_max_prompt_ms, "number")
    H.check_type("options.t_max_predict_ms", config.options.t_max_predict_ms, "number")
    H.check_type("options.show_info", config.options.show_info, "number")
    H.check_type("options.auto_fim", config.options.auto_fim, "boolean")
    H.check_type("options.max_line_suffix", config.options.max_line_suffix, "number")
    H.check_type("options.max_cache_keys", config.options.max_cache_keys, "number")
    H.check_type("options.ring_n_chunks", config.options.ring_n_chunks, "number")
    H.check_type("options.ring_chunk_size", config.options.ring_chunk_size, "number")
    H.check_type("options.ring_scope", config.options.ring_scope, "number")
    H.check_type("options.ring_update_ms", config.options.ring_update_ms, "number")
    H.check_type("options.ring_max_queued_chunks", config.options.ring_max_queued_chunks, "number")
    H.check_type("options.ring_chunk_similarity_threshold", config.options.ring_chunk_similarity_threshold, "number")
    H.check_type(
        "options.ring_eviction_similarity_threshold",
        config.options.ring_eviction_similarity_threshold,
        "number"
    )
    H.check_type("options.ring_update_idle_s", config.options.ring_update_idle_s, "number")
    H.check_type("options.fim_debounce_ms", config.options.fim_debounce_ms, "number")
    H.check_type("options.fim_large_move_line_threshold", config.options.fim_large_move_line_threshold, "number")

    H.check_type("mappings", config.mappings, "table")
    H.check_type("mappings.keymap_trigger", config.mappings.keymap_trigger, "string")
    H.check_type("mappings.keymap_accept_full", config.mappings.keymap_accept_full, "string")
    H.check_type("mappings.keymap_accept_line", config.mappings.keymap_accept_line, "string")
    H.check_type("mappings.keymap_accept_word", config.mappings.keymap_accept_word, "string")

    return config
end

H.apply_config = function(config)
    Llama.config = config

    -- Setup Highlights
    vim.api.nvim_set_hl(0, Llama.config.highlight.hl_hint_group, { fg = "#ff772f", ctermfg = 202 })
    vim.api.nvim_set_hl(0, Llama.config.highlight.hl_info_group, { fg = "#77ff2f", ctermfg = 119 })

    -- Setup Commands
    vim.api.nvim_create_user_command("LlamaEnable", Llama.init, {})
    vim.api.nvim_create_user_command("LlamaDisable", Llama.disable, {})
    vim.api.nvim_create_user_command("LlamaToggle", Llama.toggle, {})
end

--------------------------------------------------------------------------------
-- Local Helper Functions
--------------------------------------------------------------------------------

H.error = function(msg)
    error("(llama.nvim) " .. msg, 0)
end

H.check_type = function(name, val, ref, allow_nil)
    if type(val) == ref or (ref == "callable" and vim.is_callable(val)) or (allow_nil and val == nil) then
        return
    end
    H.error(string.format("`%s` should be %s, not %s", name, ref, type(val)))
end

H.map = function(mode, lhs, rhs, opts)
    if lhs == "" then
        return
    end
    opts = vim.tbl_deep_extend("force", { silent = true }, opts or {})
    vim.keymap.set(mode, lhs, rhs, opts)
end

H.cache_get = function(key)
    if not H.cache_data[key] then
        return nil
    end
    for i, k in ipairs(H.cache_lru_order) do
        if k == key then
            table.remove(H.cache_lru_order, i)
            break
        end
    end
    table.insert(H.cache_lru_order, key)
    return H.cache_data[key]
end

H.cache_insert = function(key, value)
    if #H.cache_lru_order >= Llama.config.options.max_cache_keys then
        local lru_key = table.remove(H.cache_lru_order, 1)
        H.cache_data[lru_key] = nil
    end
    for i, k in ipairs(H.cache_lru_order) do
        if k == key then
            table.remove(H.cache_lru_order, i)
            break
        end
    end
    H.cache_data[key] = value
    table.insert(H.cache_lru_order, key)
end

H.rand = function(i0, i1)
    return math.random(i0, i1)
end

--- Computes Jaccard similarity between two chunks of text (lists of strings).
-- 0 - no similarity, 1 - high similarity
H.chunk_sim = function(c0, c1)
    if #c0 == 0 and #c1 == 0 then
        return 1.0
    end
    if #c0 == 0 or #c1 == 0 then
        return 0.0
    end

    local set0 = {}
    for _, line in ipairs(c0) do
        set0[line] = true
    end
    local set1 = {}
    for _, line in ipairs(c1) do
        set1[line] = true
    end

    local common = 0
    local set0_size = 0
    for line, _ in pairs(set0) do
        if set1[line] then
            common = common + 1
        end
        set0_size = set0_size + 1
    end

    local set1_size = 0
    for _ in pairs(set1) do
        set1_size = set1_size + 1
    end

    local union = set0_size + set1_size - common
    return union > 0 and (common / union) or 1.0
end

--- Picks a random chunk of text and queues it for processing.
-- @param text (table) List of strings to pick from.
-- @param no_mod (boolean) If true, don't pick from modified buffers.
-- @param do_evict (boolean) If true, evict similar chunks.
H.pick_chunk = function(text, no_mod, do_evict)
    if no_mod and (vim.bo.modified or not vim.fn.buflisted(0) or vim.fn.filereadable(vim.fn.expand("%")) == 0) then
        return
    end

    if Llama.config.options.ring_n_chunks <= 0 then
        return
    end
    if #text < 3 then
        return
    end

    local chunk
    if #text + 1 < Llama.config.options.ring_chunk_size then
        chunk = text
    else
        local text_len = #text
        local chunk_size = Llama.config.options.ring_chunk_size / 2
        local l0_start = 1
        local l0_end = math.max(1, text_len - chunk_size)
        local l0 = H.rand(l0_start, l0_end)
        local l1 = math.min(l0 + chunk_size, text_len)
        chunk = {}
        for i = l0, l1 do
            table.insert(chunk, text[i])
        end
    end

    local chunk_str = table.concat(chunk, "\n") .. "\n"

    -- check if this chunk is already added
    for _, c in ipairs(H.ring_chunks) do
        if vim.deep_equal(c.data, chunk) then
            return
        end
    end
    for _, c in ipairs(H.ring_queued) do
        if vim.deep_equal(c.data, chunk) then
            return
        end
    end

    -- evict queued chunks that are very similar to the new one
    for i = #H.ring_queued, 1, -1 do
        if H.chunk_sim(H.ring_queued[i].data, chunk) > Llama.config.options.ring_chunk_similarity_threshold then
            if do_evict then
                table.remove(H.ring_queued, i)
                H.ring_n_evict = H.ring_n_evict + 1
            else
                return
            end
        end
    end

    -- also from s:ring_chunks
    for i = #H.ring_chunks, 1, -1 do
        if H.chunk_sim(H.ring_chunks[i].data, chunk) > Llama.config.options.ring_chunk_similarity_threshold then
            if do_evict then
                table.remove(H.ring_chunks, i)
                H.ring_n_evict = H.ring_n_evict + 1
            else
                return
            end
        end
    end

    -- if the queue is full, remove the oldest item
    if #H.ring_queued >= Llama.config.options.ring_max_queued_chunks then
        table.remove(H.ring_queued, 1)
    end

    table.insert(H.ring_queued, {
        data = chunk,
        str = chunk_str,
        time = vim.fn.reltime(),
        filename = vim.api.nvim_buf_get_name(0),
    })
end

H.ring_update = function()
    -- update only if in normal mode or if the cursor hasn't moved for a while
    if
        vim.api.nvim_get_mode().mode ~= "n"
        and H.t_last_move
        and vim.fn.reltimefloat(vim.fn.reltime(H.t_last_move)) < Llama.config.options.ring_update_idle_s
    then
        return
    end

    if #H.ring_queued == 0 then
        return
    end

    -- move the first queued chunk to the ring buffer
    if #H.ring_chunks >= Llama.config.options.ring_n_chunks and #H.ring_chunks > 0 then
        table.remove(H.ring_chunks, 1)
    end

    table.insert(H.ring_chunks, table.remove(H.ring_queued, 1))

    -- send asynchronous job with the new extra context so that it is ready for the next FIM
    local extra_context = {}
    for _, chunk in ipairs(H.ring_chunks) do
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
        response_fields = { "" },
    })

    local args = {
        "--silent",
        "--no-buffer",
        "--request",
        "POST",
        "--url",
        Llama.config.options.endpoint,
        "--header",
        "Content-Type: application/json",
        "--data",
        "@-",
    }
    if Llama.config.options.api_key and Llama.config.options.api_key ~= "" then
        table.insert(args, "--header")
        table.insert(args, "Authorization: Bearer " .. Llama.config.options.api_key)
    end

    Job:new({
        command = "curl",
        args = args,
        writer = request,
    }):start()
end

H.on_move = function()
    H.t_last_move = vim.fn.reltime()
    Llama.fim_hide()
    local pos = vim.api.nvim_win_get_cursor(0)
    Llama.fim_try_hint(pos[2], pos[1])
end

H.fim_on_exit = function(_, exit_code)
    if exit_code ~= 0 then
        vim.schedule(function()
            vim.notify("llama.nvim job failed with exit code: " .. exit_code, vim.log.levels.WARN)
        end)
    end
    H.current_job = nil
end

H.fim_on_response = function(hashes, _, data)
    local raw_data = table.concat(data, "\n")
    if raw_data == "" then
        return
    end
    if not (string.find(raw_data, "^%s*{") and string.find(raw_data, '"content"%s*:')) then
        return
    end

    local ok, _ = pcall(vim.json.decode, raw_data)
    if not ok then
        return
    end

    for _, hash in ipairs(hashes) do
        H.cache_insert(hash, raw_data)
    end

    if not H.hint_shown or not (H.fim_data and H.fim_data.can_accept) then
        vim.schedule(function()
            local pos = vim.api.nvim_win_get_cursor(0)
            Llama.fim_try_hint(pos[2], pos[1])
        end)
    end
end

--------------------------------------------------------------------------------
-- Public API Functions
--------------------------------------------------------------------------------

--- Hides the completion hint.
Llama.fim_hide = function()
    if not H.hint_shown then
        return
    end
    H.hint_shown = false
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_get_current_buf(), H.vt_namespace_id, 0, -1)
    pcall(vim.keymap.del, "i", Llama.config.mappings.keymap_accept_full, { buffer = true })
    pcall(vim.keymap.del, "i", Llama.config.mappings.keymap_accept_line, { buffer = true })
    pcall(vim.keymap.del, "i", Llama.config.mappings.keymap_accept_word, { buffer = true })
end

H.pick_chunk_around_cursor = function()
    local half_chunk = Llama.config.options.ring_chunk_size / 2
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]
    local last_line = vim.api.nvim_buf_line_count(0)
    local start_line = math.max(1, cur_line - half_chunk)
    local end_line = math.min(last_line, cur_line + half_chunk)
    -- Get lines from current buffer (0)
    local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
    H.pick_chunk(lines, true, true)
end

--- Initializes the plugin.
Llama.init = function()
    if vim.fn.executable("curl") == 0 then
        vim.notify('llama.nvim requires "curl" to be available', vim.log.levels.ERROR)
        return
    end
    H.t_last_move = vim.fn.reltime()
    local augroup = vim.api.nvim_create_augroup("Llama", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
        group = augroup,
        pattern = "*",
        callback = function()
            vim.keymap.set("i", Llama.config.mappings.keymap_trigger, function()
                return Llama.fim_inline(false, false)
            end, { expr = true, silent = true, buffer = true })
        end,
    })
    vim.api.nvim_create_autocmd("InsertLeavePre", { group = augroup, pattern = "*", callback = Llama.fim_hide })
    vim.api.nvim_create_autocmd(
        { "CursorMoved", "CursorMovedI" },
        { group = augroup, pattern = "*", callback = H.on_move }
    )
    vim.api.nvim_create_autocmd(
        { "CompleteChanged", "CompleteDone" },
        { group = augroup, pattern = "*", callback = Llama.fim_hide }
    )

    if Llama.config.options.auto_fim then
        vim.api.nvim_create_autocmd("CursorMovedI", {
            group = augroup,
            pattern = "*",
            callback = function()
                Llama.fim(-1, -1, true, {}, true)
            end,
        })
    end

    -- gather chunks upon yanking
    vim.api.nvim_create_autocmd("TextYankPost", {
        group = augroup,
        pattern = "*",
        callback = function()
            if vim.v.event.operator == "y" then
                H.pick_chunk(vim.v.event.regcontents, false, true)
            end
        end,
    })

    -- gather chunks upon entering/leaving a buffer and saving
    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        pattern = "*",
        callback = function()
            vim.defer_fn(H.pick_chunk_around_cursor, 100)
        end,
    })
    vim.api.nvim_create_autocmd({ "BufLeave", "BufWritePost" }, {
        group = augroup,
        pattern = "*",
        callback = H.pick_chunk_around_cursor,
    })

    if Llama.config.options.ring_n_chunks > 0 and not H.ring_timer then
        H.ring_timer = vim.loop.new_timer()
        H.ring_timer:start(100, Llama.config.options.ring_update_ms, vim.schedule_wrap(H.ring_update))
    end

    H.enabled = true
end

--- Disables the plugin.
Llama.disable = function()
    Llama.fim_hide()
    vim.api.nvim_clear_autocmds({ group = "Llama" })
    pcall(vim.keymap.del, "i", Llama.config.mappings.keymap_trigger)

    if H.ring_timer then
        H.ring_timer:stop()
        H.ring_timer:close()
        H.ring_timer = nil
    end

    H.enabled = false
end

Llama.toggle = function()
    if H.enabled then
        Llama.disable()
    else
        Llama.init()
    end
end

Llama.fim_inline = function(is_auto, use_cache)
    if H.hint_shown and not is_auto then
        Llama.fim_hide()
        return ""
    end
    Llama.fim(-1, -1, is_auto, {}, use_cache)
    return ""
end

--- Main FIM call to the server.
Llama.fim = function(pos_x, pos_y, is_auto, prev, use_cache)
    if pos_x < 0 then
        pos_x = vim.api.nvim_win_get_cursor(0)[2]
    end
    if pos_y < 0 then
        pos_y = vim.api.nvim_win_get_cursor(0)[1]
    end

    if H.current_job then
        if H.timer_fim then
            H.timer_fim:stop()
        end
        H.timer_fim = vim.defer_fn(function()
            Llama.fim(pos_x, pos_y, is_auto, prev, use_cache)
        end, Llama.config.options.fim_debounce_ms)
        return
    end

    local ctx_local = Llama.fim_ctx_local(pos_x, pos_y, prev)
    if is_auto and #ctx_local.line_cur_suffix > Llama.config.options.max_line_suffix then
        return
    end

    -- Evict chunks from ring buffer that are too similar to the current context
    if Llama.config.options.ring_n_chunks > 0 then
        local half_chunk = Llama.config.options.ring_chunk_size / 2
        local last_line = vim.api.nvim_buf_line_count(0)
        local start_line = math.max(1, pos_y - half_chunk)
        local end_line = math.min(last_line, pos_y + half_chunk)
        local current_chunk_data = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

        for i = #H.ring_chunks, 1, -1 do
            if
                H.chunk_sim(H.ring_chunks[i].data, current_chunk_data)
                > Llama.config.options.ring_eviction_similarity_threshold
            then
                table.remove(H.ring_chunks, i)
                H.ring_n_evict = H.ring_n_evict + 1
            end
        end
    end

    local hashes = { vim.fn.sha256(ctx_local.prefix .. ctx_local.middle .. "Î" .. ctx_local.suffix) }
    local prefix_trim = ctx_local.prefix
    for _ = 1, 3 do
        prefix_trim = string.gsub(prefix_trim, "^[^\n]*\n", "", 1)
        if prefix_trim == "" then
            break
        end
        table.insert(hashes, vim.fn.sha256(prefix_trim .. ctx_local.middle .. "Î" .. ctx_local.suffix))
    end

    if use_cache then
        for _, hash in ipairs(hashes) do
            if H.cache_get(hash) ~= nil then
                return
            end
        end
    end

    H.indent_last = ctx_local.indent

    -- Prepare extra context for the request
    local extra_context = {}
    if Llama.config.options.ring_n_chunks > 0 then
        for _, chunk in ipairs(H.ring_chunks) do
            table.insert(extra_context, {
                text = chunk.str,
                time = chunk.time,
                filename = chunk.filename,
            })
        end
    end

    local request = vim.json.encode({
        input_prefix = ctx_local.prefix,
        input_suffix = ctx_local.suffix,
        input_extra = extra_context,
        prompt = ctx_local.middle,
        n_predict = Llama.config.options.n_predict,
        stop = Llama.config.options.stop_strings,
        n_indent = ctx_local.indent,
        stream = false,
        samplers = { "top_k", "top_p", "infill" },
        cache_prompt = true,
        t_max_prompt_ms = Llama.config.options.t_max_prompt_ms,
        t_max_predict_ms = (#(prev or {}) == 0) and 250 or Llama.config.options.t_max_predict_ms,
        response_fields = {
            "content",
            "timings/prompt_n",
            "timings/prompt_ms",
            "timings/prompt_per_second",
            "timings/predicted_n",
            "timings/predicted_ms",
            "timings/predicted_per_second",
            "truncated",
            "tokens_cached",
        },
    })
    if H.current_job then
        H.current_job:shutdown()
    end

    local args = {
        "--silent",
        "--no-buffer",
        "--request",
        "POST",
        "--url",
        Llama.config.options.endpoint,
        "--header",
        "Content-Type: application/json",
        "--data",
        "@-",
    }
    if Llama.config.options.api_key and Llama.config.options.api_key ~= "" then
        table.insert(args, "--header")
        table.insert(args, "Authorization: Bearer " .. Llama.config.options.api_key)
    end

    H.current_job = Job:new({
        command = "curl",
        args = args,
        writer = request,
        on_exit = function(j, return_val)
            if return_val == 0 then
                H.fim_on_response(hashes, j, j:result())
            end
            H.fim_on_exit(j, return_val)
        end,
    })
    H.current_job:start()

    -- Gather more context on large cursor movements
    if Llama.config.options.ring_n_chunks > 0 and is_auto then
        if not vim.b.llama_last_pick_pos then
            vim.b.llama_last_pick_pos = pos_y
        end

        local delta_y = math.abs(pos_y - vim.b.llama_last_pick_pos)
        if delta_y > Llama.config.options.fim_large_move_line_threshold then
            local max_y = vim.api.nvim_buf_line_count(0)
            -- expand the prefix even further
            local prefix_start = math.max(1, pos_y - Llama.config.options.ring_scope)
            local prefix_end = math.max(1, pos_y - Llama.config.options.n_prefix)
            if prefix_end > prefix_start then
                H.pick_chunk(vim.api.nvim_buf_get_lines(0, prefix_start - 1, prefix_end, false), false, false)
            end

            -- pick a suffix chunk
            local suffix_start = math.min(max_y, pos_y + Llama.config.options.n_suffix)
            local suffix_end = math.min(max_y, suffix_start + Llama.config.options.ring_chunk_size)
            if suffix_end > suffix_start then
                H.pick_chunk(vim.api.nvim_buf_get_lines(0, suffix_start - 1, suffix_end, false), false, false)
            end

            vim.b.llama_last_pick_pos = pos_y
        end
    end
end

--- Gathers local context around cursor.
Llama.fim_ctx_local = function(pos_x, pos_y, prev)
    local bufnr = vim.api.nvim_get_current_buf()
    local max_y = vim.api.nvim_buf_line_count(bufnr)
    local line_cur, line_cur_prefix, line_cur_suffix, indent, lines_prefix, lines_suffix

    if not prev or #prev == 0 then
        -- Standard context gathering when there's no previous suggestion
        line_cur = vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)[1] or ""
        if line_cur:match("^%s*$") then
            line_cur_prefix, line_cur_suffix, indent = "", "", 0
        else
            line_cur_prefix = line_cur:sub(1, pos_x)
            line_cur_suffix = line_cur:sub(pos_x + 1)
            indent = #(line_cur:match("^%s*"))
        end
        lines_prefix =
            vim.api.nvim_buf_get_lines(bufnr, math.max(1, pos_y - Llama.config.options.n_prefix) - 1, pos_y - 1, false)
        lines_suffix =
            vim.api.nvim_buf_get_lines(bufnr, pos_y, math.min(max_y, pos_y + Llama.config.options.n_suffix), false)
    else
        -- Context gathering for speculative completion (with a previous suggestion)
        if #prev == 1 then
            line_cur = (vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)[1] or "") .. prev[1]
        else
            line_cur = prev[#prev]
        end

        line_cur_prefix = line_cur
        line_cur_suffix = ""

        lines_prefix = vim.api.nvim_buf_get_lines(
            bufnr,
            math.max(1, pos_y - Llama.config.options.n_prefix + #prev - 1) - 1,
            pos_y - 1,
            false
        )
        if #prev > 1 then
            table.insert(lines_prefix, (vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)[1] or "") .. prev[1])
            for i = 2, #prev - 1 do
                table.insert(lines_prefix, prev[i])
            end
        end

        lines_suffix =
            vim.api.nvim_buf_get_lines(bufnr, pos_y + 1, math.min(max_y, pos_y + Llama.config.options.n_suffix), false)
        indent = H.indent_last
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
Llama.fim_try_hint = function(pos_x, pos_y)
    if not ({ i = true, ic = true, ix = true })[vim.api.nvim_get_mode().mode] then
        return
    end
    local ctx = Llama.fim_ctx_local(pos_x, pos_y, {})
    local hash = vim.fn.sha256(ctx.prefix .. ctx.middle .. "Î" .. ctx.suffix)
    local raw_response = H.cache_get(hash)

    if not raw_response then
        local pm = ctx.prefix .. ctx.middle
        for i = 1, 128 do
            if i + 1 > #pm then
                break
            end
            local new_ctx_str = pm:sub(1, #pm - (i + 1)) .. "Î" .. ctx.suffix
            local cached_resp = H.cache_get(vim.fn.sha256(new_ctx_str))
            if cached_resp then
                local ok, r = pcall(vim.json.decode, cached_resp)
                if ok and r.content and r.content:sub(1, i + 1) == pm:sub(-(i + 1)) then
                    r.content = r.content:sub(i + 2)
                    if #r.content > 0 then
                        raw_response = vim.json.encode(r)
                        break
                    end
                end
            end
        end
    end

    if raw_response then
        Llama.fim_render(pos_x, pos_y, raw_response)
        if H.hint_shown then
            Llama.fim(pos_x, pos_y, true, H.fim_data.content, true)
        end
    end
end

--- Renders the suggestion with deduplication and info.
Llama.fim_render = function(pos_x, pos_y, data)
    if vim.fn.pumvisible() == 1 then
        return
    end

    local ok, response = pcall(vim.json.decode, data)
    if not ok or not response.content or response.content == "" then
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local line_cur_tbl = vim.api.nvim_buf_get_lines(bufnr, pos_y - 1, pos_y, true)
    if #line_cur_tbl == 0 then
        return
    end
    local line_cur = line_cur_tbl[1]
    local line_cur_suffix = line_cur:sub(pos_x + 1)

    local content_lines = vim.split(response.content, "\n", { trimempty = false })
    while #content_lines > 0 and content_lines[#content_lines] == "" do
        table.remove(content_lines)
    end
    if #content_lines == 0 then
        return
    end

    -- ### Deduplication Logic ###
    if #content_lines == 1 and (content_lines[1] == "" or content_lines[1] == line_cur_suffix) then
        return
    end
    if #content_lines > 1 and content_lines[1] == "" then
        local existing = vim.api.nvim_buf_get_lines(bufnr, pos_y, pos_y + #content_lines - 2, false)
        local suggestion_rest = {}
        for i = 2, #content_lines do
            table.insert(suggestion_rest, content_lines[i])
        end
        if vim.deep_equal(suggestion_rest, existing) then
            return
        end
    end

    -- ### Info String Logic (Corrected) ###
    local info_string = ""
    if Llama.config.options.show_info > 0 and response["timings/prompt_n"] then
        local prefix = (Llama.config.options.show_info == 2) and "   " or "llama.nvim"
        info_string = string.format(
            "%s | c: %d, r: %d/%d, e: %d, q: %d/16, C: %d/%d | p: %d (%.2fms, %.2f t/s) | g: %d (%.2fms, %.2f t/s)",
            prefix,
            response.tokens_cached or 0,
            #H.ring_chunks,
            Llama.config.options.ring_n_chunks,
            H.ring_n_evict,
            #H.ring_queued,
            #H.cache_lru_order,
            Llama.config.options.max_cache_keys,
            response["timings/prompt_n"] or 0,
            response["timings/prompt_ms"] or 0.0,
            response["timings/prompt_per_second"] or 0.0,
            response["timings/predicted_n"] or 0,
            response["timings/predicted_ms"] or 0.0,
            response["timings/predicted_per_second"] or 0.0
        )
    end
    if Llama.config.options.show_info == 1 and info_string ~= "" then
        vim.o.statusline = info_string
    end

    -- ### Display Logic ###
    local virt_text = { { content_lines[1], Llama.config.highlight.hl_hint_group } }
    if Llama.config.options.show_info == 2 and info_string ~= "" then
        table.insert(virt_text, { info_string, Llama.config.highlight.hl_info_group })
    end

    vim.api.nvim_buf_set_extmark(
        bufnr,
        H.vt_namespace_id,
        pos_y - 1,
        pos_x,
        { virt_text = virt_text, virt_text_pos = "overlay" }
    )

    if #content_lines > 1 then
        local virt_lines = {}
        for i = 2, #content_lines do
            table.insert(virt_lines, { { content_lines[i], Llama.config.highlight.hl_hint_group } })
        end
        vim.api.nvim_buf_set_extmark(bufnr, H.vt_namespace_id, pos_y - 1, 0, { virt_lines = virt_lines })
    end

    H.hint_shown = true
    H.fim_data = { pos_x = pos_x, pos_y = pos_y, line_cur = line_cur, can_accept = true, content = content_lines }

    vim.keymap.set("i", Llama.config.mappings.keymap_accept_full, function()
        Llama.fim_accept("full")
    end, { buffer = true, silent = true })
    vim.keymap.set("i", Llama.config.mappings.keymap_accept_line, function()
        Llama.fim_accept("line")
    end, { buffer = true, silent = true })
    vim.keymap.set("i", Llama.config.mappings.keymap_accept_word, function()
        Llama.fim_accept("word")
    end, { buffer = true, silent = true })
end

--- Accepts the current suggestion.
Llama.fim_accept = function(accept_type)
    if not (H.fim_data.can_accept and H.fim_data.content and #H.fim_data.content > 0) then
        Llama.fim_hide()
        return
    end
    local d = H.fim_data
    local bufnr = vim.api.nvim_get_current_buf()
    local first_line = (accept_type == "word") and (d.content[1]:match("^%s*[%S]+") or "") or d.content[1]
    vim.api.nvim_buf_set_lines(bufnr, d.pos_y - 1, d.pos_y, true, { d.line_cur:sub(1, d.pos_x) .. first_line })
    if accept_type == "full" and #d.content > 1 then
        local rest = {}
        for i = 2, #d.content do
            table.insert(rest, d.content[i])
        end
        vim.api.nvim_buf_set_lines(bufnr, d.pos_y, d.pos_y, true, rest)
    end
    local cur_y, cur_x
    if accept_type == "word" then
        cur_y, cur_x = d.pos_y, d.pos_x + #first_line
    elseif accept_type == "line" or #d.content == 1 then
        cur_y, cur_x = d.pos_y, d.pos_x + #first_line
    else
        cur_y = d.pos_y + #d.content - 1
        cur_x = #d.content[#d.content]
    end
    vim.api.nvim_win_set_cursor(0, { cur_y, cur_x })
    Llama.fim_hide()
end

return Llama
