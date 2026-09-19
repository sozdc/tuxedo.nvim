# tuxedo.nvim

A small Neovim integration for the independently installed [Tuxedo](https://github.com/webstonehq/tuxedo). It opens Tuxedo's own terminal UI in one centered floating window and provides a native quick-add command.

> `tuxedo.nvim` does not bundle Tuxedo. Tuxedo must be installed independently.

## Requirements

- Neovim 0.11 or newer
- Tuxedo installed independently and available as `tuxedo` (or configured with `command`)
- No Lua or runtime dependencies

Install or update Tuxedo using its official installation instructions. Normal Tuxedo upgrades do not require rebuilding or reinstalling this plugin.

## Installation

With lazy.nvim:

```lua
{
  "sozdc/tuxedo.nvim",
  cmd = { "Tuxedo", "TuxedoToggle", "TuxedoClose", "TuxedoAdd" },
  opts = {},
}
```

The exact setup table is:

```lua
require("tuxedo").setup({
  command = "tuxedo",
  float = {
    width = 0.90,
    height = 0.90,
    border = "rounded",
  },
})
```

`width` and `height` accept either a positive fraction up to `1` or a positive absolute editor size. `border` accepts Neovim's named borders or a 1-, 2-, 4-, or 8-element border table; entries may be characters or `{ character, highlight }` pairs. Unknown options and invalid values are rejected.

## Usage

Commands:

- `:Tuxedo` opens or focuses the Tuxedo UI.
- `:TuxedoToggle` hides or restores the same live terminal session.
- `:TuxedoClose` stops and removes the current Tuxedo terminal session.
- `:TuxedoAdd` prompts for a task and invokes Tuxedo's native `add` command.
- `:TuxedoAdd write release notes` adds the supplied text without opening a prompt.

Lua API:

```lua
local tuxedo = require("tuxedo")
tuxedo.setup(opts)
tuxedo.open({ file = "/path/to/todo.txt" }) -- file is optional
tuxedo.toggle()
tuxedo.close()
local status = tuxedo.status()
tuxedo.add("write release notes", function(result, err)
  -- Called asynchronously after Tuxedo finishes.
end)
```

`open()`, `toggle()`, and `close()` return stable success/state values rather than the mutable internal terminal record. `status()` returns a detached snapshot with `state`, `visible`, `target_kind`, `file`, `cwd`, `buffer`, and `job`; changing the snapshot cannot affect the live session. The optional `add()` callback receives `(result, err)` asynchronously, including validation and Neovim-version failures. Successful results preserve `ok`, `action`, and Tuxedo's documented task fields, including project/context arrays and recurrence metadata.

Toggle preserves the terminal buffer and Tuxedo process. This intentionally keeps navigation/filter state and allows Tuxedo's documented external-file polling to notice tasks added through `:TuxedoAdd` without restarting the UI. Closing the floating window externally is also treated as a hide; the same process is restored by the next `:Tuxedo`. Use `:TuxedoClose` when the process itself must stop or before switching task files.

A requested explicit file is canonicalized before launch and passed as Tuxedo's optional positional `FILE`, even when its relative name resembles `add`, `ls`, `update`, `--sample`, or begins with `-`. Tuxedo remains responsible for opening, creating, and interpreting the file.

## File resolution and quick-add routing

Tuxedo's documented launch precedence is:

1. Explicit positional `FILE` supplied to the TUI.
2. `TODO_FILE`.
3. `TODO_DIR/todo.txt`.
4. Existing `todo.txt` in the launch directory.
5. The TUI's first-run file-selection prompt when none exists.

The CLI's sample fallback is a separate behavior and is never used as a substitute for the TUI's first-run prompt. For an explicit or otherwise deterministic active session, the adapter freezes the canonical file and routes one-shot commands through an absolute `TODO_FILE` override. The plugin cannot observe a file selected inside Tuxedo's first-run UI, so `:TuxedoAdd` remains unavailable for that session: exit it with `q` or `:TuxedoClose`, then reopen with an explicit file or valid `TODO_FILE`/`TODO_DIR`. Without an active session, Tuxedo receives the caller's current environment and performs its normal resolution.

## Health and troubleshooting

Run:

```vim
:checkhealth tuxedo
```

Health checks Neovim's API floor, the configured command, executable resolution, display-only version text, and independent native add/list capabilities. It reports the resolved executable as the TUI entry point but does not claim to prove an interactive launch from a noninteractive health check. The compatibility probe uses a private temporary directory with controlled `TODO_FILE`, `TODO_DIR`, `DONE_FILE`, and `TUXEDO_NO_UPDATE_CHECK=1`; it recursively removes that directory afterward. Add is required for V1 and is reported as an error when unavailable. List is optional and reported as a warning when unavailable. Neither native capability disables the TUI entry point.

Version parsing is display-only. No exact Tuxedo version is pinned, and unknown or newer versions remain usable when the required interface works. The stable boundary is Tuxedo's documented executable interface: argv lists, exit status/stderr, `--version`, JSON `add`/`ls`, the optional TUI `FILE`, and `TODO_FILE`/`TODO_DIR`/`DONE_FILE`. Breaking CLI changes are adapted in `lua/tuxedo/cli.lua`; temporary user pinning is only an exceptional fallback.

Common fixes:

- If the executable is missing, install Tuxedo or set `command` to an executable path.
- If health reports add JSON incompatibility, inspect the installed Tuxedo version and its `add` output before retrying; mutation failures after process start may be indeterminate.
- If a session rejects a second explicit file, exit it with `q` or run `:TuxedoClose` before opening another file. This protects the live process from accidental retargeting.
- Keep task-file environment variables consistent between Tuxedo and Neovim. The plugin does not parse or write todo files itself.

## Development

Run the dependency-free contract tests from the repository root:

```sh
make test
```

The tests exercise configuration validation, argv construction, target precedence, JSON/version compatibility, error classification, isolated capability probing, public commands/API completion, and the terminal lifecycle across hide/show, external close, cross-tab moves, resize, buffer wipeout, and process exit. They do not snapshot terminal screens or depend on Tuxedo's private implementation.

## Scope

Tuxedo remains the task model, file owner, mutation engine, and TUI. This plugin deliberately does not copy Tuxedo code, parse todo.txt files, depend on Rust modules, inspect terminal screen contents, use private sockets, or treat task numbers as persistent IDs. Future picker, edit, and completion integrations may build on the same public boundary; they are not implemented here.

## License

MIT; see [LICENSE](LICENSE).
