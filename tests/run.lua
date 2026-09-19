package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local config = require("tuxedo.config")
local cli = require("tuxedo.cli")
local terminal = require("tuxedo.terminal")

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

test("permissive add JSON and authoritative rejection", function()
  local result = assert(cli.decode_add('{"ok":true,"task":{"raw":"1 buy milk","future":true},"future":"ignored"}'))
  eq(result.task.raw, "1 buy milk")
  local generic = assert(cli.decode_add('{"ok":true,"message":"accepted"}'))
  eq(generic.message, "accepted")
  local rejected, rejection, rejection_kind = cli.decode_add('{"ok":false,"error":"nope"}')
  eq(rejected, nil)
  eq(rejection.kind, "rejection")
  eq(rejection.message, "nope")
  eq(rejection_kind, "rejection")
end)

test("list normalization tolerates extra fields", function()
  local list = assert(cli.decode_list('[{"n":1,"raw":"x","done":false,"future":{"x":1}},{"text":"y","id":"two"}]'))
  eq(list[1].n, 1)
  eq(list[1].raw, "x")
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

test("outside task env sentinels survive sandbox probe", function()
  local executable = cli.resolve_executable("tuxedo")
  if not executable then
    return
  end
  local outside_dir = vim.fn.tempname()
  vim.fn.mkdir(outside_dir, "p")
  local outside_todo = outside_dir .. "/todo.txt"
  local outside_done = outside_dir .. "/done.txt"
  local outside_extra = outside_dir .. "/extra.txt"
  vim.fn.writefile({ "todo sentinel" }, outside_todo)
  vim.fn.writefile({ "done sentinel" }, outside_done)
  vim.fn.writefile({ "extra sentinel" }, outside_extra)
  local names = { "TODO_FILE", "TODO_DIR", "DONE_FILE" }
  local previous = vim.fn.environ()
  for _, name in ipairs(names) do
    local value = ({ TODO_FILE = outside_todo, TODO_DIR = outside_dir, DONE_FILE = outside_done })[name]
    vim.fn.setenv(name, value)
  end
  local success, report = pcall(cli.probe, executable)
  for _, name in ipairs(names) do
    if previous[name] == nil then
      vim.fn.setenv(name, nil)
    else
      vim.fn.setenv(name, previous[name])
    end
  end
  if not success then
    vim.fn.delete(outside_dir, "rf")
    error(report)
  end
  eq(vim.fn.readfile(outside_todo), { "todo sentinel" })
  eq(vim.fn.readfile(outside_done), { "done sentinel" })
  eq(vim.fn.readfile(outside_extra), { "extra sentinel" })
  vim.fn.delete(outside_dir, "rf")
  ok(report.tui ~= nil)
  ok(report.add ~= nil and report.list ~= nil)
  if report.cleanup_warning then
    error(report.cleanup_warning)
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

    local _, exited = add({ code = 2, stdout = '{"ok":true}', stderr = "rejected" })
    eq(exited.kind, "exit")
    eq(exited.indeterminate, false)
    eq(exited.retryable, false)

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

test("probe keeps TUI capability independent from version and cleans private sandbox", function()
  local marker
  local probe_dir
  with_system(function(argv, options)
    probe_dir = options.cwd
    if argv[2] == "--version" then
      return { code = 1, stdout = "", stderr = "version unavailable" }
    elseif argv[2] == "add" then
      marker = argv[3]
      eq(vim.fn.getfperm(options.cwd), "rwx------")
      return { code = 0, stdout = '{"ok":true,"task":{"raw":"' .. marker .. '"}}', stderr = "" }
    end
    return { code = 0, stdout = '[{"raw":"' .. marker .. '"}]', stderr = "" }
  end, function()
    local report = cli.probe("/tmp/future-tuxedo")
    eq(report.tui, true)
    eq(report.version, nil)
    ok(report.add.ok)
    ok(report.list.ok)
    eq(vim.fn.isdirectory(probe_dir), 0)
    ok(cli.parse_version("tuxedo 9999.1").token == "9999.1")
  end)
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
