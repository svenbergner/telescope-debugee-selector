
local M = {}

M.check = function()
    vim.health.start('Debugee Selector Report')
    vim.health.ok('Debugee Selector is installed')
end

return M
