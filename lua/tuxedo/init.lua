local config = require("tuxedo.config")
local cli = require("tuxedo.cli")
local terminal = require("tuxedo.terminal")

local M = {}
local title = "tuxedo.nvim"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = title })
end

local function require_supported()
  local version = vim.version()
  if version.major > 0 or version.minor >= 11 then
    return true
  end
  local message = string.format(
    "tuxedo.nvim requires Neovim 0.11 or newer; current version is %d.%d.%d",
    version.major,
    version.minor,
    version.patch or 0
  )
  notify(message, vim.log.levels.ERROR)
  return nil, message
end

local function completion_error(kind, message)
  return {
    kind = kind,
    message = message,
    retryable = false,
    indeterminate = false,
  }
end

local function complete_later(callback, result, err)
  if not callback then
    return
  end
  vim.schedule(function()
    callback(result, err)
  end)
end

local function validate_open(opts)
  if opts == nil then
    return {}
  end
  if type(opts) ~= "table" then
    return nil, "open options must be a table"
  end
  for key in pairs(opts) do
    if key ~= "file" then
      return nil, "unknown open option: " .. tostring(key)
    end
  end
  if opts.file ~= nil and (type(opts.file) ~= "string" or vim.trim(opts.file) == "") then
    return nil, "file must be a non-empty string"
  end
  return opts
end

function M.setup(opts)
  local supported, err = require_supported()
  if not supported then
    return nil, err
  end
  return config.setup(opts)
end

function M.open(opts)
  local supported, version_error = require_supported()
  if not supported then
    return nil, version_error
  end
  local valid, err = validate_open(opts)
  if not valid then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  local record, open_error = terminal.open(valid)
  if not record then
    return nil, open_error
  end
  return true, "visible"
end

function M.toggle()
  local supported, version_error = require_supported()
  if not supported then
    return nil, version_error
  end
  local state, err = terminal.toggle()
  if not state then
    return nil, err
  end
  return true, state
end

function M.close()
  local supported, version_error = require_supported()
  if not supported then
    return nil, version_error
  end
  return true, terminal.close() and "closed" or "absent"
end

function M.status()
  return terminal.status()
end

function M.add(text, callback)
  if callback ~= nil and type(callback) ~= "function" then
    local message = "add callback must be a function"
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end
  local supported, version_error = require_supported()
  if not supported then
    complete_later(callback, nil, completion_error("version", version_error))
    return nil, version_error
  end
  if type(text) ~= "string" or vim.trim(text) == "" then
    local message = "Tuxedo task cannot be blank"
    notify(message, vim.log.levels.WARN)
    complete_later(callback, nil, completion_error("schema", message))
    return nil, "blank task"
  end
  local context = terminal.context()
  if not context then
    context = { cwd = vim.fn.getcwd() }
  end
  cli.add(text, context, function(result, err)
    if err then
      local message = err.message or tostring(err)
      if err.indeterminate then
        message = message .. "; inspect Tuxedo before retrying"
      end
      notify(message, vim.log.levels.ERROR)
    else
      local task
      if result and result.task then
        task = result.task.raw or result.task.text
      end
      task = task or (result and (result.raw or result.message)) or "task added"
      notify("Added: " .. task)
    end
    complete_later(callback, result, err)
  end)
  return true
end

function M._config()
  return config
end

function M._cli()
  return cli
end

return M
