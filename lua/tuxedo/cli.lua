local M = {}

local EXPECTED = "documented Tuxedo CLI: --version, add, ls --json, optional FILE, TODO_FILE/TODO_DIR/DONE_FILE"
local unpack_fn = table.unpack or unpack

local function cwd_or_default(cwd)
  if type(cwd) == "string" and cwd ~= "" then
    return cwd
  end
  if vim.uv and vim.uv.cwd then
    return vim.uv.cwd()
  end
  return vim.fn.getcwd()
end

local function path_is_absolute(path, win)
  if win then
    return path:match("^%a:/") ~= nil or path:sub(1, 2) == "//"
  end
  return path:sub(1, 1) == "/"
end

local function lexical_normalize(path, base, win)
  if type(path) ~= "string" or path == "" or vim.trim(path) == "" or path:find("%z") then
    return nil
  end
  if win == nil then
    win = package.config:sub(1, 1) == "\\"
  end
  base = cwd_or_default(base)
  if type(base) ~= "string" or base == "" then
    return nil
  end
  local normalize_opts = { expand_env = false, win = win }
  base = vim.fs.normalize(base, normalize_opts)
  if not path_is_absolute(base, win) then
    return nil
  end
  local normalized_path = vim.fs.normalize(path, normalize_opts)
  local joined
  if path_is_absolute(normalized_path, win) then
    joined = normalized_path
  elseif win and normalized_path:match("^%a:") then
    return nil
  elseif win and normalized_path:sub(1, 1) == "/" then
    local drive = base:match("^(%a:)/")
    if not drive then
      return nil
    end
    joined = drive .. normalized_path
  else
    joined = base:gsub("/$", "") .. "/" .. normalized_path
  end
  local normalized = vim.fs.normalize(joined, normalize_opts)
  if not path_is_absolute(normalized, win) then
    return nil
  end
  return normalized
end

local function copy_env(env)
  if type(env) ~= "table" then
    return nil
  end
  return vim.deepcopy(env)
end

local function raw_error(kind, message, fields)
  fields = fields or {}
  fields.kind = kind
  fields.message = message
  if fields.retryable == nil then
    fields.retryable = false
  end
  if fields.indeterminate == nil then
    fields.indeterminate = false
  end
  return fields
end

local function interface_message(message, capability, version)
  local installed = version and (version.display or version.token or version.raw) or "unknown"
  return string.format("%s (installed version: %s; expected interface: %s; failed capability: %s)", message, vim.trim(tostring(installed)), EXPECTED, capability)
end

local function result_signal(result)
  return result and result.signal and result.signal ~= 0 and result.signal ~= "0"
end

local function result_timeout(result)
  if not result then
    return false
  end
  if result.timed_out or result.timeout then
    return true
  end
  local stderr = tostring(result.stderr or ""):lower()
  return stderr:find("timed out", 1, true) ~= nil or result.code == 124
end

local function is_list(value)
  return type(value) == "table" and vim.islist(value)
end

local function decoder_error(kind, message)
  return { kind = kind, message = message }
end

local function decode_json(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return nil, decoder_error("json", "empty output"), "json", false
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok then
    return nil, decoder_error("json", tostring(value)), "json", false
  end
  return value, nil, nil, true
end

local recognized_item_fields = {
  completed = "string",
  context = "string",
  contexts = "string_list",
  created = "string",
  done = "boolean",
  due = "string",
  id = "number_or_string",
  n = "number",
  priority = "string",
  project = "string",
  projects = "string_list",
  raw = "string",
  rec = "string",
  t = "string",
  tags = "string_list",
  text = "string",
}

local function normalize_item(item)
  if type(item) ~= "table" or is_list(item) then
    return nil
  end
  local normalized = {}
  for key, kind in pairs(recognized_item_fields) do
    local value = item[key]
    if kind == "string" and type(value) == "string" then
      normalized[key] = value
    elseif kind == "number" and type(value) == "number" then
      normalized[key] = value
    elseif kind == "boolean" and type(value) == "boolean" then
      normalized[key] = value
    elseif kind == "number_or_string" and (type(value) == "number" or type(value) == "string") then
      normalized[key] = value
    elseif kind == "string_list" and type(value) == "table" and is_list(value) then
      local values = {}
      for _, entry in ipairs(value) do
        if type(entry) == "string" then
          values[#values + 1] = entry
        end
      end
      if #values == #value then
        normalized[key] = values
      end
    end
  end
  return normalized
end

function M.resolve_executable(command)
  if type(command) ~= "string" or vim.trim(command) == "" then
    return nil, "command must be a non-empty string"
  end
  if vim.fn.executable(command) ~= 1 then
    return nil, "executable not found: " .. command
  end
  local resolved = vim.fn.exepath(command)
  if type(resolved) ~= "string" or resolved == "" then
    return nil, "could not resolve executable: " .. command
  end
  local absolute = lexical_normalize(resolved, cwd_or_default())
  if not absolute then
    return nil, "resolved executable path is invalid: " .. resolved
  end
  return absolute
end

function M.normalize_path(path, cwd)
  return lexical_normalize(path, cwd)
end

function M.resolve_session_target(opts)
  opts = opts or {}
  local cwd = cwd_or_default(opts.cwd)
  if not lexical_normalize(cwd) then
    return { kind = "invalid", reason = "launch cwd is not an absolute normalized path" }
  end
  if opts.file ~= nil then
    local path = lexical_normalize(opts.file, cwd)
    if not path then
      return { kind = "invalid", reason = "explicit file is empty or cannot be normalized" }
    end
    return { kind = "deterministic", path = path, target = path, source = "file" }
  end
  local env = opts.env or {}
  if env.TODO_FILE ~= nil then
    local path = lexical_normalize(env.TODO_FILE, cwd)
    if not path then
      return { kind = "invalid", reason = "TODO_FILE is empty or cannot be normalized" }
    end
    return { kind = "deterministic", path = path, target = path, source = "TODO_FILE" }
  end
  if env.TODO_DIR ~= nil then
    local dir = lexical_normalize(env.TODO_DIR, cwd)
    if not dir then
      return { kind = "invalid", reason = "TODO_DIR is empty or cannot be normalized" }
    end
    local path = lexical_normalize(dir .. "/todo.txt", cwd)
    return { kind = "deterministic", path = path, target = path, source = "TODO_DIR" }
  end
  local local_file = lexical_normalize("todo.txt", cwd)
  if local_file and vim.fn.filereadable(local_file) == 1 then
    return { kind = "deterministic", path = local_file, target = local_file, source = "cwd" }
  end
  return { kind = "first_run" }
end

function M.build_tui_argv(executable, opts)
  opts = opts or {}
  local argv = { executable }
  if opts.file ~= nil then
    local path = lexical_normalize(opts.file, opts.cwd)
    if not path then
      return nil, "file is empty or cannot be normalized"
    end
    argv[#argv + 1] = path
  end
  return argv
end

function M.build_add_argv(executable, text)
  return { executable, "add", text, "--json" }
end

function M.build_list_argv(executable, filters)
  local argv = { executable, "ls", "--json" }
  if type(filters) == "string" and filters ~= "" then
    argv[#argv + 1] = filters
  elseif type(filters) == "table" then
    local values = filters.args or filters
    if is_list(values) then
      for _, value in ipairs(values) do
        if type(value) == "string" and value ~= "" then
          argv[#argv + 1] = value
        end
      end
    end
  end
  return argv
end

function M.parse_version(stdout)
  local raw = type(stdout) == "string" and stdout or ""
  local display
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if vim.trim(line) ~= "" then
      display = vim.trim(line)
      break
    end
  end
  display = display or vim.trim(raw)
  local token = display:match("^[Tt][Uu][Xx][Ee][Dd][Oo]%s+([^%s]+)")
  return { token = token, version = token, display = display, raw = raw }
end

function M.decode_add(stdout)
  local value, err, kind, parsed = decode_json(stdout)
  if not parsed then
    return nil, err, kind
  end
  if type(value) ~= "table" or is_list(value) then
    return nil, decoder_error("schema", "top-level add result is not an object"), "schema"
  end
  if value.ok == false then
    return nil, decoder_error("rejection", tostring(value.error or value.message or "Tuxedo rejected add")), "rejection"
  end
  local result = { ok = true }
  if type(value.action) == "string" then
    result.action = value.action
  end
  if type(value.task) == "table" then
    local task = normalize_item(value.task)
    if task then
      result.task = task
    end
  elseif type(value.task) == "string" then
    result.task = { raw = value.task }
  end
  if type(value.raw) == "string" then
    result.raw = value.raw
  end
  if type(value.message) == "string" then
    result.message = value.message
  end
  return result
end

function M.decode_list(stdout)
  local value, err, kind, parsed = decode_json(stdout)
  if not parsed then
    return nil, err, kind
  end
  if not is_list(value) then
    return nil, decoder_error("schema", "top-level list result is not an array"), "schema"
  end
  local result = {}
  for index, item in ipairs(value) do
    local normalized = normalize_item(item)
    if not normalized then
      return nil, decoder_error("schema", "list item " .. index .. " is not an object"), "schema"
    end
    result[#result + 1] = normalized
  end
  return result
end

local function executable_error(message, capability, retryable)
  return raw_error("executable", interface_message(message, capability, nil), { retryable = retryable })
end

local function process_detail(stderr)
  local detail = vim.trim(tostring(stderr or ""))
  if detail == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, detail)
  if ok and type(decoded) == "table" and not is_list(decoded) then
    local decoded_detail = decoded.error or decoded.message
    if type(decoded_detail) == "string" and decoded_detail ~= "" then
      detail = decoded_detail
    end
  end
  detail = detail:gsub("%s+", " ")
  if vim.fn.strchars(detail) > 500 then
    detail = vim.fn.strcharpart(detail, 0, 500) .. "…"
  end
  return detail
end

local function process_error(result, capability, mutating, version)
  local stderr = result and tostring(result.stderr or "") or ""
  local detail = process_detail(stderr)
  local function message(text)
    if detail then
      text = text .. ": " .. detail
    end
    return interface_message(text, capability, version)
  end
  if result_timeout(result) then
    return raw_error("timeout", message("Tuxedo process timed out"), {
      stderr = stderr,
      indeterminate = mutating,
      retryable = not mutating,
    })
  end
  if result_signal(result) then
    return raw_error("signal", message("Tuxedo process was terminated by a signal"), {
      stderr = stderr,
      indeterminate = mutating,
      retryable = not mutating,
    })
  end
  return raw_error("exit", message("Tuxedo exited unsuccessfully"), {
    code = result and result.code,
    stderr = stderr,
    indeterminate = false,
    retryable = not mutating,
  })
end

local function process_options(context)
  local opts = {
    text = true,
    timeout = 10000,
  }
  if context.cwd then
    opts.cwd = context.cwd
  end
  if context.env then
    opts.env = context.env
    opts.clear_env = true
  end
  return opts
end

local function prepare_context(context, capability, mutating)
  context = context or {}
  local cwd = cwd_or_default(context.cwd)
  local executable = context.executable
  if not executable then
    local err
    executable, err = M.resolve_executable(require("tuxedo.config").get().command)
    if not executable then
      return nil, executable_error(err, capability, not mutating)
    end
  else
    local normalized = lexical_normalize(executable, cwd)
    if not normalized then
      return nil, executable_error("invalid executable path", capability, not mutating)
    end
    executable = normalized
  end
  local target = context.target
  local env = copy_env(context.env)
  if target then
    local kind = target.kind
    if kind == "first_run" or kind == "invalid" then
      return nil, raw_error("schema", interface_message("active Tuxedo session has no deterministic task file; exit it with q or :TuxedoClose, then reopen with an explicit file or valid TODO_FILE/TODO_DIR before quick-add", capability, nil), { retryable = false })
    end
    local path = target.path or target.target or target
    path = lexical_normalize(path, cwd)
    if not path then
      return nil, raw_error("schema", interface_message("active Tuxedo session target is invalid", capability, nil), { retryable = false })
    end
    env = env or (vim.fn.environ and vim.fn.environ() or {})
    env.TODO_FILE = path
  end
  return { cwd = cwd, executable = executable, env = env, target = target }
end

local function async_system(argv, context, callback)
  local options = process_options(context)
  local scheduled = vim.schedule_wrap(callback)
  local ok, handle = pcall(vim.system, argv, options, scheduled)
  if not ok then
    scheduled(nil, raw_error("executable", interface_message("could not start Tuxedo: " .. tostring(handle), "spawn", nil), { retryable = false }))
    return
  end
  if not handle then
    scheduled(nil, raw_error("executable", interface_message("could not start Tuxedo", "spawn", nil), { retryable = false }))
  end
end

local function decoder_text(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

function M.add(text, context, callback)
  callback = callback or function() end
  if type(text) ~= "string" or vim.trim(text) == "" then
    callback(nil, raw_error("schema", "Tuxedo task text must be non-empty", { retryable = false }))
    return
  end
  local prepared, err = prepare_context(context, "add", true)
  if not prepared then
    callback(nil, err)
    return
  end
  local argv = M.build_add_argv(prepared.executable, text)
  async_system(argv, prepared, function(result, transport_error)
    if transport_error then
      callback(nil, transport_error)
      return
    end
    if not result then
      callback(nil, raw_error("executable", interface_message("Tuxedo returned no process result", "add", nil), { indeterminate = true }))
      return
    end
    if result.code ~= 0 or result_signal(result) or result_timeout(result) then
      callback(nil, process_error(result, "add", true))
      return
    end
    local decoded, decode_err, decode_kind = M.decode_add(result.stdout)
    if not decoded then
      local failure_kind = decode_kind or (type(decode_err) == "table" and decode_err.kind) or "json"
      local failure_message = decoder_text(decode_err)
      if failure_kind == "rejection" then
        callback(nil, raw_error("schema", interface_message("Tuxedo rejected add: " .. failure_message, "add rejection", nil), {
          stderr = tostring(result.stderr or ""),
          authoritative = true,
          indeterminate = false,
          retryable = false,
        }))
      else
        callback(nil, raw_error(failure_kind, interface_message("Tuxedo add returned unexpected JSON: " .. failure_message, "add JSON", nil), {
          stderr = tostring(result.stderr or ""),
          indeterminate = true,
          retryable = false,
        }))
      end
      return
    end
    callback(decoded, nil)
  end)
end

function M.list(filters, context, callback)
  callback = callback or function() end
  local prepared, err = prepare_context(context, "list", false)
  if not prepared then
    callback(nil, err)
    return
  end
  local argv = M.build_list_argv(prepared.executable, filters)
  async_system(argv, prepared, function(result, transport_error)
    if transport_error then
      transport_error.retryable = true
      callback(nil, transport_error)
      return
    end
    if not result then
      callback(nil, raw_error("executable", interface_message("Tuxedo returned no process result", "list", nil), { retryable = true }))
      return
    end
    if result.code ~= 0 or result_signal(result) or result_timeout(result) then
      callback(nil, process_error(result, "list", false))
      return
    end
    local decoded, decode_err, decode_kind = M.decode_list(result.stdout)
    if not decoded then
      local failure_kind = decode_kind or (type(decode_err) == "table" and decode_err.kind) or "json"
      callback(nil, raw_error(failure_kind, interface_message("Tuxedo list returned unexpected JSON: " .. decoder_text(decode_err), "list JSON", nil), {
        stderr = tostring(result.stderr or ""),
        retryable = true,
      }))
      return
    end
    callback(decoded, nil)
  end)
end

local function run_sync(argv, options)
  local ok, handle = pcall(vim.system, argv, options)
  if not ok then
    return nil, tostring(handle)
  end
  local waited_ok, result = pcall(handle.wait, handle)
  if not waited_ok then
    return nil, tostring(result)
  end
  return result
end

function M.version(executable)
  if not executable then
    return nil, executable_error("Tuxedo executable is not available", "--version", true)
  end
  local result, err = run_sync({ executable, "--version" }, { text = true, timeout = 5000 })
  if not result then
    return nil, raw_error("executable", interface_message("could not invoke Tuxedo --version: " .. tostring(err), "--version", nil), { retryable = true })
  end
  if result.code ~= 0 or result_signal(result) or result_timeout(result) then
    return nil, process_error(result, "--version", false)
  end
  local parsed = M.parse_version(result.stdout)
  parsed.stderr = tostring(result.stderr or "")
  parsed.code = result.code
  return parsed
end

local function make_probe_dir()
  local dir = vim.fn.tempname()
  if vim.fn.mkdir(dir, "p", 448) ~= 1 or vim.fn.isdirectory(dir) ~= 1 then
    return nil, "could not create private temporary probe directory"
  end
  return dir
end

local function cleanup_probe(dir)
  local ok, result = pcall(vim.fn.delete, dir, "rf")
  if not ok or result ~= 0 or vim.fn.isdirectory(dir) == 1 then
    return "probe cleanup failed; retained temporary path: " .. dir
  end
end

function M.probe(executable)
  local report = {
    tui = { entrypoint = executable ~= nil, launch_probed = false },
    add = { ok = false },
    list = { ok = false },
  }
  local version, version_error = M.version(executable)
  report.version = version
  report.version_error = version_error
  if not executable then
    report.tui.error = version_error
    local failure = version_error or raw_error("executable", interface_message("Tuxedo executable is not available", "executable/TUI", nil), { retryable = true })
    report.add.error = failure
    report.list.error = failure
    return report
  end

  local dir, dir_error = make_probe_dir()
  if not dir then
    local failure = raw_error("executable", interface_message(dir_error, "sandbox", version), { retryable = true })
    report.add.error = failure
    report.list.error = failure
    return report
  end

  local probe_ok, probe_error = pcall(function()
    local todo = lexical_normalize(dir .. "/todo.txt", dir)
    local done = lexical_normalize(dir .. "/done.txt", dir)
    if not todo or not done then
      error("could not normalize sandbox task paths")
    end
    vim.fn.writefile({}, todo)
    vim.fn.writefile({}, done)
    local env = copy_env(vim.fn.environ()) or {}
    env.TODO_FILE = todo
    env.TODO_DIR = dir
    env.DONE_FILE = done
    env.TUXEDO_NO_UPDATE_CHECK = "1"
    local marker = "tuxedo-nvim-probe-" .. tostring((vim.uv and vim.uv.hrtime and vim.uv.hrtime()) or os.time())
    local add_result, add_run_error = run_sync(M.build_add_argv(executable, marker), {
      text = true,
      timeout = 5000,
      cwd = dir,
      env = env,
      clear_env = true,
    })
    if not add_result then
      report.add.error = raw_error("executable", interface_message("could not run sandbox add: " .. tostring(add_run_error), "add", version), { retryable = true })
    elseif add_result.code ~= 0 or result_signal(add_result) or result_timeout(add_result) then
      report.add.error = process_error(add_result, "add", true, version)
    else
      local decoded, decode_error, decode_kind = M.decode_add(add_result.stdout)
      if decoded then
        report.add.ok = true
        report.add.result = decoded
      elseif decode_kind == "rejection" or (type(decode_error) == "table" and decode_error.kind == "rejection") then
        report.add.error = raw_error("schema", interface_message("sandbox add was rejected: " .. decoder_text(decode_error), "add rejection", version), {
          retryable = false,
          authoritative = true,
        })
      else
        local failure_kind = decode_kind or (type(decode_error) == "table" and decode_error.kind) or "json"
        report.add.error = raw_error(failure_kind, interface_message("sandbox add returned unexpected JSON: " .. decoder_text(decode_error), "add JSON", version), {
          retryable = false,
          indeterminate = true,
        })
      end
    end

    local list_result, list_run_error = run_sync(M.build_list_argv(executable), {
      text = true,
      timeout = 5000,
      cwd = dir,
      env = env,
      clear_env = true,
    })
    if not list_result then
      report.list.error = raw_error("executable", interface_message("could not run sandbox list: " .. tostring(list_run_error), "list", version), { retryable = true })
    elseif list_result.code ~= 0 or result_signal(list_result) or result_timeout(list_result) then
      report.list.error = process_error(list_result, "list", false, version)
    else
      local decoded, decode_error, decode_kind = M.decode_list(list_result.stdout)
      if not decoded then
        local failure_kind = decode_kind or (type(decode_error) == "table" and decode_error.kind) or "json"
        report.list.error = raw_error(failure_kind, interface_message("sandbox list returned unexpected JSON: " .. decoder_text(decode_error), "list JSON", version), { retryable = true })
      else
        local found = false
        for _, item in ipairs(decoded) do
          if (type(item.raw) == "string" and item.raw:find(marker, 1, true)) or item.text == marker then
            found = true
            break
          end
        end
        if found or not report.add.ok then
          report.list.ok = true
          report.list.result = decoded
        else
          report.list.error = raw_error("schema", interface_message("sandbox list did not expose the added marker", "list marker", version), { retryable = true })
        end
      end
    end
  end)

  if not probe_ok then
    local failure = raw_error("executable", interface_message("sandbox probe failed: " .. tostring(probe_error), "sandbox", version), { retryable = true })
    report.add.error = report.add.error or failure
    report.list.error = report.list.error or failure
  end
  report.cleanup_warning = cleanup_probe(dir)
  return report
end
M._lexical_normalize = lexical_normalize
M._run_sync = run_sync
M.expected_interface = EXPECTED

return M
