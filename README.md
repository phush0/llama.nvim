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

```lua
require("llama").setup({
  endpoint = "http://127.0.0.1:8080/infill",
  -- See the configuration section in the source code for all available options.
})
```

## Recent Changes

### Refactoring to plenary.nvim

The core job management system of `llama.nvim` has been refactored from using the built-in `vim.fn.jobstart` to using the more robust and modern `plenary.nvim` library.

This change is internal and should not affect the plugin's functionality from a user's perspective. The primary goal of this refactoring was to improve the stability and maintainability of the codebase by aligning it with modern Neovim plugin development best practices.

As part of this refactoring, the `plenary.nvim` library is now a required dependency.