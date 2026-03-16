local actions = require('telescope.actions')
local actions_state = require('telescope.actions.state')
local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local previewers = require('telescope.previewers')
local utils = require('telescope.previewers.utils')
local config = require('telescope.config').values

local log = require('plenary.log'):new()
-- log.level = 'debug'

local searchPathRoot = ''
local current_index = 0
local last_selected_index = 1
local last_debugee_args = ''
local last_program = ''

local state_file = vim.fn.stdpath('data') .. '/debugee_selector_state.json'
local project_key = vim.fn.getcwd()

--- Loads persisted state from disk into module variables
local function load_state()
   if vim.fn.filereadable(state_file) == 0 then
      return
   end
   local ok, all_states = pcall(function()
      return vim.fn.json_decode(table.concat(vim.fn.readfile(state_file), '\n'))
   end)
   if ok and type(all_states) == 'table' then
      local data = all_states[project_key] or {}
      searchPathRoot = data.searchPathRoot or ''
      last_selected_index = data.last_selected_index or 1
      last_debugee_args = data.last_debugee_args or ''
      last_program = data.last_program or ''
   end
end

--- Persists the current state to disk
local function save_state()
   -- Read existing states for all projects first to avoid overwriting them
   local all_states = {}
   if vim.fn.filereadable(state_file) == 1 then
      local ok, decoded = pcall(function()
         return vim.fn.json_decode(table.concat(vim.fn.readfile(state_file), '\n'))
      end)
      if ok and type(decoded) == 'table' then
         all_states = decoded
      end
   end
   all_states[project_key] = {
      searchPathRoot = searchPathRoot,
      last_selected_index = last_selected_index,
      last_debugee_args = last_debugee_args,
      last_program = last_program,
   }
   vim.fn.writefile({ vim.fn.json_encode(all_states) }, state_file)
end

--- Splits a space-separated argument string into a table of individual arguments
--- @param args_str string: The argument string, e.g. "--foo bar --baz"
--- @return table: A list of argument strings
local function parse_args(args_str)
   local result = {}
   for arg in args_str:gmatch('%S+') do
      table.insert(result, arg)
   end
   return result
end

load_state()

-- Apply the restored program/args to the DAP config after all plugins are loaded
vim.schedule(function()
   if last_program ~= '' then
      local ok, dap = pcall(require, 'dap')
      if ok and dap.configurations.cpp and dap.configurations.cpp[1] then
         ---@diagnostic disable-next-line: inject-field
         dap.configurations.cpp[1].program = last_program
         ---@diagnostic disable-next-line: inject-field
         dap.configurations.cpp[1].args = parse_args(last_debugee_args)
      end
   end
end)

local function update_notification(message, title, level, timeout)
   level = level or 'info'
   timeout = timeout or 3000
   if #message < 1 then
      return
   end
   message = string.gsub(message, '\n.*$', '')
   vim.notify(message, level, {
      id = title,
      title = title,
      position = { row = 1, col = '100%' },
      timeout = timeout, -- Timeout in milliseconds
   })
end

--- Removes the searchPathRoot from the given filepath
--- @param filepath string: The full file path
--- @return string: The shortened file path
local function get_shortend_file_path(filepath)
   return '...' .. string.sub(filepath, string.len(searchPathRoot) + 1)
end

--- Returns the filename from a given filepath
--- @param filepath string: The full file path
--- @return string: The filename extracted from the file path
local function get_filename_from_filepath(filepath)
   return vim.fs.basename(filepath)
end

--- Get file information
--- @param filepath string: The full file path
--- @return table: The file information
local getFileInfo = function(filepath)
   local output = {}
   table.insert(output, 'Filename: ' .. get_filename_from_filepath(filepath))
   table.insert(output, 'Fullpath: ' .. filepath)
   table.insert(output, 'Size: ' .. vim.fn.getfsize(filepath) / 1024 .. ' kb')
   table.insert(output, 'Date: ' .. vim.fn.strftime('%H:%M:%S %d.%m.%Y', vim.fn.getftime(filepath)))
   return output
end

--- Get the preset from the given entry
--- @param entry string: The entry to extract the preset from
--- @return string: The preset name
local function get_preset_from_entry(entry)
   local startOfPreset = entry:find('"', 1) + 1
   if startOfPreset == nil then
      return ''
   end
   local endOfPreset = entry:find('"', startOfPreset + 1) - 1
   return entry:sub(startOfPreset, endOfPreset)
end

--- Get the description from the given entry
--- @param entry string: The entry to extract the description from
--- @return string: The description
local function get_desc_from_entry(entry)
   local entryLen = #entry
   local startOfDesc = entry:find('- ', 1) + 2
   if startOfDesc == nil then
      return ''
   end
   local endOfDesc = entryLen
   return entry:sub(startOfDesc, endOfDesc)
end

--- Get the build path for the selected configuration
local function get_build_path_for_configuration(callback_opts, callback)
   local buildPath = ''
   local opts = {
      results_title = 'CMake Presets',
      prompt_title = '',
      default_selection_index = last_selected_index,
      layout_strategy = 'horizontal',
      layout_config = {
         width = 50,
         height = 16,
      },
   }
   pickers
      .new(opts, {
         finder = finders.new_async_job({
            command_generator = function()
               current_index = 0
               return { 'cmake', '--list-presets' }
            end,
            entry_maker = function(entry)
               if not string.find(entry, '"') then
                  return nil
               end
               current_index = current_index + 1
               local preset = get_preset_from_entry(entry)
               local description = get_desc_from_entry(entry)
               return {
                  value = preset,
                  display = description,
                  ordinal = entry,
                  index = current_index,
               }
            end,
         }),

         sorter = config.generic_sorter(opts),

         attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
               local selectedPreset = actions_state.get_selected_entry().value
               last_selected_index = actions_state.get_selected_entry().index - 2
               actions.close(prompt_bufnr)
               save_state()

               local api = vim.api
               api.nvim_cmd({ cmd = 'wa' }, {}) -- save all buffers
               local cmd = 'cmake --preset=' .. selectedPreset
               local searchString = 'Build files have been written to: '

               update_notification('CMake configure for preset: ' .. selectedPreset, 'CMake Preset', 'info', 5000)

               vim.fn.jobstart(cmd, {
                  stdout_buffered = false,
                  stderr_buffered = true,
                  on_stdout = function(_, data)
                     if data then
                        for _, line in ipairs(data) do
                           local buildPathStart = string.find(line, searchString)
                           if buildPathStart then
                              buildPath = string.sub(line, buildPathStart + #searchString, -1)
                           end
                        end
                     end
                  end,
                  on_exit = function(_, code)
                     if code == 0 then
                        searchPathRoot = buildPath
                        callback(callback_opts)
                     else
                        searchPathRoot = ''
                     end
                  end,
               })
            end)
            return true
         end,
      })
      :find()
end

--- Show a list of all executables in the selected path
--- @param opts any: The options for the picker
local show_debugee_candidates = function(opts)
   if searchPathRoot == '' then
      searchPathRoot = vim.fn.getcwd() .. '/'
      searchPathRoot = vim.fn.input('Path to executable: ', searchPathRoot, 'dir')
   end
   opts = opts
      or {
         results_title = 'Debugee Selector',
         prompt_title = 'Select Debugee Executable',
         layout_config = {
            preview_width = 0.4,
         },
      }
   pickers
      .new(opts, {
         finder = finders.new_async_job({
            command_generator = function()
               ---@diagnostic disable-next-line: undefined-field
               if vim.loop.os_uname().sysname == 'Darwin' then
                  return { 'find', searchPathRoot, '-perm', '+111', '-type', 'f' }
               else
                  return { 'find', searchPathRoot, '-executable', '-type', 'f' }
               end
            end,
            entry_maker = function(entry)
               if
                  string.find(entry, 'Frameworks')
                  or string.find(entry, 'plugins ')
                  or string.find(entry, 'CMakeFiles')
                  or string.find(entry, '.dylib')
                  or string.find(entry, 'jdk/bin')
                  or string.find(entry, 'jdk/lib')
                  or string.find(entry, 'Resources')
               then
                  return nil
               else
                  return {
                     value = entry,
                     display = get_shortend_file_path(entry),
                     ordinal = entry,
                  }
               end
            end,
         }),

         sorter = config.generic_sorter(opts),

         previewer = previewers.new_buffer_previewer({
            title = 'Debuggee Details',
            define_preview = function(self, entry)
               vim.api.nvim_buf_set_lines(self.state.bufnr, 0, 0, true, getFileInfo(entry.value))
               utils.highlighter(self.state.bufnr, 'markdown')
               -- Enable word wrap in the preview window
               vim.api.nvim_set_option_value('wrap', true, { win = self.state.winid })
            end,
         }),

         attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
               local selectedFilePath = actions_state.get_selected_entry().value
               log.debug('attach_mappings', selectedFilePath)
               actions.close(prompt_bufnr)

               -- Prompt the user for arguments to pass to the debugee
               local args_str = vim.fn.input('Debugee arguments: ', last_debugee_args)
               last_debugee_args = args_str
               last_program = selectedFilePath
               save_state()

               local dap_config = require('dap').configurations.cpp[1]
               ---@diagnostic disable-next-line: inject-field
               dap_config.program = selectedFilePath
               ---@diagnostic disable-next-line: inject-field
               dap_config.args = parse_args(args_str)
            end)
            return true
         end,
      })
      :find()
end

--- Let the user select the root path to search for executables
local selectSearchPathRoot = function(opts)
   get_build_path_for_configuration(opts, show_debugee_candidates)
end

--- Sets the search path to the default value
local reset_serch_path = function()
   searchPathRoot = ''
   save_state()
end

--- Resets the stored debugee arguments
local reset_debugee_args = function()
   last_debugee_args = ''
   save_state()
end

--- Register the extension
return require('telescope').register_extension({
   exports = {
      show_debugee_candidates = show_debugee_candidates,
      selectSearchPathRoot = selectSearchPathRoot,
      reset_search_path = reset_serch_path,
      reset_debugee_args = reset_debugee_args,
   },
})

-- Commandline to find all executables in a folder
-- find . -perm +111 -type f | grep -v Frameworks | grep -v plugins | grep -v CMakeFiles | grep -v Resources
