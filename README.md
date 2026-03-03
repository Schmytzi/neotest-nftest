# neotest-nftest

A [neotest](https://github.com/nvim-neotest/neotest) adapter for [nf-test](https://www.nf-test.com/), the testing framework for [Nextflow](https://www.nextflow.io/) pipelines.

## Requirements

- [Neovim](https://neovim.io/) >= 0.9
- [neotest](https://github.com/nvim-neotest/neotest)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with the `groovy` parser installed
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nf-test](https://www.nf-test.com/installation/) installed and available in `$PATH`

## Installation

1. Make sure that the groovy parser for nvim-treesitter is installed: `:TSInstall groovy`
2. Add neotest-nftest to your config:

```lua
return {
  {
    "Schmytzi/neotest-nftest",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
  },
  {
    "nvim-neotest/neotest",
    dependencies = {
      "nvim-neotest/nvim-nio",
      "nvim-lua/plenary.nvim",
      "antoinemadec/FixCursorHold.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    config = function()
      require("neotest").setup({
        adapters = {
          require("neotest-nftest"),
        },
      })
    end,
  }
}
```

## Configuration

The adapter can be configured by calling it as a function with an options table. All options are optional and fall back to their defaults.

```lua
require("neotest").setup({
  adapters = {
    require("neotest-nftest")({
      -- Profile to pass to nf-test via --profile. Defaults to "docker".
      profile = "docker",

      -- Additional arguments passed to nf-test when running tests.
      extra_args = {},
    }),
  },
})
```

### Options

| Option       | Type       | Default    | Description                                              |
|--------------|------------|------------|----------------------------------------------------------|
| `profile`    | `string`   | `"docker"` | The nf-test profile to use when running tests (`--profile +<profile>`). |
| `extra_args` | `string[]` | `{}`       | Extra arguments appended to the nf-test command.        |

## Usage

neotest-nftest automatically discovers test files matching the `*.nf.test` pattern within a Nextflow project (a directory containing `nextflow.config` or `.git`).

### Running Tests

Use the standard neotest keybindings or API to run tests. For example:

```lua
-- Run the nearest test
require("neotest").run.run()

-- Run all tests in the current file
require("neotest").run.run(vim.fn.expand("%"))

-- Run tests with a specific profile (overrides the configured default)
require("neotest").run.run({ profile = "conda" })

-- Run a test and update snapshots
require("neotest").run.run({
  extra_args = { "--update-snapshot", "--clean-snapshot" }
})
```

## DAP Strategy

If you run tests with the `dap` strategy (e.g. `require("neotest").run.run({ strategy = "dap" })`), nf-test will be invoked with the `--verbose` flag. This enables more detailed output for troubleshooting.

> **Note:** Using the `dap` strategy will **not** start a debugger, as Nextflow does not support debugging via DAP. The verbose output is useful for diagnostics, but debugging features such as breakpoints and stepping through code are not available.

## Project Structure

A typical Nextflow project layout expected by this adapter:

```
my-pipeline/
├── nextflow.config       ← used to detect project root
├── main.nf
└── tests/
    └── my_module.nf.test ← discovered as a test file
```
