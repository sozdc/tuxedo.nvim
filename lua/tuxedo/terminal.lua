local config = require("tuxedo.config")
local cli = require("tuxedo.cli")

local M = {}
local current_session
local augroup

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "tuxedo.nvim" })
end

local function valid_window(win)
  return win and win > 0 and vim.api.nvim_win_is_valid(win)
end

local function valid_buffer(buf)
  return buf and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

local function same_tab(win, tab)
  return valid_window(win) and vim.api.nvim_win_get_tabpage(win) == tab
end

function M.geometry(columns, lines, float)
  columns = math.max(1, tonumber(columns) or 1)
  lines = math.max(1, tonumber(lines) or 1)
  float = float or config.get().float
  local function dimension(value, total)
    local size
    if value <= 1 then
      size = math.floor(total * value)
    else
      size = math.floor(value)
    end
    return math.max(1, math.min(total, size))
  end
  local width = dimension(float.width, columns)
  local height = dimension(float.height, lines)
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
  }
end

local function window_config()
  local geometry = M.geometry(vim.o.columns, math.max(1, vim.o.lines - vim.o.cmdheight), config.get().float)
  geometry.relative = "editor"
  geometry.style = "minimal"
  geometry.border = config.get().float.border
  return geometry
end

local function live(record)
  return current_session == record and not record.closing and valid_buffer(record.buf) and record.job and record.job > 0 and vim.fn.jobwait({ record.job }, 0)[1] == -1
end

local function restore_focus(record, owner, tab, previous)
  if not owner or not tab or vim.api.nvim_get_current_tabpage() ~= tab then
    return
  end
  if same_tab(previous, tab) then
    pcall(vim.api.nvim_set_current_win, previous)
  end
end

local function cleanup_record(record, opts)
  opts = opts or {}
  if current_session == record then
    current_session = nil
  end
  record.closing = true
  local old_win = record.win
  local owner = valid_window(old_win) and vim.api.nvim_get_current_win() == old_win
  local tab = valid_window(old_win) and vim.api.nvim_win_get_tabpage(old_win) or vim.api.nvim_get_current_tabpage()
  local previous = record.previous_win
  record.win = nil
  if opts.stop_job and record.job and record.job > 0 then
    local status = vim.fn.jobwait({ record.job }, 0)[1]
    if status == -1 then
      pcall(vim.fn.jobstop, record.job)
    end
  end
  if valid_window(old_win) and not opts.skip_window then
    pcall(vim.api.nvim_win_close, old_win, true)
  end
  if valid_buffer(record.buf) and not opts.skip_buffer then
    pcall(vim.api.nvim_buf_delete, record.buf, { force = true })
  end
  if not opts.skip_focus then
    restore_focus(record, owner, tab, previous)
  end
end

local function stale_cleanup(record)
  if current_session ~= record then
    return
  end
  cleanup_record(record, { stop_job = false })
end

local function schedule_insert(record)
  vim.schedule(function()
    if live(record) and valid_window(record.win) and vim.api.nvim_get_current_win() == record.win then
      pcall(vim.cmd, "startinsert")
    end
  end)
end

local function on_job_exit(record, job_id, code)
  if current_session ~= record or record.job ~= job_id or record.closing then
    return
  end
  local message
  if code and code ~= 0 then
    message = string.format("Tuxedo exited with code %s; run :checkhealth tuxedo", tostring(code))
  end
  cleanup_record(record, { stop_job = false })
  if message then
    notify(message, vim.log.levels.ERROR)
  end
end

local function set_buffer_options(buf)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "tuxedo"
  vim.bo[buf].modifiable = false
end

local function open_float(record, caller_win)
  if not valid_buffer(record.buf) then
    return nil, "Tuxedo terminal buffer is no longer valid"
  end
  local caller_tab = vim.api.nvim_get_current_tabpage()
  local existing = record.win
  if valid_window(existing) then
    local existing_tab = vim.api.nvim_win_get_tabpage(existing)
    if existing_tab == caller_tab then
      if caller_win ~= existing then
        record.previous_win = caller_win
        pcall(vim.api.nvim_set_current_win, existing)
      end
      return existing
    end
    record.win = nil
    pcall(vim.api.nvim_win_close, existing, true)
  else
    record.win = nil
  end
  record.previous_win = caller_win
  local ok, win = pcall(vim.api.nvim_open_win, record.buf, true, window_config())
  if not ok or not win then
    return nil, "could not create Tuxedo floating window: " .. tostring(win)
  end
  record.win = win
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  pcall(vim.api.nvim_win_set_option, win, "winhl", "Normal:Normal,FloatBorder:FloatBorder")
  pcall(vim.fn.jobresize, record.job, window_config().width, window_config().height)
  return win
end

local function same_requested_target(record, opts)
  if not opts or opts.file == nil then
    return true
  end
  local requested = cli.resolve_session_target({ file = opts.file, cwd = vim.fn.getcwd(), env = record.env })
  if requested.kind ~= "deterministic" or record.target.kind ~= "deterministic" then
    return false
  end
  return requested.path == record.target.path
end

local function ensure_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("TuxedoNvim", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local record = current_session
      local win = tonumber(args.match)
      if record and record.win == win then
        record.win = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(args)
      local record = current_session
      if not record or record.buf ~= args.buf then
        return
      end
      record.closing = true
      current_session = nil
      record.win = nil
      local job = record.job
      vim.schedule(function()
        if job and job > 0 and vim.fn.jobwait({ job }, 0)[1] == -1 then
          pcall(vim.fn.jobstop, job)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      local record = current_session
      if not record or not live(record) or not valid_window(record.win) then
        return
      end
      local geometry = window_config()
      pcall(vim.api.nvim_win_set_config, record.win, geometry)
      local width = vim.api.nvim_win_get_width(record.win)
      local height = vim.api.nvim_win_get_height(record.win)
      pcall(vim.fn.jobresize, record.job, width, height)
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function(args)
      local record = current_session
      if record and valid_buffer(record.buf) and args.buf == record.buf then
        schedule_insert(record)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      local record = current_session
      if record then
        cleanup_record(record, { stop_job = true, skip_window = true, skip_focus = true })
      end
    end,
  })
end

local function launch(opts)
  local cwd = vim.fn.getcwd()
  local env = vim.fn.environ()
  local executable, executable_error = cli.resolve_executable(config.get().command)
  if not executable then
    notify("Tuxedo executable unavailable: " .. tostring(executable_error), vim.log.levels.ERROR)
    return nil, executable_error
  end
  local target = cli.resolve_session_target({ file = opts.file, cwd = cwd, env = env })
  local argv, argv_error = cli.build_tui_argv(executable, { file = opts.file, cwd = cwd })
  if not argv then
    notify("Cannot open Tuxedo: " .. tostring(argv_error), vim.log.levels.ERROR)
    return nil, argv_error
  end
  local record = {
    buf = vim.api.nvim_create_buf(false, true),
    win = nil,
    job = nil,
    previous_win = vim.api.nvim_get_current_win(),
    target = target,
    cwd = cwd,
    executable = executable,
    env = vim.deepcopy(env),
    closing = false,
  }
  current_session = record
  ensure_autocmds()
  vim.bo[record.buf].buflisted = false
  vim.bo[record.buf].bufhidden = "hide"
  vim.bo[record.buf].swapfile = false
  local win, win_error = open_float(record, record.previous_win)
  if not win then
    cleanup_record(record, { stop_job = false })
    notify(win_error, vim.log.levels.ERROR)
    return nil, win_error
  end
  local job = vim.fn.jobstart(argv, {
    term = true,
    cwd = cwd,
    env = record.env,
    clear_env = true,
    on_exit = vim.schedule_wrap(function(job_id, code)
      on_job_exit(record, job_id, code)
    end),
  })
  if not job or job <= 0 then
    cleanup_record(record, { stop_job = false })
    local message = "could not start Tuxedo terminal job"
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end
  record.job = job
  set_buffer_options(record.buf)
  schedule_insert(record)
  return record
end

function M.open(opts)
  opts = opts or {}
  if type(opts) ~= "table" or (opts.file ~= nil and (type(opts.file) ~= "string" or vim.trim(opts.file) == "")) then
    notify("Tuxedo open expects an optional non-empty file string", vim.log.levels.ERROR)
    return nil, "invalid open options"
  end
  ensure_autocmds()
  if current_session and not live(current_session) then
    stale_cleanup(current_session)
  end
  if current_session and live(current_session) then
    if not same_requested_target(current_session, opts) then
      local message = "a Tuxedo session is already open for a different task file; close it before opening another"
      notify(message, vim.log.levels.ERROR)
      return nil, message
    end
    local caller = vim.api.nvim_get_current_win()
    local win, err = open_float(current_session, caller)
    if not win then
      notify(err, vim.log.levels.ERROR)
      return nil, err
    end
    schedule_insert(current_session)
    return current_session
  end
  return launch(opts)
end

function M.hide()
  local record = current_session
  if not record or not live(record) or not valid_window(record.win) then
    return false
  end
  local win = record.win
  local owner = vim.api.nvim_get_current_win() == win
  local tab = vim.api.nvim_win_get_tabpage(win)
  local previous = record.previous_win
  record.win = nil
  pcall(vim.api.nvim_win_close, win, true)
  restore_focus(record, owner, tab, previous)
  return true
end

function M.toggle()
  local record = current_session
  if record and not live(record) then
    stale_cleanup(record)
    record = nil
  end
  if not record then
    return M.open({})
  end
  if valid_window(record.win) and vim.api.nvim_win_get_tabpage(record.win) == vim.api.nvim_get_current_tabpage() then
    M.hide()
    return nil
  end
  return M.open({})
end

function M.close()
  if current_session then
    cleanup_record(current_session, { stop_job = true })
  end
end

function M.current()
  if current_session and live(current_session) then
    return current_session
  end
  return nil
end

function M.context()
  local record = M.current()
  if not record then
    return nil
  end
  return {
    cwd = record.cwd,
    target = record.target,
    executable = record.executable,
    env = vim.deepcopy(record.env),
  }
end

M._live = live
M._current_session = function()
  return current_session
end

return M
