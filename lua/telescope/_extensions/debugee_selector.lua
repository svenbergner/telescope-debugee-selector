local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local actions = require('telescope.actions')
local actions_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')
local utils = require('telescope.previewers.utils')
local config = require('telescope.config').values

local log = require('plenary.log'):new()
-- log.level = 'debug'

local searchPathRoot = "/Users/svenbergner/Repos/SSE/Release/30/build/mac-SSE-ub-debug"
-- local searchPathRoot = ""


local getFileInfo = function(filepath)
        local shortendFilePath = string.sub(filepath, string.len(searchPathRoot) + 1)
        local output = "Debuggee: " .. "..." .. shortendFilePath
        return output
end

local show_debugee_candidates = function(opts)
        -- searchPathRoot = vim.fn.input("Path to buildfolder: ", vim.fn.getcwd() .. "/", "file")
        pickers.new(opts, {
                finder = finders.new_async_job({
                        command_generator = function()
                                return { "find", searchPathRoot, "-perm", "+111", "-type", "f" }
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
                                        vim.tbl_flatten({
                                                getFileInfo(entry.value)
                                        })
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

show_debugee_candidates()

return require("telescope").register_extension({
        exports = {
                show_debugee_candidates = show_debugee_candidates
        }
})


-- Commandline to find all executables in a folder
-- find . -perm +111 -type f | grep -v Frameworks | grep -v plugins | grep -v CMakeFiles | grep -v Resources
