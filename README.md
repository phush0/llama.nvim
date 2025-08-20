# llama.nvim

A Neovim plugin for asynchronous code completion using a local LLaMA model.

## Features

*   **Asynchronous Fill-in-the-Middle (FIM) Completion:** Get code suggestions without blocking your workflow.
*   **Context Caching:** Responses from the model are cached to provide faster suggestions for repeated contexts.
*   **Context Ring:** The plugin maintains a "context ring" of code chunks from your project to provide more relevant suggestions.
*   **Configurable Keymaps:** Customize the keybindings for triggering and accepting completions.
*   **Customizable Highlighting:** Change the colors of the completion hints and information text.

## Requirements

*   Neovim >= 0.8
*   `curl` installed and available in your `PATH`.
*   [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

## Installation

You can install `llama.nvim` using your favorite plugin manager.

### lazy.nvim

```lua
{
  "phusho/llama.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("llama").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "phusho/llama.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("llama").setup()
  end,
}
```

## Configuration

You can override the default configuration by passing a table to the `setup` function.

### Default Configuration

```lua
require("llama").setup({
  options = {
    -- Server Settings
    endpoint = 'http://127.0.0.1:8012/infill',
    api_key = '', -- Optional API key for authentication
    
    -- Context Settings
    n_prefix = 256,        -- Lines of context before cursor
    n_suffix = 64,         -- Lines of context after cursor
    n_predict = 128,       -- Max tokens to predict
    stop_strings = {},     -- Strings that stop generation
    
    -- Timing Settings
    t_max_prompt_ms = 500,   -- Max time for prompt processing
    t_max_predict_ms = 1000, -- Max time for prediction
    
    -- UI Settings
    show_info = 2,           -- 0: disabled, 1: statusline, 2: inline
    auto_fim = true,         -- Auto-trigger on cursor movement
    max_line_suffix = 8,     -- Don't auto-complete if more chars after cursor
    
    -- Cache Settings
    max_cache_keys = 250,    -- Max number of cached responses
    
    -- Context Ring Buffer Settings
    ring_n_chunks = 16,                          -- Max context chunks to maintain
    ring_chunk_size = 64,                        -- Size of each chunk (lines)
    ring_scope = 1024,                           -- Range for gathering chunks
    ring_update_ms = 1000,                       -- Update frequency
    ring_max_queued_chunks = 16,                 -- Max queued chunks
    ring_chunk_similarity_threshold = 0.9,       -- Similarity threshold for deduplication
    ring_eviction_similarity_threshold = 0.5,    -- Threshold for evicting similar chunks
    ring_update_idle_s = 3.0,                   -- Idle time before updates
    
    -- FIM (Fill-in-Middle) Settings
    fim_debounce_ms = 100,                       -- Debounce delay for requests
    fim_large_move_line_threshold = 32,          -- Line threshold for context expansion
  },
  
  mappings = {
    keymap_trigger = "<C-F>",      -- Trigger completion
    keymap_accept_full = "<Tab>",  -- Accept full suggestion
    keymap_accept_line = "<S-Tab>", -- Accept current line only
    keymap_accept_word = "<C-B>",  -- Accept current word only
  },
  
  highlight = {
    hl_hint_group = "llama_hl_hint", -- Highlight group for suggestions
    hl_info_group = "llama_hl_info", -- Highlight group for info text
  }
})
```

### Basic Usage Example

```lua
require("llama").setup({
  options = {
    endpoint = "http://127.0.0.1:8080/infill",
    auto_fim = true,
  }
})
```
