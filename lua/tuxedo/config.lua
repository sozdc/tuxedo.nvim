local M = {}

local defaults = {
  command = "tuxedo",
  float = {
    width = 0.90,
    height = 0.90,
    border = "rounded",
  },
}

local current = vim.deepcopy(defaults)

local borders = {
  none = true,
  single = true,
  double = true,
  rounded = true,
  solid = true,
  shadow = true,
  bold = true,
}

local function fail(message)
  error("tuxedo.nvim: " .. message, 2)
end
local function valid_size(value, name)
  if type(value) ~= "number" or value ~= value or value <= 0 then
    fail(name .. " must be a positive number")
  end
  return value
end

local function valid_border(value)
  if type(value) == "string" then
    if not borders[value] then
      fail("float.border must be a supported border name")
    end
    return value
  end
  if type(value) ~= "table" or not vim.islist(value) or not ({ [1] = true, [2] = true, [4] = true, [8] = true })[#value] then
    fail("float.border must be a supported border name or a 1-, 2-, 4-, or 8-element table")
  end
  for _, entry in ipairs(value) do
    if type(entry) == "string" then
      -- Empty strings are valid border characters and hide that side.
    elseif type(entry) == "table" and vim.islist(entry) and #entry == 2 and type(entry[1]) == "string" and type(entry[2]) == "string" then
      -- [character, highlight] entries are accepted by nvim_open_win().
    else
      fail("float.border entries must be strings or { character, highlight } pairs")
    end
  end
  return vim.deepcopy(value)
end

local function validate(opts)
  if opts == nil then
    return {}
  end
  if type(opts) ~= "table" then
    fail("setup options must be a table")
  end
  for key in pairs(opts) do
    if key ~= "command" and key ~= "float" then
      fail("unknown option: " .. tostring(key))
    end
  end
  local out = {}
  if opts.command ~= nil then
    if type(opts.command) ~= "string" or vim.trim(opts.command) == "" then
      fail("command must be a non-empty string")
    end
    out.command = opts.command
  end
  if opts.float ~= nil then
    if type(opts.float) ~= "table" then
      fail("float must be a table")
    end
    for key in pairs(opts.float) do
      if key ~= "width" and key ~= "height" and key ~= "border" then
        fail("unknown float option: " .. tostring(key))
      end
    end
    out.float = {}
    if opts.float.width ~= nil then
      out.float.width = valid_size(opts.float.width, "float.width")
    end
    if opts.float.height ~= nil then
      out.float.height = valid_size(opts.float.height, "float.height")
    end
    if opts.float.border ~= nil then
      out.float.border = valid_border(opts.float.border)
    end
  end
  return out
end

function M.setup(opts)
  local validated = validate(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(current), validated)
  return M.get()
end

function M.get()
  return vim.deepcopy(current)
end

function M.defaults()
  return vim.deepcopy(defaults)
end

function M._reset()
  current = vim.deepcopy(defaults)
end

return M
