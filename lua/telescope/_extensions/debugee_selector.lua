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
local current_index = 0
local last_selected_index = 1

local function update_notification(message, title, level, timeout)
  level = level or "info"
  timeout = timeout or 3000
  if #message < 1 then
    return
  end
  message = string.gsub(message, "\n.*$", "")
  vim.notify(message, level, {
    id = title,
    title = title,
    position = { row = 1, col = "100%" },
    timeout = timeout, -- Timeout in milliseconds
  })
end


--- Removes the searchPathRoot from the given filepath
--- @param filepath string: The full file path
--- @return string: The shortened file path
local getShortendFilePath = function(filepath)
  return string.sub(filepath, string.len(searchPathRoot) + 1)
end

--- Returns the filename from a given filepath
--- @param filepath string: The full file path
--- @return string: The filename extracted from the file path
local getFileNameFromFilePath = function(filepath)
  return vim.fs.basename(filepath)
end

--- Get file information
--- @param filepath string: The full file path
--- @return table: The file information
local getFileInfo = function(filepath)
  local output = {}
  table.insert(output, "Filename: " .. getFileNameFromFilePath(filepath))
  table.insert(output, "Shortpath: " .. "..." .. getShortendFilePath(filepath))
  table.insert(output, "Size: " .. vim.fn.getfsize(filepath) / 1024 .. " kb")
  table.insert(output, "Date: " .. vim.fn.strftime('%H:%M:%S %d.%m.%Y', vim.fn.getftime(filepath)))
  return output
end

--- Get the preset from the given entry
--- @param entry string: The entry to extract the preset from
--- @return string: The preset name
local function getPresetFromEntry(entry)
  local startOfPreset = entry:find('"', 1) + 1
  if startOfPreset == nil then
    return ""
  end
  local endOfPreset = entry:find('"', startOfPreset + 1) - 1
  return entry:sub(startOfPreset, endOfPreset)
end

--- Get the description from the given entry
--- @param entry string: The entry to extract the description from
--- @return string: The description
local function getDescFromEntry(entry)
  local entryLen = #entry
  local startOfDesc = entry:find('- ', 1) + 2
  if startOfDesc == nil then
    return ""
  end
  local endOfDesc = entryLen
  return entry:sub(startOfDesc, endOfDesc)
end

--- Get the build path for the selected configuration
local function get_build_path_for_configuration(callback_opts, callback)
  local buildPath = ""
  local opts = {
    results_title = "CMake Presets",
    prompt_title = "",
    default_selection_index = last_selected_index,
    layout_strategy = "vertical",
    layout_config = {
      width = 80,
      height = 20,
    },
  }
  pickers.new(opts, {
    finder = finders.new_async_job({
      command_generator = function()
        current_index = 0
        return { "cmake", "--list-presets" }
      end,
      entry_maker = function(entry)
        if (not string.find(entry, '"')) then
          return nil
        end
        current_index = current_index + 1
        local preset = getPresetFromEntry(entry)
        local description = getDescFromEntry(entry)
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

        local api = vim.api
        api.nvim_cmd({ cmd = 'wa' }, {}) -- save all buffers
        local cmd = 'cmake --preset=' .. selectedPreset
        local searchString = "Build files have been written to: "

        update_notification("CMake configure for preset: " .. selectedPreset, "CMake Preset", "info", 5000)

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
              searchPathRoot = ""
            end
          end,
        })
      end)
      return true
    end
  }):find()
end

--- Show a list of all executables in the selected path
--- @param opts any: The options for the picker
local show_debugee_candidates = function(opts)
  if (searchPathRoot == "") then
    searchPathRoot = vim.fn.getcwd() .. '/'
    searchPathRoot = vim.fn.input('Path to executable: ', searchPathRoot, 'dir');
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

--- Let the user select the root path to search for executables
local selectSearchPathRoot = function(opts)
  get_build_path_for_configuration(opts, show_debugee_candidates)
end

--- Sets the search path to the default value
local reset_serch_path = function()
  searchPathRoot = ""
end

--- Register the extension
return require("telescope").register_extension({
  exports = {
    show_debugee_candidates = show_debugee_candidates,
    selectSearchPathRoot = selectSearchPathRoot,
    reset_search_path = reset_serch_path,
  }
})

-- Commandline to find all executables in a folder
-- find . -perm +111 -type f | grep -v Frameworks | grep -v plugins | grep -v CMakeFiles | grep -v Resources
