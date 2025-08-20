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

The default configuration is:

```lua
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
  ring_max_queued_chunks = 16,
  ring_chunk_similarity_threshold = 0.9,
  ring_eviction_similarity_threshold = 0.5,
  ring_update_idle_s = 3.0,
  fim_debounce_ms = 100,
  fim_large_move_line_threshold = 32,
  keymap_trigger = "<C-F>",
  keymap_accept_full = "<Tab>",
  keymap_accept_line = "<S-Tab>",
  keymap_accept_word = "<C-B>",
  hl_hint_group = "llama_hl_hint",
  hl_info_group = "llama_hl_info",
}
```

```lua
require("llama").setup({
  endpoint = "http://127.0.0.1:8080/infill",
  -- See the configuration section in the source code for all available options.
})
```
