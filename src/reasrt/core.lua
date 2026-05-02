local M = {}

local function normalize_piece(piece)
  piece = tostring(piece or "")
  piece = piece:gsub("\\", "/")
  piece = piece:gsub("/+", "/")
  return piece
end

function M.normalize_path(path)
  return normalize_piece(path)
end

function M.join_path(...)
  local parts = { ... }
  local normalized = {}

  for index, part in ipairs(parts) do
    local piece = normalize_piece(part)
    if piece ~= "" then
      if index > 1 then
        piece = piece:gsub("^/+", "")
      end
      if index < #parts then
        piece = piece:gsub("/+$", "")
      end
      normalized[#normalized + 1] = piece
    end
  end

  return table.concat(normalized, "/")
end

function M.get_script_path(level)
  local info = debug.getinfo(level or 2, "S")
  local source = info and info.source or ""
  if source:sub(1, 1) == "@" then
    return source:sub(2)
  end
  return source
end

function M.get_script_dir(script_path)
  local normalized = normalize_piece(script_path)
  local dir = normalized:match("^(.*)/[^/]+$")
  if dir and dir ~= "" then
    return dir .. "/"
  end
  return "./"
end

function M.extend_package_path(script_dir)
  if not package or not package.path then
    return
  end

  local root = M.get_script_dir(script_dir)
  local prefixes = {
    root .. "?.lua",
    root .. "?/init.lua",
  }

  for _, prefix in ipairs(prefixes) do
    if not package.path:find(prefix, 1, true) then
      package.path = prefix .. ";" .. package.path
    end
  end
end

function M.now_sec(reaper)
  if reaper and reaper.time_precise then
    return reaper.time_precise()
  end
  return os.clock()
end

function M.format_ms(ms)
  ms = tonumber(ms) or 0
  local total_sec = math.floor(ms / 1000)
  local milli = ms % 1000
  local sec = total_sec % 60
  local min = math.floor(total_sec / 60) % 60
  local hour = math.floor(total_sec / 3600)
  return string.format("%02d:%02d:%02d.%03d", hour, min, sec, milli)
end

function M.normalize_search_text(s)
  s = tostring(s or "")
  return s:lower()
end

function M.contains_icase_blob(search_blob, needle)
  if not needle or needle == "" then
    return true
  end
  return tostring(search_blob or ""):find(needle, 1, true) ~= nil
end

function M.make_item_key(item)
  return table.concat({
    tostring(item and item.srt_index or ""),
    tostring(item and item.start_ms or 0),
    tostring(item and item.end_ms or 0),
    tostring(item and item.text or ""),
  }, "|")
end

function M.split_lines_preserve_empty(text)
  local lines = {}
  text = tostring(text or "")
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

  if text == "" then
    return lines
  end

  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end

  for line in text:gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  return lines
end

function M.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.strip_leading_speaker_label(text)
  text = tostring(text or "")
  if text == "" then
    return text
  end

  local full_open = string.char(239, 188, 136)
  local full_close = string.char(239, 188, 137)
  local _, speaker, rest = text:match("^(%s*" .. full_open .. "%s*([^\r\n]-)%s*" .. full_close .. ")(.*)$")
  if not speaker then
    _, speaker, rest = text:match("^(%s*%(%s*([^\r\n]-)%s*%))(.*)$")
  end
  if not speaker then
    return text
  end

  speaker = M.trim(speaker)
  if speaker == "" then
    return text
  end

  rest = tostring(rest or ""):gsub("^[%s\r\n]+", "")
  return rest
end

function M.clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

function M.parse_integer(value, default_value)
  local num = tonumber(value)
  if not num then
    return default_value
  end
  if num >= 0 then
    return math.floor(num)
  end
  return math.ceil(num)
end

function M.file_exists(path)
  if not path or path == "" then
    return false
  end
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  f:close()
  return true
end

function M.delete_file(path)
  if not path or path == "" then
    return false, "File path is empty."
  end
  local ok, err = os.remove(path)
  if ok then
    return true
  end
  return false, err or "Failed to delete file."
end

function M.format_signed_ms(ms)
  ms = M.parse_integer(ms, 0) or 0
  if ms >= 0 then
    return "+" .. tostring(ms) .. " ms"
  end
  return tostring(ms) .. " ms"
end

function M.collapse_text_to_single_line(text)
  text = tostring(text or "")
  text = text:gsub("[\r\n]+", " ")
  text = text:gsub("%s+", " ")
  return M.trim(text)
end

function M.make_tooltip_text(text, max_chars)
  text = tostring(text or "")
  max_chars = M.parse_integer(max_chars, 1200) or 1200
  if #text <= max_chars then
    return text
  end
  return text:sub(1, max_chars) .. "..."
end

function M.is_srt_file_path(path)
  path = M.normalize_search_text(M.trim(path or ""))
  return path:match("%.srt$") ~= nil
end

function M.parse_execprocess_result(output)
  output = tostring(output or "")
  local newline_pos = output:find("\n", 1, true)
  if not newline_pos then
    return tonumber(M.trim(output)), ""
  end

  local exit_code = tonumber(M.trim(output:sub(1, newline_pos - 1)))
  local stdout = output:sub(newline_pos + 1):gsub("\r\n", "\n"):gsub("\r", "\n")
  return exit_code, stdout
end

function M.escape_powershell_single_quoted(text)
  return tostring(text or ""):gsub("'", "''")
end

function M.normalize_tag(tag)
  tag = M.trim(tag)
  tag = tag:gsub("%s+", " ")
  return tag
end

function M.parse_tags_text(tags_text)
  local tags = {}
  local seen = {}
  tags_text = tostring(tags_text or "")

  for raw in tags_text:gmatch("[^,\n]+") do
    local tag = M.normalize_tag(raw)
    if tag ~= "" then
      local key = M.normalize_search_text(tag)
      if not seen[key] then
        seen[key] = true
        tags[#tags + 1] = tag
      end
    end
  end

  return tags
end

function M.join_tags(tags)
  if not tags or #tags == 0 then
    return ""
  end
  return table.concat(tags, ", ")
end

local function escape_json_string(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
  return '"' .. s .. '"'
end

function M.json_encode(value)
  local value_type = type(value)

  if value_type == "nil" then
    return "null"
  elseif value_type == "boolean" then
    return value and "true" or "false"
  elseif value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return tostring(value)
  elseif value_type == "string" then
    return escape_json_string(value)
  elseif value_type == "table" then
    local is_array = true
    local max_index = 0

    for k, _ in pairs(value) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
        is_array = false
        break
      end
      if k > max_index then
        max_index = k
      end
    end

    local out = {}
    if is_array then
      for i = 1, max_index do
        out[#out + 1] = M.json_encode(value[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
    end

    for k, v in pairs(value) do
      out[#out + 1] = escape_json_string(tostring(k)) .. ":" .. M.json_encode(v)
    end
    table.sort(out)
    return "{" .. table.concat(out, ",") .. "}"
  end

  return "null"
end

function M.json_decode(text)
  text = tostring(text or "")
  local pos = 1
  local len = #text

  local function skip_ws()
    while pos <= len do
      local c = text:sub(pos, pos)
      if c == " " or c == "\n" or c == "\r" or c == "\t" then
        pos = pos + 1
      else
        break
      end
    end
  end

  local parse_value

  local function parse_string()
    if text:sub(pos, pos) ~= '"' then
      error("Expected string at position " .. tostring(pos))
    end
    pos = pos + 1
    local out = {}

    while pos <= len do
      local c = text:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local esc = text:sub(pos + 1, pos + 1)
        if esc == '"' or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
          pos = pos + 2
        elseif esc == "b" then
          out[#out + 1] = "\b"
          pos = pos + 2
        elseif esc == "f" then
          out[#out + 1] = "\f"
          pos = pos + 2
        elseif esc == "n" then
          out[#out + 1] = "\n"
          pos = pos + 2
        elseif esc == "r" then
          out[#out + 1] = "\r"
          pos = pos + 2
        elseif esc == "t" then
          out[#out + 1] = "\t"
          pos = pos + 2
        elseif esc == "u" then
          error("Unicode escape is not supported in JSON parser.")
        else
          error("Invalid escape at position " .. tostring(pos))
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end

    error("Unterminated string.")
  end

  local function parse_number()
    local start_pos = pos
    local s = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not s or s == "" then
      error("Invalid number at position " .. tostring(pos))
    end
    pos = start_pos + #s
    return tonumber(s)
  end

  local function parse_array()
    pos = pos + 1
    skip_ws()

    local arr = {}
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end

    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()

      local c = text:sub(pos, pos)
      if c == "]" then
        pos = pos + 1
        return arr
      elseif c == "," then
        pos = pos + 1
        skip_ws()
      else
        error("Expected ',' or ']' at position " .. tostring(pos))
      end
    end
  end

  local function parse_object()
    pos = pos + 1
    skip_ws()

    local obj = {}
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end

    while true do
      local key = parse_string()
      skip_ws()
      if text:sub(pos, pos) ~= ":" then
        error("Expected ':' at position " .. tostring(pos))
      end
      pos = pos + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()

      local c = text:sub(pos, pos)
      if c == "}" then
        pos = pos + 1
        return obj
      elseif c == "," then
        pos = pos + 1
        skip_ws()
      else
        error("Expected ',' or '}' at position " .. tostring(pos))
      end
    end
  end

  parse_value = function()
    skip_ws()
    local c = text:sub(pos, pos)

    if c == '"' then
      return parse_string()
    elseif c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif c == "-" or c:match("%d") then
      return parse_number()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end

    error("Unexpected token at position " .. tostring(pos))
  end

  local value = parse_value()
  skip_ws()
  if pos <= len then
    error("Unexpected trailing data at position " .. tostring(pos))
  end
  return value
end

function M.ensure_directory_exists(reaper, path)
  if not path or path == "" then
    return false, "Directory path is empty."
  end

  if reaper and reaper.RecursiveCreateDirectory then
    local ok = reaper.RecursiveCreateDirectory(path, 0)
    if ok == 1 or ok == true then
      return true
    end
  end

  local test = io.open(path .. "/.__reasrt_write_test__", "wb")
  if test then
    test:close()
    os.remove(path .. "/.__reasrt_write_test__")
    return true
  end

  return false, "Failed to create directory: " .. tostring(path)
end

function M.write_text_file_utf8(path, content)
  local f, err = io.open(path, "wb")
  if not f then
    return false, ("Failed to open file for write: %s"):format(tostring(err))
  end
  f:write(content or "")
  f:close()
  return true
end

function M.read_text_file_utf8(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, ("Failed to open file: %s"):format(tostring(err))
  end

  local data = f:read("*a")
  f:close()

  if not data then
    return nil, "Failed to read file."
  end

  if data:sub(1, 3) == "\239\187\191" then
    data = data:sub(4)
  end

  return data
end

function M.get_appdata_root(reaper)
  local resource_path = reaper and reaper.GetResourcePath and reaper.GetResourcePath() or ""
  if resource_path ~= "" then
    return resource_path:gsub("[/\\]+$", "")
  end

  return ""
end

function M.get_default_app_storage_dir(reaper, app_name)
  local resource_root = M.get_appdata_root(reaper)
  if resource_root == "" then
    return ""
  end
  return resource_root .. "\\" .. tostring(app_name or "ReaSRTBrowser")
end

function M.get_default_metadata_dir(reaper, app_name)
  local app_dir = M.get_default_app_storage_dir(reaper, app_name)
  if app_dir == "" then
    return ""
  end
  return app_dir .. "\\metadata"
end

function M.get_default_settings_path(reaper, app_name)
  local app_dir = M.get_default_app_storage_dir(reaper, app_name)
  if app_dir == "" then
    return ""
  end
  return app_dir .. "\\settings.json"
end

function M.get_default_libraries_path(reaper, app_name)
  local app_dir = M.get_default_app_storage_dir(reaper, app_name)
  if app_dir == "" then
    return ""
  end
  return app_dir .. "\\libraries.json"
end

function M.hash_string_djb2(input)
  local hash = 5381
  input = tostring(input or "")

  for i = 1, #input do
    hash = ((hash * 33) + input:byte(i)) % 4294967296
  end

  return string.format("%08x", hash)
end

function M.build_temp_output_path(reaper, app_name, prefix, extension, now_sec_fn)
  local app_dir = M.get_default_app_storage_dir(reaper, app_name)
  if app_dir == "" then
    return nil, "App storage directory could not be resolved."
  end

  local temp_dir = app_dir .. "\\temp"
  local ok, err = M.ensure_directory_exists(reaper, temp_dir)
  if not ok then
    return nil, err or "Failed to create temp directory."
  end

  prefix = tostring(prefix or "temp")
  extension = tostring(extension or ".tmp")
  local now_value = now_sec_fn and now_sec_fn() or os.clock()
  local unique = M.hash_string_djb2(prefix .. "|" .. tostring(now_value) .. "|" .. tostring(math.random()))
  return temp_dir .. "\\" .. prefix .. "_" .. unique .. extension
end

function M.build_metadata_path_for_srt(reaper, app_name, srt_path)
  local dir = M.get_default_metadata_dir(reaper, app_name)
  if dir == "" then
    return nil, "Metadata base directory could not be resolved."
  end

  local ok, err = M.ensure_directory_exists(reaper, dir)
  if not ok then
    return nil, err
  end

  return dir .. "\\" .. M.hash_string_djb2(srt_path) .. ".json"
end

function M.parse_srt_timecode_to_ms(s)
  local h, m, sec, ms = tostring(s or ""):match("^(%d+):(%d+):(%d+)[,.](%d+)$")
  if not h then
    return nil
  end

  h = tonumber(h)
  m = tonumber(m)
  sec = tonumber(sec)
  ms = tonumber(ms)

  if not (h and m and sec and ms) then
    return nil
  end

  return (((h * 60) + m) * 60 + sec) * 1000 + ms
end

function M.parse_srt_content(text)
  local items = {}
  local lines = M.split_lines_preserve_empty(text)
  local i = 1
  local block_count = 0

  while i <= #lines do
    while i <= #lines and M.trim(lines[i]) == "" do
      i = i + 1
    end
    if i > #lines then
      break
    end

    local index_line = M.trim(lines[i])
    local time_line = M.trim(lines[i + 1] or "")

    local srt_index = tonumber(index_line)
    local start_tc, end_tc = time_line:match("^(.-)%s*%-%->%s*(.-)$")

    if not start_tc then
      start_tc, end_tc = index_line:match("^(.-)%s*%-%->%s*(.-)$")
      if start_tc then
        srt_index = block_count + 1
        i = i - 1
      end
    end

    if start_tc and end_tc then
      local start_ms = M.parse_srt_timecode_to_ms(M.trim(start_tc))
      local end_ms = M.parse_srt_timecode_to_ms(M.trim(end_tc))

      if start_ms and end_ms then
        local text_lines = {}
        i = i + 2
        while i <= #lines and M.trim(lines[i]) ~= "" do
          text_lines[#text_lines + 1] = lines[i]
          i = i + 1
        end

        block_count = block_count + 1
        items[#items + 1] = {
          srt_index = srt_index or block_count,
          text = table.concat(text_lines, "\n"),
          start_ms = start_ms,
          end_ms = end_ms,
          note = "",
          tags_text = "",
          tags = {},
          favorite = false,
        }
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  return items
end

function M.get_initial_browse_dir(reaper)
  local proj_path = ""
  if reaper and reaper.EnumProjects then
    local _, project_fn = reaper.EnumProjects(-1, "")
    proj_path = tostring(project_fn or "")
  end

  if proj_path ~= "" then
    local dir = proj_path:match("^(.*)[/\\][^/\\]+$")
    if dir and dir ~= "" then
      return dir
    end
  end

  return ""
end

function M.get_filename(path)
  if not path or path == "" then
    return nil
  end
  return tostring(path):match("([^/\\]+)$") or path
end

function M.get_parent_dir(path)
  path = tostring(path or "")
  if path == "" then
    return ""
  end

  local normalized = path:gsub("[/\\]+$", "")
  return normalized:match("^(.*)[/\\][^/\\]+$") or ""
end

function M.get_file_stem(path)
  local filename = M.get_filename(path)
  if not filename or filename == "" then
    return ""
  end

  local stem = filename:match("^(.*)%.([^.]*)$")
  return stem or filename
end

function M.compare_text_case_insensitive(a, b)
  a = tostring(a or "")
  b = tostring(b or "")
  local na = M.normalize_search_text(a)
  local nb = M.normalize_search_text(b)
  if na ~= nb then
    return na < nb
  end
  return a < b
end

function M.get_media_length_sec(reaper, path)
  if not path or path == "" or not reaper then
    return nil
  end

  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then
    return nil
  end

  local length = reaper.GetMediaSourceLength(src)
  reaper.PCM_Source_Destroy(src)

  if not length or length <= 0 then
    return nil
  end

  return length
end

function M.get_selected_insertion_track(reaper)
  local track_count = reaper and reaper.CountSelectedTracks and reaper.CountSelectedTracks(0) or 0
  if track_count <= 0 then
    return nil, "No track selected. Select a destination track in REAPER."
  end

  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    return nil, "Failed to get selected track."
  end

  return track, nil
end

function M.set_take_name(reaper, take, name)
  if not take then
    return false
  end

  if reaper and reaper.GetSetMediaItemTakeInfo_String then
    local ok = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", tostring(name or ""), true)
    return ok and true or false
  end

  return false
end

function M.has_required_sws_preview_api(reaper)
  return
    reaper and
    reaper.CF_CreatePreview and
    reaper.CF_Preview_Play and
    reaper.CF_Preview_Stop and
    reaper.CF_Preview_GetValue and
    reaper.CF_Preview_SetValue and
    reaper.CF_PCM_Source_SetSectionInfo and
    reaper.PCM_Source_CreateFromType
end

function M.get_preview_backend_status(reaper)
  if M.has_required_sws_preview_api(reaper) then
    return true, "SWS preview API available."
  end
  return false, "SWS Extension preview API is not available. Install/update SWS to use preview."
end

return M
