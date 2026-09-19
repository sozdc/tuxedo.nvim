package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local config = require("tuxedo.config")
local cli = require("tuxedo.cli")
local terminal = require("tuxedo.terminal")
local tuxedo = require("tuxedo")

local tests = {}
local failures = {}

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual), 2)
  end
end

local function ok(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

local function fails(fn, message)
  local success = pcall(fn)
  if success then
    error(message or "expected function to fail", 2)
  end
end
local function with_system(resolver, fn)
  local previous = vim.system
  local state = { calls = {} }
  vim.system = function(argv, options, callback)
    local copied_argv = vim.deepcopy(argv)
    local copied_options = vim.deepcopy(options)
    state.calls[#state.calls + 1] = { argv = copied_argv, options = copied_options }
    local result = resolver(argv, options, state)
    if callback then
      callback(result)
    end
    return {
      wait = function()
        return result
      end,
    }
  end
  local success, err = pcall(fn, state)
  vim.system = previous
  if not success then
    error(err, 0)
  end
end

local function await_state(state)
  ok(vim.wait(1000, function()
    return state.done == true
  end, 10), "timed out waiting for scheduled process callback")
end

local function write_fake_tuxedo(path)
  vim.fn.writefile({
    "#!/bin/sh",
    'case "$1" in',
    "  --version)",
    "    printf 'tuxedo fake\\n'",
    "    ;;",
    "  add)",
    '    printf \'%s\\n\' "$2" >> "$TODO_FILE"',
    '    printf \'{"ok":true,"task":{"raw":"%s"}}\\n\' "$2"',
    "    ;;",
    "  ls)",
    "    marker=",
    '    while IFS= read -r line; do marker=$line; done < "$TODO_FILE"',
    '    printf \'[{"raw":"%s"}]\\n\' "$marker"',
    "    ;;",
    "  *)",
    "    trap 'exit 0' TERM INT HUP",
    "    while IFS= read -r line; do",
    '      [ "$line" = "q" ] && exit 0',
    "    done",
    "    ;;",
    "esac",
  }, path)
  ok(vim.fn.setfperm(path, "rwx------") ~= 0, "could not make fake Tuxedo executable")
end

test("configuration defaults and deep merge", function()
  config._reset()
  eq(config.get(), { command = "tuxedo", float = { width = 0.90, height = 0.90, border = "rounded" } })
  config.setup({ float = { width = 40, border = "double" } })
  eq(config.get(), { command = "tuxedo", float = { width = 40, height = 0.90, border = "double" } })
  config.setup({ command = "custom-tuxedo", float = { height = 12 } })
  eq(config.get().float.width, 40)
  eq(config.get().float.height, 12)
end)

test("configuration rejects unknown and invalid options", function()
  config._reset()
  config.setup({ float = { border = { "-", "|" } } })
  eq(config.get().float.border, { "-", "|" })
  config.setup({ float = { border = { { "╭", "TuxedoBorder" }, { "─", "TuxedoBorder" }, { "╮", "TuxedoBorder" }, { "│", "TuxedoBorder" } } } })
  eq(config.get().float.border[1], { "╭", "TuxedoBorder" })
  fails(function() config.setup({ unknown = true }) end)
  fails(function() config.setup({ float = { unknown = true } }) end)
  fails(function() config.setup({ command = "  " }) end)
  fails(function() config.setup({ float = { width = 0 } }) end)
  fails(function() config.setup({ float = { border = "invalid" } }) end)
  fails(function() config.setup({ float = { border = { "-", "|", "+" } } }) end)
  fails(function() config.setup({ float = { border = { { "-", "TuxedoBorder", "extra" } } } }) end)
end)

test("TUI argv canonicalizes spaces reserved names and dash paths", function()
  local cwd = "/tmp/tuxedo argv test"
  eq(cli.build_tui_argv("/bin/tuxedo", { cwd = cwd, file = "--sample" }), { "/bin/tuxedo", cwd .. "/--sample" })
  eq(cli.build_tui_argv("/bin/tuxedo", { cwd = cwd, file = "add" }), { "/bin/tuxedo", cwd .. "/add" })
  eq(cli.build_tui_argv("/bin/tuxedo", { cwd = cwd, file = "folder/../todo.txt" }), { "/bin/tuxedo", cwd .. "/todo.txt" })
end)

test("path normalization supports Windows roots and separators", function()
  eq(cli._lexical_normalize([[folder\..\todo.txt]], [[C:\Users\me]], true), "C:/Users/me/todo.txt")
  eq(cli._lexical_normalize([[C:\Users\me\..\todo.txt]], [[D:\ignored]], true), "C:/Users/todo.txt")
  eq(cli._lexical_normalize([[\\server\share\dir\..\todo.txt]], [[C:\Users\me]], true), "//server/share/todo.txt")
  eq(cli._lexical_normalize([[\todo.txt]], [[C:\Users\me]], true), "C:/todo.txt")
  eq(cli._lexical_normalize([[C:todo.txt]], [[C:\Users\me]], true), nil)
end)

test("add and list argv preserve task spaces", function()
  eq(cli.build_add_argv("/bin/tuxedo", "buy milk and bread"), { "/bin/tuxedo", "add", "buy milk and bread", "--json" })
  eq(cli.build_list_argv("/bin/tuxedo"), { "/bin/tuxedo", "ls", "--json" })
  eq(cli.build_list_argv("/bin/tuxedo", { "+work", "due:today" }), { "/bin/tuxedo", "ls", "--json", "+work", "due:today" })
end)

test("session target precedence and first-run state", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "x" }, dir .. "/todo.txt")
  eq(cli.resolve_session_target({ cwd = dir, file = "explicit.txt", env = { TODO_FILE = "env.txt" } }).path, dir .. "/explicit.txt")
  eq(cli.resolve_session_target({ cwd = dir, env = { TODO_FILE = "env.txt", TODO_DIR = "other" } }).path, dir .. "/env.txt")
  eq(cli.resolve_session_target({ cwd = dir, env = { TODO_DIR = "other" } }).path, dir .. "/other/todo.txt")
  eq(cli.resolve_session_target({ cwd = dir, env = {} }).path, dir .. "/todo.txt")
  vim.fn.delete(dir, "rf")
  eq(cli.resolve_session_target({ cwd = dir, env = {} }).kind, "first_run")
  eq(cli.resolve_session_target({ cwd = dir, env = { TODO_FILE = "" } }).kind, "invalid")
end)

test("version parsing is display-only", function()
  local parsed = cli.parse_version("tuxedo 2026.8.1\n")
  eq(parsed.token, "2026.8.1")
  eq(parsed.raw, "tuxedo 2026.8.1\n")
  eq(cli.parse_version("  future-build\nnotes\n").display, "future-build")
  eq(cli.parse_version("\n").token, nil)
end)

test("add JSON preserves the documented result", function()
  local result = assert(cli.decode_add(
    '{"ok":true,"action":"add","task":{"n":1,"raw":"1 buy milk","done":false,"completed":"2026-09-19","projects":["work"],"contexts":["home"],"rec":"1w","t":"2026-09-20","future":true},"future":"ignored"}'
  ))
  eq(result.action, "add")
  eq(result.task.n, 1)
  eq(result.task.raw, "1 buy milk")
  eq(result.task.completed, "2026-09-19")
  eq(result.task.projects, { "work" })
  eq(result.task.contexts, { "home" })
  eq(result.task.rec, "1w")
  eq(result.task.t, "2026-09-20")
  eq(result.task.future, nil)
  local generic = assert(cli.decode_add('{"ok":true,"message":"accepted"}'))
  eq(generic.message, "accepted")
  local rejected, rejection, rejection_kind = cli.decode_add('{"ok":false,"error":"nope"}')
  eq(rejected, nil)
  eq(rejection.kind, "rejection")
  eq(rejection.message, "nope")
  eq(rejection_kind, "rejection")
end)

test("list normalization preserves documented fields and tolerates additions", function()
  local list = assert(cli.decode_list(
    '[{"n":1,"raw":"x","done":false,"completed":"2026-09-19","projects":["work"],"contexts":["home"],"rec":"1w","t":"2026-09-20","future":{"x":1}},{"text":"y","id":"two"}]'
  ))
  eq(list[1].n, 1)
  eq(list[1].raw, "x")
  eq(list[1].completed, "2026-09-19")
  eq(list[1].projects, { "work" })
  eq(list[1].contexts, { "home" })
  eq(list[1].rec, "1w")
  eq(list[1].t, "2026-09-20")
  eq(list[1].future, nil)
  eq(list[2].id, "two")
end)
test("malformed JSON and schema are distinguished", function()
  for _, value in ipairs({ "", "not json" }) do
    local result, detail, kind = cli.decode_list(value)
    eq(result, nil)
    eq(detail.kind, "json")
    eq(kind, "json")
  end
  local _, list_detail, list_schema = cli.decode_list("{}")
  eq(list_detail.kind, "schema")
  eq(list_schema, "schema")
  local _, item_detail, item_schema = cli.decode_list("[1]")
  eq(item_detail.kind, "schema")
  eq(item_schema, "schema")
  for _, value in ipairs({ "null", "false", "1", '"text"' }) do
    local _, detail, kind = cli.decode_list(value)
    eq(detail.kind, "schema")
    eq(kind, "schema")
  end
  local _, add_detail, add_schema = cli.decode_add("[]")
  local _, add_null_detail, add_null_schema = cli.decode_add("null")
  eq(add_null_detail.kind, "schema")
  eq(add_null_schema, "schema")
  eq(add_detail.kind, "schema")
  eq(add_schema, "schema")
end)

test("float geometry handles fractional absolute and tiny editors", function()
  local g = terminal.geometry(100, 40, { width = 0.9, height = 0.8, border = "rounded" })
  eq(g.width, 90)
  eq(g.height, 32)
  local absolute = terminal.geometry(20, 5, { width = 40, height = 3, border = "rounded" })
  eq(absolute.width, 20)
  eq(absolute.height, 3)
  local tiny = terminal.geometry(1, 1, { width = 0.01, height = 0.01, border = "rounded" })
  eq(tiny.width, 1)
  eq(tiny.height, 1)
end)

test("frozen target remains deterministic", function()
  local target = cli.resolve_session_target({ cwd = "/tmp/a", file = "one.txt", env = {} })
  local changed = cli.resolve_session_target({ cwd = "/tmp/other", file = "one.txt", env = { TODO_FILE = "two.txt" } })
  eq(target.path, "/tmp/a/one.txt")
  eq(changed.path, "/tmp/other/one.txt")
  ok(target.path ~= changed.path)
end)

test("sandbox probe cannot inherit outside task paths", function()
  local root = vim.fn.tempname()
  ok(vim.fn.mkdir(root, "p", 448) ~= 0)
  local fake = root .. "/tuxedo"
  write_fake_tuxedo(fake)
  local executable = assert(cli.resolve_executable(fake))
  local outside_todo = root .. "/outside-todo.txt"
  local outside_done = root .. "/outside-done.txt"
  local outside_dir = root .. "/outside"
  vim.fn.mkdir(outside_dir, "p")
  vim.fn.writefile({ "todo sentinel" }, outside_todo)
  vim.fn.writefile({ "done sentinel" }, outside_done)
  vim.fn.writefile({ "directory sentinel" }, outside_dir .. "/todo.txt")
  local names = { "TODO_FILE", "TODO_DIR", "DONE_FILE" }
  local previous = vim.fn.environ()
  vim.fn.setenv("TODO_FILE", outside_todo)
  vim.fn.setenv("TODO_DIR", outside_dir)
  vim.fn.setenv("DONE_FILE", outside_done)

  local report
  local success, err = xpcall(function()
    report = cli.probe(executable)
    eq(vim.fn.readfile(outside_todo), { "todo sentinel" })
    eq(vim.fn.readfile(outside_done), { "done sentinel" })
    eq(vim.fn.readfile(outside_dir .. "/todo.txt"), { "directory sentinel" })
    eq(report.tui, { entrypoint = true, launch_probed = false })
    ok(report.add.ok)
    ok(report.list.ok)
    eq(report.cleanup_warning, nil)
  end, debug.traceback)

  for _, name in ipairs(names) do
    if previous[name] == nil then
      vim.fn.setenv(name, nil)
    else
      vim.fn.setenv(name, previous[name])
    end
  end
  vim.fn.delete(root, "rf")
  if not success then
    error(err)
  end
end)

test("version failures do not parse nonzero stdout", function()
  with_system(function()
    return { code = 1, stdout = "tuxedo 9999.1", stderr = "broken" }
  end, function()
    local value, err = cli.version("/tmp/tuxedo")
    eq(value, nil)
    eq(err.kind, "exit")
    ok(err.message:find("installed version: unknown", 1, true) ~= nil)
  end)
end)

test("native process routing and normalized failures", function()
  local next_result
  with_system(function()
    return next_result
  end, function(state)
    local function add(result, context)
      next_result = result
      state.done = false
      local value, err
      cli.add("route me", context or { cwd = "/tmp/original", executable = "/tmp/tuxedo" }, function(result_value, result_error)
        value, err = result_value, result_error
        state.done = true
      end)
      await_state(state)
      return value, err
    end

    local value, err = add({ code = 0, stdout = '{"ok":true,"task":{"raw":"route me"}}', stderr = "" }, {
      cwd = "/tmp/original",
      executable = "/tmp/tuxedo",
      env = { TODO_FILE = "/tmp/parent.txt", CUSTOM = "preserved" },
      target = { kind = "deterministic", path = "/tmp/frozen/todo.txt" },
    })
    ok(value and not err)
    eq(state.calls[1].argv, { "/tmp/tuxedo", "add", "route me", "--json" })
    eq(state.calls[1].options.cwd, "/tmp/original")
    eq(state.calls[1].options.clear_env, true)
    eq(state.calls[1].options.env.TODO_FILE, "/tmp/frozen/todo.txt")
    eq(state.calls[1].options.env.CUSTOM, "preserved")

    local rejection_value, rejection = add({ code = 0, stdout = '{"ok":false,"error":"blocked"}', stderr = "" })
    eq(rejection_value, nil)
    eq(rejection.kind, "schema")
    eq(rejection.authoritative, true)
    eq(rejection.indeterminate, false)
    eq(rejection.retryable, false)

    local _, malformed = add({ code = 0, stdout = "not json", stderr = "" })
    eq(malformed.kind, "json")
    eq(malformed.indeterminate, true)
    eq(malformed.retryable, false)

    local _, shape = add({ code = 0, stdout = "[]", stderr = "" })
    eq(shape.kind, "schema")
    eq(shape.indeterminate, true)
    eq(shape.retryable, false)

    local _, exited = add({
      code = 2,
      stdout = '{"ok":true}',
      stderr = '{"ok":false,"action":"add","error":"disk is read-only"}',
    })
    eq(exited.kind, "exit")
    eq(exited.indeterminate, false)
    eq(exited.retryable, false)
    ok(exited.message:find("disk is read-only", 1, true) ~= nil)
    ok(exited.message:find('{"ok"', 1, true) == nil)

    local _, timed_out = add({ code = -1, timed_out = true, stdout = "", stderr = "" })
    eq(timed_out.kind, "timeout")
    eq(timed_out.indeterminate, true)
    eq(timed_out.retryable, false)

    local _, signaled = add({ code = 1, signal = 9, stdout = "", stderr = "" })
    eq(signaled.kind, "signal")
    eq(signaled.indeterminate, true)
    eq(signaled.retryable, false)

    local _, spawned = add(nil)
    eq(spawned.kind, "executable")
    eq(spawned.indeterminate, true)

    local first_run_value, first_run_error
    cli.add("route me", {
      cwd = "/tmp/original",
      executable = "/tmp/tuxedo",
      target = { kind = "first_run" },
    }, function(result_value, result_error)
      first_run_value, first_run_error = result_value, result_error
    end)
    eq(first_run_value, nil)
    eq(first_run_error.kind, "schema")
    ok(first_run_error.message:find("exit it with q or :TuxedoClose", 1, true) ~= nil)
    eq(#state.calls, 8)
  end)
end)

test("list process failures remain retryable and schema-aware", function()
  local next_result
  with_system(function()
    return next_result
  end, function(state)
    local function list(result)
      next_result = result
      state.done = false
      local value, err
      cli.list(nil, { cwd = "/tmp", executable = "/tmp/tuxedo" }, function(result_value, result_error)
        value, err = result_value, result_error
        state.done = true
      end)
      await_state(state)
      return value, err
    end
    local _, malformed = list({ code = 0, stdout = "not json", stderr = "" })
    eq(malformed.kind, "json")
    eq(malformed.retryable, true)
    local _, shape = list({ code = 0, stdout = "{}", stderr = "" })
    eq(shape.kind, "schema")
    eq(shape.retryable, true)
    local _, exited = list({ code = 3, stdout = "", stderr = "bad" })
    eq(exited.kind, "exit")
    eq(exited.retryable, true)
    local _, timed_out = list({ code = -1, timed_out = true, stdout = "", stderr = "" })
    eq(timed_out.kind, "timeout")
    eq(timed_out.retryable, true)
  end)
end)

test("probe reports unprobed TUI entry point independently and cleans sandbox", function()
  local marker
  local probe_dir
  with_system(function(argv, options)
    probe_dir = options.cwd
    if argv[2] == "--version" then
      return { code = 1, stdout = "", stderr = "version unavailable" }
    end
    local inherited_env = vim.fn.environ()
    eq(options.env.HOME, inherited_env.HOME)
    eq(options.env.PATH, inherited_env.PATH)
    if argv[2] == "add" then
      marker = argv[3]
      eq(vim.fn.getfperm(options.cwd), "rwx------")
      return { code = 0, stdout = '{"ok":true,"task":{"raw":"' .. marker .. '"}}', stderr = "" }
    end
    return { code = 0, stdout = '[{"raw":"' .. marker .. '"}]', stderr = "" }
  end, function()
    local report = cli.probe("/tmp/future-tuxedo")
    eq(report.tui, { entrypoint = true, launch_probed = false })
    eq(report.version, nil)
    ok(report.add.ok)
    ok(report.list.ok)
    eq(vim.fn.isdirectory(probe_dir), 0)
    ok(cli.parse_version("tuxedo 9999.1").token == "9999.1")
  end)
end)

test("public add reports asynchronous completion", function()
  local original_add = cli.add
  local original_notify = vim.notify
  vim.notify = function() end
  local callback_result
  local callback_error
  local callback_done = false
  cli.add = function(text, context, callback)
    eq(text, "callback task")
    ok(type(context.cwd) == "string")
    callback({ message = "accepted" }, nil)
  end
  local success, err = xpcall(function()
    eq(tuxedo.add("callback task", function(result, callback_err)
      callback_result = result
      callback_error = callback_err
      callback_done = true
    end), true)
    eq(callback_done, false, "completion callback must not run before add returns")
    ok(vim.wait(1000, function()
      return callback_done
    end, 10))
    eq(callback_result, { message = "accepted" })
    eq(callback_error, nil)
  end, debug.traceback)
  cli.add = original_add
  vim.notify = original_notify
  if not success then
    error(err)
  end
end)

test("public API rejects unsupported Neovim before side effects", function()
  terminal.close()
  config._reset()
  local original_version = vim.version
  local original_notify = vim.notify
  local notifications = {}
  local callback_error
  vim.version = function()
    return { major = 0, minor = 10, patch = 4 }
  end
  vim.notify = function(message)
    notifications[#notifications + 1] = message
  end
  local success, err = xpcall(function()
    local setup_result, setup_error = tuxedo.setup({ command = "/bin/false" })
    eq(setup_result, nil)
    ok(setup_error:find("requires Neovim 0.11", 1, true) ~= nil)
    eq(config.get().command, "tuxedo")
    local open_result, open_error = tuxedo.open()
    eq(open_result, nil)
    ok(open_error:find("requires Neovim 0.11", 1, true) ~= nil)
    eq(terminal.current(), nil)
    local add_result = tuxedo.add("guarded task", function(_, add_error)
      callback_error = add_error
    end)
    eq(add_result, nil)
    ok(vim.wait(1000, function()
      return callback_error ~= nil
    end, 10))
    eq(callback_error.kind, "version")
    ok(#notifications >= 3)
  end, debug.traceback)
  vim.version = original_version
  vim.notify = original_notify
  config._reset()
  if not success then
    error(err)
  end
end)

test("commands expose close and direct quick-add text", function()
  local original_add = tuxedo.add
  local original_close = tuxedo.close
  local original_input = vim.ui.input
  local added = {}
  local close_count = 0
  tuxedo.add = function(text)
    added[#added + 1] = text
    return true
  end
  tuxedo.close = function()
    close_count = close_count + 1
    return true, "closed"
  end
  vim.ui.input = function(opts, callback)
    eq(opts.prompt, "Tuxedo task: ")
    callback("prompted task")
  end
  local command_names = { "Tuxedo", "TuxedoToggle", "TuxedoClose", "TuxedoAdd" }
  local success, err = xpcall(function()
    for _, name in ipairs(command_names) do
      pcall(vim.api.nvim_del_user_command, name)
    end
    vim.g.loaded_tuxedo_nvim = nil
    dofile("plugin/tuxedo.lua")
    local commands = vim.api.nvim_get_commands({ builtin = false })
    ok(commands.TuxedoClose ~= nil)
    eq(commands.TuxedoAdd.nargs, "*")
    vim.cmd("TuxedoAdd task from command")
    vim.cmd("TuxedoAdd")
    vim.cmd("TuxedoClose")
    eq(added, { "task from command", "prompted task" })
    eq(close_count, 1)
  end, debug.traceback)
  for _, name in ipairs(command_names) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  vim.g.loaded_tuxedo_nvim = nil
  tuxedo.add = original_add
  tuxedo.close = original_close
  vim.ui.input = original_input
  if not success then
    error(err)
  end
end)

test("health invokes version exactly once", function()
  local root = vim.fn.tempname()
  ok(vim.fn.mkdir(root, "p", 448) ~= 0)
  local fake = root .. "/tuxedo"
  write_fake_tuxedo(fake)
  local original_system = vim.system
  local original_health = {}
  for _, name in ipairs({ "start", "ok", "info", "warn", "error" }) do
    original_health[name] = vim.health[name]
    vim.health[name] = function() end
  end
  local version_calls = 0
  vim.system = function(argv, options, callback)
    if argv[1] == fake and argv[2] == "--version" then
      version_calls = version_calls + 1
    end
    return original_system(argv, options, callback)
  end
  config._reset()
  config.setup({ command = fake })
  local success, err = xpcall(function()
    require("tuxedo.health").check()
    eq(version_calls, 1)
  end, debug.traceback)
  vim.system = original_system
  for name, value in pairs(original_health) do
    vim.health[name] = value
  end
  config._reset()
  vim.fn.delete(root, "rf")
  if not success then
    error(err)
  end
end)

test("terminal lifecycle preserves state and cleans stale sessions", function()
  terminal.close()
  local root = vim.fn.tempname()
  ok(vim.fn.mkdir(root, "p", 448) ~= 0)
  local fake = root .. "/tuxedo"
  local todo = root .. "/todo.txt"
  write_fake_tuxedo(fake)
  vim.fn.writefile({}, todo)
  local env_names = { "TODO_FILE", "TODO_DIR", "DONE_FILE" }
  local previous_env = vim.fn.environ()
  vim.fn.setenv("TODO_FILE", todo)
  vim.fn.setenv("TODO_DIR", root)
  vim.fn.setenv("DONE_FILE", root .. "/done.txt")
  local initial_tab = vim.api.nvim_get_current_tabpage()
  local initial_tabs = #vim.api.nvim_list_tabpages()
  config._reset()
  config.setup({ command = fake })

  local success, err = xpcall(function()
    local opened, state = tuxedo.open({ file = todo })
    eq(opened, true)
    eq(state, "visible")
    local first = assert(terminal.current())
    local first_buf = first.buf
    local first_job = first.job
    eq(vim.api.nvim_get_chan_info(first_job).mode, "terminal")
    local snapshot = tuxedo.status()
    eq(snapshot.state, "visible")
    snapshot.job = -1
    eq(terminal.current().job, first_job, "status must not expose mutable session state")

    local toggled, toggle_state = tuxedo.toggle()
    eq(toggled, true)
    eq(toggle_state, "hidden")
    eq(tuxedo.status().state, "hidden")
    eq(vim.fn.jobwait({ first_job }, 0)[1], -1)
    toggled, toggle_state = tuxedo.toggle()
    eq(toggled, true)
    eq(toggle_state, "visible")
    eq(terminal.current().buf, first_buf)
    eq(terminal.current().job, first_job)

    local externally_closed = terminal.current().win
    vim.api.nvim_win_close(externally_closed, true)
    ok(vim.wait(1000, function()
      return terminal.current() and terminal.current().win == nil
    end, 10))
    eq(tuxedo.open(), true)
    eq(terminal.current().buf, first_buf)
    eq(terminal.current().job, first_job)

    local normal_win = terminal.current().previous_win
    vim.api.nvim_set_current_win(normal_win)
    local caller_win = vim.api.nvim_get_current_win()
    eq(terminal.hide(), true)
    eq(vim.api.nvim_get_current_win(), caller_win, "hiding an unfocused float must preserve focus")
    eq(tuxedo.open(), true)

    vim.cmd("tabnew")
    local caller_tab = vim.api.nvim_get_current_tabpage()
    local cross_tab_caller = vim.api.nvim_get_current_win()
    eq(tuxedo.open(), true)
    eq(vim.api.nvim_win_get_tabpage(terminal.current().win), caller_tab)
    eq(vim.api.nvim_get_current_win(), terminal.current().win)
    eq(terminal.current().buf, first_buf)
    eq(terminal.current().job, first_job)
    local hidden, hidden_state = tuxedo.toggle()
    eq(hidden, true)
    eq(hidden_state, "hidden")
    eq(vim.api.nvim_get_current_win(), cross_tab_caller)
    vim.cmd("tabclose")

    eq(tuxedo.open(), true)
    config.setup({ float = { width = 0.5, height = 0.5 } })
    vim.api.nvim_exec_autocmds("VimResized", {})
    local expected = terminal.geometry(vim.o.columns, math.max(1, vim.o.lines - vim.o.cmdheight), config.get().float)
    eq(vim.api.nvim_win_get_width(terminal.current().win), expected.width)
    eq(vim.api.nvim_win_get_height(terminal.current().win), expected.height)

    vim.api.nvim_buf_delete(first_buf, { force = true })
    ok(vim.wait(1000, function()
      return terminal.current() == nil and vim.fn.jobwait({ first_job }, 0)[1] ~= -1
    end, 10), "wiping the terminal buffer must stop and detach its job")
    eq(tuxedo.open({ file = todo }), true)
    local second = assert(terminal.current())
    ok(second.buf ~= first_buf)
    ok(second.job ~= first_job)
    local second_buf = second.buf
    local second_job = second.job
    ok(vim.fn.chansend(second_job, "q\n") > 0)
    ok(vim.wait(1000, function()
      return terminal._current_session() == nil and not vim.api.nvim_buf_is_valid(second_buf)
    end, 10), "normal TUI exit must detach and delete the old session")
    eq(tuxedo.open({ file = todo }), true)
    local third = assert(terminal.current())
    ok(third.buf ~= second_buf)
    ok(third.job ~= second_job)
    local closed, close_state = tuxedo.close()
    eq(closed, true)
    eq(close_state, "closed")
    eq(tuxedo.status(), { state = "absent", visible = false })
    closed, close_state = tuxedo.close()
    eq(closed, true)
    eq(close_state, "absent")
  end, debug.traceback)

  terminal.close()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= initial_tab and vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.api.nvim_set_current_tabpage, tab)
      pcall(vim.cmd, "tabclose!")
    end
  end
  if vim.api.nvim_tabpage_is_valid(initial_tab) then
    pcall(vim.api.nvim_set_current_tabpage, initial_tab)
  end
  eq(#vim.api.nvim_list_tabpages(), initial_tabs)
  for _, name in ipairs(env_names) do
    if previous_env[name] == nil then
      vim.fn.setenv(name, nil)
    else
      vim.fn.setenv(name, previous_env[name])
    end
  end
  config._reset()
  vim.fn.delete(root, "rf")
  if not success then
    error(err)
  end
end)

for _, item in ipairs(tests) do
  local success, err = pcall(item.fn)
  if not success then
    failures[#failures + 1] = item.name .. ": " .. tostring(err)
  end
end

if #failures > 0 then
  for _, failure in ipairs(failures) do
    vim.api.nvim_err_writeln("FAIL " .. failure)
  end
  os.exit(1)
end
vim.api.nvim_out_write(string.format("%d tuxedo.nvim tests passed\n", #tests))
