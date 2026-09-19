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

vim.api.nvim_create_user_command("TuxedoAdd", function()
  vim.ui.input({ prompt = "Tuxedo task: " }, function(text)
    if text == nil then
      return
    end
    tuxedo.add(text)
  end)
end, { nargs = 0, desc = "Add a task through Tuxedo" })
