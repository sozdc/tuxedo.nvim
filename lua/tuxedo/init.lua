local config = require("tuxedo.config")
local cli = require("tuxedo.cli")
local terminal = require("tuxedo.terminal")

local M = {}
local title = "tuxedo.nvim"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = title })
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
  return config.setup(opts)
end

function M.open(opts)
  local valid, err = validate_open(opts)
  if not valid then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  return terminal.open(valid)
end

function M.toggle()
  return terminal.toggle()
end

function M.add(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    notify("Tuxedo task cannot be blank", vim.log.levels.WARN)
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
      return
    end
    local task
    if result and result.task then
      task = result.task.raw or result.task.text
    end
    task = task or (result and result.raw) or "task added"
    notify("Added: " .. task)
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
