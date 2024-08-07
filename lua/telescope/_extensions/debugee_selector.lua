local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local actions = require('telescope.actions')
local actions_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')
local utils = require('telescope.previewers.utils')
local config = require('telescope.config').values

local log = require('plenary.log'):new()
-- log.level = 'debug'

local searchPathRoot = ""

local getShortendFilePath = function(filepath)
        return string.sub(filepath, string.len(searchPathRoot) + 1)
end

local getFileNameFromFilePath = function(filepath)
        return vim.fs.basename(filepath)
end

local getFileInfo = function(filepath)
        local output = {}
        table.insert(output, "Filename: " .. getFileNameFromFilePath(filepath))
        table.insert(output, "Shortpath: " .. "..." .. getShortendFilePath(filepath))
        table.insert(output, "Size: " .. vim.fn.getfsize(filepath) / 1024 .. " kb")
        table.insert(output, "Date: " .. vim.fn.strftime('%H:%M:%S %d.%m.%Y', vim.fn.getftime(filepath)))
        return output
end

local selectSearchPathRoot = function()
        if (searchPathRoot == "") then
                searchPathRoot = vim.fn.getcwd() .. '/'
        end
        searchPathRoot = vim.fn.input('Path to executable: ', searchPathRoot, 'dir');
end

local show_debugee_candidates = function(opts)
        if (searchPathRoot == "") then
                selectSearchPathRoot()
        end
        pickers.new(opts, {
                finder = finders.new_async_job({
                        command_generator = function()
                                if ( vim.loop.os_uname().sysname == 'Darwin' ) then
                                        print('Mac')
                                        return { "find", searchPathRoot, "-perm", "+111", "-type", "f" }
                                else
                                        print('Linux')
                                        return { "find", searchPathRoot, "-executable", "-type", "f" }
                                end
                        end,
                        entry_maker = function(entry)
                                if string.find(entry, "Frameworks") or
                                    string.find(entry, "plugins ") or
                                    string.find(entry, "CMakeFiles") or
                                    string.find(entry, ".dylib") or
                                    string.find(entry, "jdk/bin") or
                                    string.find(entry, "jdk/lib") or
                                    string.find(entry, "Resources")
                                then
                                        return nil
                                else
                                        return {
                                                value = entry,
                                                display = entry,
                                                ordinal = entry,
                                        }
                                end
                        end,
                }),

                sorter = config.generic_sorter(opts),

                previewer = previewers.new_buffer_previewer {
                        title = 'Debuggee Details',
                        define_preview = function(self, entry)
                                vim.api.nvim_buf_set_lines(
                                        self.state.bufnr,
                                        0,
                                        0,
                                        true,
                                        getFileInfo(entry.value)
                                )
                                utils.highlighter(self.state.bufnr, 'markdown')
                        end,
                },

                attach_mappings = function(prompt_bufnr)
                        actions.select_default:replace(function()
                                local selectedFilePath = actions_state.get_selected_entry().value
                                log.debug("attach_mappings", selectedFilePath)
                                require('dap').configurations.cpp[1].program = selectedFilePath
                                actions.close(prompt_bufnr)
                        end)
                        return true
                end
        }):find()
end

return require("telescope").register_extension({
        exports = {
                show_debugee_candidates = show_debugee_candidates,
                selectSearchPathRoot = selectSearchPathRoot
        }
})

-- Commandline to find all executables in a folder
-- find . -perm +111 -type f | grep -v Frameworks | grep -v plugins | grep -v CMakeFiles | grep -v Resources
