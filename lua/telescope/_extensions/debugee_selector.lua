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

--- Removes the searchPathRoot from the given filepath
--- @param filepath string
--- @return string
local getShortendFilePath = function(filepath)
        return string.sub(filepath, string.len(searchPathRoot) + 1)
end

---Returns the filename from a given filepath
---@param filepath string
---@return string
local getFileNameFromFilePath = function(filepath)
        return vim.fs.basename(filepath)
end

--- Get file information
--- @param filepath string
--- @return table
local getFileInfo = function(filepath)
        local output = {}
        table.insert(output, "Filename: " .. getFileNameFromFilePath(filepath))
        table.insert(output, "Shortpath: " .. "..." .. getShortendFilePath(filepath))
        table.insert(output, "Size: " .. vim.fn.getfsize(filepath) / 1024 .. " kb")
        table.insert(output, "Date: " .. vim.fn.strftime('%H:%M:%S %d.%m.%Y', vim.fn.getftime(filepath)))
        return output
end

--- Let the user select the root path to search for executables
local selectSearchPathRoot = function()
        if (searchPathRoot == "") then
                searchPathRoot = vim.fn.getcwd() .. '/'
        end
        searchPathRoot = vim.fn.input('Path to executable: ', searchPathRoot, 'dir');
end

--- Show a list of all executables in the selected path
--- @param opts any
local show_debugee_candidates = function(opts)
        if (searchPathRoot == "") then
                selectSearchPathRoot()
        end
        pickers.new(opts, {
                finder = finders.new_async_job({
                        command_generator = function()
                                ---@diagnostic disable-next-line: undefined-field
                                if (vim.loop.os_uname().sysname == 'Darwin') then
                                        return { "find", searchPathRoot, "-perm", "+111", "-type", "f" }
                                else
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
                                ---@diagnostic disable-next-line: inject-field
                                require('dap').configurations.cpp[1].program = selectedFilePath
                                actions.close(prompt_bufnr)
                        end)
                        return true
                end
        }):find()
end

--- Sets the search path to the default value
local reset_serch_path = function()
        searchPathRoot = ""
end

return require("telescope").register_extension({
        exports = {
                show_debugee_candidates = show_debugee_candidates,
                selectSearchPathRoot = selectSearchPathRoot,
                reset_search_path = reset_serch_path,
        }
})

-- Commandline to find all executables in a folder
-- find . -perm +111 -type f | grep -v Frameworks | grep -v plugins | grep -v CMakeFiles | grep -v Resources
