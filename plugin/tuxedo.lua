if vim.g.loaded_tuxedo_nvim then
  return
end
vim.g.loaded_tuxedo_nvim = 1

local tuxedo = require("tuxedo")

vim.api.nvim_create_user_command("Tuxedo", function()
  tuxedo.open()
end, { nargs = 0, desc = "Open the Tuxedo task terminal" })

vim.api.nvim_create_user_command("TuxedoToggle", function()
  tuxedo.toggle()
end, { nargs = 0, desc = "Toggle the Tuxedo task terminal" })

vim.api.nvim_create_user_command("TuxedoClose", function()
  tuxedo.close()
end, { nargs = 0, desc = "Close the Tuxedo task terminal session" })

vim.api.nvim_create_user_command("TuxedoAdd", function(opts)
  if opts.args ~= "" then
    tuxedo.add(opts.args)
    return
  end
  vim.ui.input({ prompt = "Tuxedo task: " }, function(text)
    if text == nil then
      return
    end
    tuxedo.add(text)
  end)
end, { nargs = "*", desc = "Add a task through Tuxedo" })
