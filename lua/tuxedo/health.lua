local config = require("tuxedo.config")
local cli = require("tuxedo.cli")

local M = {}

local function report_error(err)
  local message = type(err) == "table" and err.message or tostring(err)
  vim.health.error(message)
end

function M.check()
  vim.health.start("tuxedo.nvim")
  local version = vim.version()
  if version.major > 0 or version.minor >= 11 then
    vim.health.ok(string.format("Neovim %d.%d.%d (API floor: 0.11)", version.major, version.minor, version.patch or 0))
  else
    vim.health.error(string.format("Neovim %d.%d.%d is too old; tuxedo.nvim requires >= 0.11", version.major, version.minor, version.patch or 0))
  end

  local cfg = config.get()
  vim.health.info("Configured command: " .. cfg.command)
  local executable, executable_error = cli.resolve_executable(cfg.command)
  if not executable then
    report_error({
      message = string.format(
        "Tuxedo executable unavailable: %s (installed version: unknown; expected interface: %s; failed capability: executable/TUI)",
        tostring(executable_error),
        cli.expected_interface
      ),
    })
    return
  end
  vim.health.ok("Resolved executable: " .. executable)

  local probe = cli.probe(executable)
  local version_info = probe.version
  local version_error = probe.version_error
  if not version_info then
    report_error(version_error)
  else
    local display = version_info.display ~= "" and version_info.display or "<unparseable>"
    vim.health.info("Installed Tuxedo version: " .. display)
    if not version_info.token then
      vim.health.warn("Tuxedo version output is unparseable; version parsing is display-only and capabilities will decide compatibility")
    else
      vim.health.ok("Tuxedo version text: " .. version_info.token)
    end
  end

  local installed = version_info and (version_info.display or version_info.token or version_info.raw) or "unknown"
  local function capability_message(message, capability)
    return string.format("%s (installed version: %s; expected interface: %s; failed capability: %s)", message, vim.trim(tostring(installed)), cli.expected_interface, capability)
  end
  if probe.tui and probe.tui.entrypoint then
    vim.health.info("TUI entry point resolved; interactive launch is not probed")
  else
    report_error(probe.tui and probe.tui.error or { message = capability_message("TUI entry point unavailable", "TUI executable") })
  end
  if probe.add and probe.add.ok then
    vim.health.ok("Native add JSON capability available")
  else
    report_error(probe.add and probe.add.error or { message = capability_message("Native add JSON capability failed", "add JSON") })
  end
  if probe.list and probe.list.ok then
    vim.health.ok("Native list JSON capability available")
  else
    local err = probe.list and probe.list.error
    if err then
      vim.health.warn((err.message or tostring(err)) .. "; list is optional in V1 and does not affect the TUI entry point")
    else
      vim.health.warn(capability_message("Native list JSON capability unavailable", "list JSON") .. "; list is optional in V1 and does not affect the TUI entry point")
    end
  end
  if probe.cleanup_warning then
    vim.health.warn(probe.cleanup_warning)
  end
end

return { check = M.check }
