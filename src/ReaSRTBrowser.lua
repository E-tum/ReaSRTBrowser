local bootstrap_path = debug.getinfo(1, "S").source or ""
if bootstrap_path:sub(1, 1) == "@" then
  bootstrap_path = bootstrap_path:sub(2)
end

local bootstrap_dir = bootstrap_path:match("^(.*[\\/])") or "./"
if package and package.path then
  package.path = bootstrap_dir .. "?.lua;" .. bootstrap_dir .. "?/init.lua;" .. package.path
end

local UI_CONFIG = require("resources.ui")
local Core = require("reasrt.core")
local I18n = require("reasrt.i18n")
local i18n = I18n.create({
  script_dir = bootstrap_dir,
  default_language = UI_CONFIG.app.default_language,
  fallback_language = UI_CONFIG.app.fallback_language,
})

local function t(key, ...)
  return i18n:t(key, ...)
end

local APP_NAME = UI_CONFIG.app.name
local WINDOW_TITLE = UI_CONFIG.app.window_title or APP_NAME

if not reaper.ImGui_CreateContext then
  reaper.MB(t("error.imgui_missing"), APP_NAME, 0)
  return
end

local ctx = reaper.ImGui_CreateContext(WINDOW_TITLE)
local font = nil
local font_size = tonumber(UI_CONFIG.fonts.default.size) or 14
local font_small = nil
local font_small_size = tonumber(UI_CONFIG.fonts.small.size) or 12
font_cache = font_cache or {}

--========================================================
-- Utility
--========================================================

local function now_sec()
  return Core.now_sec(reaper)
end

local format_ms = Core.format_ms
local normalize_search_text = Core.normalize_search_text
local contains_icase_blob = Core.contains_icase_blob
local split_lines_preserve_empty = Core.split_lines_preserve_empty
local trim = Core.trim
local clamp = Core.clamp
local parse_integer = Core.parse_integer
local file_exists = Core.file_exists
local delete_file = Core.delete_file
local format_signed_ms = Core.format_signed_ms
local collapse_text_to_single_line = Core.collapse_text_to_single_line
local make_tooltip_text = Core.make_tooltip_text
local strip_leading_speaker_label = Core.strip_leading_speaker_label
local is_srt_file_path = Core.is_srt_file_path
local parse_execprocess_result = Core.parse_execprocess_result
local escape_powershell_single_quoted = Core.escape_powershell_single_quoted
local normalize_tag = Core.normalize_tag
local parse_tags_text = Core.parse_tags_text
local join_tags = Core.join_tags
local json_encode = Core.json_encode
local json_decode = Core.json_decode

local function ensure_directory_exists(path)
  return Core.ensure_directory_exists(reaper, path)
end

local write_text_file_utf8 = Core.write_text_file_utf8
local read_text_file_utf8 = Core.read_text_file_utf8

local function get_default_app_storage_dir()
  return Core.get_default_app_storage_dir(reaper, APP_NAME)
end

local function get_default_metadata_dir()
  return Core.get_default_metadata_dir(reaper, APP_NAME)
end

local function get_default_settings_path()
  return Core.get_default_settings_path(reaper, APP_NAME)
end

local function get_default_libraries_path()
  return Core.get_default_libraries_path(reaper, APP_NAME)
end

local hash_string_djb2 = Core.hash_string_djb2

local function build_temp_output_path(prefix, extension)
  return Core.build_temp_output_path(reaper, APP_NAME, prefix, extension, now_sec)
end

local function build_metadata_path_for_srt(srt_path)
  return Core.build_metadata_path_for_srt(reaper, APP_NAME, srt_path)
end

local parse_srt_content = Core.parse_srt_content

local get_filename = Core.get_filename
local compare_text_case_insensitive = Core.compare_text_case_insensitive

function get_default_font_path()
  return tostring(UI_CONFIG.fonts.default.path or "")
end

function get_font_candidate_paths()
  local candidates = {}
  local seen = {}

  local function add_candidate(path)
    path = trim(path or "")
    if path == "" then
      return
    end
    local key = normalize_search_text(path)
    if seen[key] then
      return
    end
    seen[key] = true
    candidates[#candidates + 1] = path
  end

  add_candidate(get_default_font_path())

  local os_name = reaper.GetOS and tostring(reaper.GetOS() or "") or ""
  if os_name:find("Win", 1, true) then
    add_candidate("C:\\Windows\\Fonts\\meiryo.ttc")
    add_candidate("C:\\Windows\\Fonts\\YuGothM.ttc")
    add_candidate("C:\\Windows\\Fonts\\msgothic.ttc")
    add_candidate("C:\\Windows\\Fonts\\segoeui.ttf")
  elseif os_name:find("OSX", 1, true) or os_name:find("macOS", 1, true) or os_name:find("Darwin", 1, true) then
    add_candidate("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
    add_candidate("/System/Library/Fonts/Supplemental/Helvetica.ttc")
    add_candidate("/Library/Fonts/Arial Unicode.ttf")
  else
    add_candidate("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc")
    add_candidate("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.otf")
    add_candidate("/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc")
    add_candidate("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
  end

  return candidates
end

function resolve_available_font_path(path, allow_fallback)
  local preferred = trim(path or "")
  if preferred ~= "" and file_exists(preferred) then
    return preferred, false
  end

  if allow_fallback == false then
    return nil, false
  end

  for _, candidate in ipairs(get_font_candidate_paths()) do
    if file_exists(candidate) then
      return candidate, normalize_search_text(candidate) ~= normalize_search_text(preferred)
    end
  end

  return nil, preferred ~= ""
end

function get_effective_font_path(path)
  return resolve_available_font_path(path, true)
end

function get_small_font_size_for(size)
  local base_size = tonumber(size) or (tonumber(UI_CONFIG.fonts.default.size) or 14)
  local default_size = tonumber(UI_CONFIG.fonts.default.size) or 14
  local default_small = tonumber(UI_CONFIG.fonts.small.size) or math.max(8, default_size - 1)
  local delta = default_size - default_small
  if delta < 1 then
    delta = 1
  end
  return math.max(8, base_size - delta)
end

function get_current_font_small()
  return font_small
end

function get_current_font_small_size()
  return font_small_size
end

function apply_ui_font_settings(path, size, options)
  options = options or {}
  if not (reaper.ImGui_CreateFont and reaper.ImGui_Attach) then
    return false, t("error.failed_create_font", trim(path or ""))
  end

  local requested_path = trim(path or "")
  local resolved_size = parse_integer(size, font_size or tonumber(UI_CONFIG.fonts.default.size) or 14)
  if not resolved_size or resolved_size <= 0 then
    return false, t("error.invalid_font_size")
  end

  local resolved_path, used_fallback = resolve_available_font_path(path, options.allow_fallback ~= false)
  local new_small_size = get_small_font_size_for(resolved_size)

  if not resolved_path or resolved_path == "" then
    if options.allow_default_font == true and requested_path == "" then
      font = nil
      font_size = resolved_size
      font_small = nil
      font_small_size = new_small_size
      return true, nil, used_fallback
    end
    return false, t("error.failed_create_font", requested_path)
  end

  local cache_key = resolved_path .. "@" .. tostring(resolved_size)
  local cache_entry = font_cache[cache_key]
  if not cache_entry then
    local new_font = reaper.ImGui_CreateFont(resolved_path, resolved_size)
    if not new_font then
      return false, t("error.failed_create_font", resolved_path)
    end

    local new_small_font = reaper.ImGui_CreateFont(resolved_path, new_small_size)
    if not new_small_font then
      return false, t("error.failed_create_font", resolved_path)
    end

    cache_entry = {
      font = new_font,
      small_font = new_small_font,
      small_size = new_small_size,
      attached = false,
    }
    font_cache[cache_key] = cache_entry
  end

  if not cache_entry.attached then
    reaper.ImGui_Attach(ctx, cache_entry.font)
    reaper.ImGui_Attach(ctx, cache_entry.small_font)
    cache_entry.attached = true
  end

  font = cache_entry.font
  font_size = resolved_size
  font_small = cache_entry.small_font
  font_small_size = cache_entry.small_size

  return true, resolved_path, used_fallback
end

apply_ui_font_settings(nil, font_size, { allow_fallback = true, allow_default_font = true })

local function normalize_virtual_folder_path(path)
  path = tostring(path or "")
  path = path:gsub("\\", "/")
  path = path:gsub("/+", "/")
  path = path:gsub("^/+", ""):gsub("/+$", "")

  local parts = {}
  for raw_part in path:gmatch("[^/]+") do
    local part = trim(raw_part)
    if part ~= "" and part ~= "." and part ~= ".." then
      parts[#parts + 1] = part
    end
  end

  return table.concat(parts, "/")
end

local function split_virtual_folder_path(path)
  local parts = {}
  local normalized = normalize_virtual_folder_path(path)
  if normalized == "" then
    return parts
  end

  for part in normalized:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end

  return parts
end

local function get_media_length_sec(path)
  return Core.get_media_length_sec(reaper, path)
end

--========================================================
-- App state
--========================================================

local app = {
  source = {
    srt_path = nil,
    srt_name = nil,
    srt_loaded = false,

    audio_path = nil,
    audio_name = nil,
    audio_loaded = false,
    audio_length_sec = nil,
    audio_files = {},
    audio_missing = false,
    audio_missing_path = nil,

    metadata_path = nil,
    metadata_loaded = false,
  },

  data = {
    items = {},
    items_revision = 0,
    global_offset_ms = 0,

    metadata_dirty = false,
    metadata_dirty_at = nil,
    last_save_at = 0,
    save_delay_sec = 1.5,
  },

  ui = {
    filter_text = "",
    filter_favorites_only = false,
    filter_tags = "",
    filter_revision = 0,
    offset_input = "0",
    library_search_open = false,
    left_panel_tab = "sources",
    pending_left_panel_tab = nil,
    content_mode = "source",
    active_library_id = nil,

    selected_item_keys = {},       -- [item_key] = true
    last_selected_item_key = nil,  -- 最後に選択したアイテム
    selection_anchor_key = nil,    -- Shift範囲選択の起点

    left_pane_width = UI_CONFIG.layout.left_pane_width or 400,
    detail_pane_height = UI_CONFIG.layout.detail_pane_height or 260,
    item_list_clipper = nil,
    source_tooltip_hovered_metadata_path = nil,
    source_tooltip_hover_started_at = nil,
    source_tooltip_delay_sec = 0.8,
    item_sort = {
      source = { column_key = "item.column.index", descending = false },
      library = { column_key = "item.column.srt", descending = false },
    },
    show_detail_pane = true,
    startup_view_restored = false,

    status = t("status.no_srt_loaded"),
    show_status_in_popup = false,
  },

  cache = {
    filtered_indices = {},
    filter_revision = -1,
    items_revision = -1,
  },

  preview = {
    backend = "none", -- "sws" or "none"

    handle = nil,
    root_source = nil,
    section_source = nil,

    is_playing = false,
    last_error = nil,
  },

  library = {
    query = "",
    results = {},
    status = t("status.library_search_idle"),
    scanned_files = 0,
    sources = {},
    sources_status = "Source library is idle.",
    sources_dirty = true,
    source_filter = "",
    selected_metadata_paths = {},
    last_selected_metadata_path = nil,
    selection_anchor_metadata_path = nil,
    folder_open_state = {},
  },

  settings = {
    path = nil,
    loaded = false,
    initialized = false,
    dirty = false,
    dirty_at = nil,
    save_delay_sec = 0.5,
    language = UI_CONFIG.app.default_language,
    recent_sources = {},
    last_opened_srt_path = nil,
    last_srt_browse_dir = nil,
    last_audio_browse_dir = nil,
    hide_speaker_labels = false,
    preview_volume = 90,
    font_path = nil,
    font_size = tonumber(UI_CONFIG.fonts.default.size) or 14,
    show_detail_pane = true,
    startup_content_mode = "source",
    startup_library_id = nil,
    left_pane_width = UI_CONFIG.layout.left_pane_width or 400,
    detail_pane_height = UI_CONFIG.layout.detail_pane_height or 260,
    item_table_column_widths = {
      source = {},
      library = {},
    },
    library_folders = {},
    source_folders = {},
    source_order = {},
  },

  user_libraries = {
    path = nil,
    loaded = false,
    initialized = false,
    dirty = false,
    dirty_at = nil,
    save_delay_sec = 0.5,
    entries = {},
    source_memberships = {},
    selected_library_id = nil,
    selected_member_metadata_path = nil,
    audio_length_cache = {},
  }
}

local load_srt_from_path
local load_audio_from_path
local clear_source_selection
local clear_selection
local set_single_source_selection
local set_single_selection
local prune_source_selection
local prompt_select_multiple_srt_paths_windows
local add_srt_paths_to_library
local invalidate_source_library_cache
local prepare_all_runtime_fields
local invalidate_items
local find_item_by_key
local flush_metadata_now
local clear_loaded_items
local mark_metadata_dirty
local save_metadata_json
local get_library_folder_by_id
local get_source_folder_id
local get_folder_id_by_parent_and_name
local ensure_library_folder_exists
local create_library_folder
local get_library_folder_children_ids
local is_descendant_folder_id
local rename_library_folder
local move_library_folder
local delete_library_folder
local assign_source_to_folder
local remove_source_folder_assignment
local append_source_to_order
local remove_source_from_order
local get_source_order_lookup
local move_source_order_entries_before_target
local move_source_order_entries_after_target
local refresh_source_library_cache
local load_source_entry
local search_library
local load_library_result
local prompt_create_library_folder
local prompt_rename_library_folder
local invalidate_filter_cache
local stop_preview
local trigger_ui_action
local SourcePane = {}
local LibraryStore = {}
local LibraryPane = {}

local function set_app_language(language)
  local normalized = trim(language)
  if normalized == "" then
    normalized = UI_CONFIG.app.default_language
  end
  i18n:set_language(normalized)
  app.settings.language = normalized
end

local function is_ui_entry_visible(entry)
  local visible_when = entry and entry.visible_when
  if visible_when == "library" then
    return app.ui.content_mode == "library"
  end
  if visible_when == "source" then
    return app.ui.content_mode ~= "library"
  end
  return true
end

local function get_item_table_columns_for_mode()
  if app.ui.content_mode == "library" then
    return UI_CONFIG.item_table_columns.library or {}
  end
  return UI_CONFIG.item_table_columns.source or {}
end


--========================================================
-- Metadata helpers
--========================================================

local function make_item_lookup_key(srt_index, start_ms, end_ms, text_value)
  return table.concat({
    tostring(srt_index or ""),
    tostring(start_ms or 0),
    tostring(end_ms or 0),
    tostring(text_value or ""),
  }, "|")
end

local function get_global_offset_ms()
  return parse_integer(app.data.global_offset_ms, 0) or 0
end

local function get_effective_item_bounds_ms(item)
  local offset_ms = 0
  if item and item.source_global_offset_ms ~= nil then
    offset_ms = parse_integer(item.source_global_offset_ms, 0) or 0
  else
    offset_ms = get_global_offset_ms()
  end
  local start_ms = parse_integer(item and item.start_ms, 0) or 0
  local end_ms = parse_integer(item and item.end_ms, 0) or 0
  return start_ms + offset_ms, end_ms + offset_ms
end

local function sync_offset_input_from_state()
  app.ui.offset_input = tostring(get_global_offset_ms())
end

local function copy_audio_file_entries(entries)
  local result = {}

  if type(entries) ~= "table" then
    return result
  end

  for _, entry in ipairs(entries) do
    if type(entry) == "table" then
      local path = tostring(entry.path or "")
      if path ~= "" then
        result[#result + 1] = {
          path = path,
          label = tostring(entry.label or ""),
          is_primary = entry.is_primary == true,
        }
      end
    end
  end

  return result
end

local function get_primary_audio_file_entry(entries)
  if type(entries) ~= "table" then
    return nil
  end

  for _, entry in ipairs(entries) do
    if type(entry) == "table" and entry.is_primary == true and tostring(entry.path or "") ~= "" then
      return entry
    end
  end

  for _, entry in ipairs(entries) do
    if type(entry) == "table" and tostring(entry.path or "") ~= "" then
      return entry
    end
  end

  return nil
end

local function normalize_recent_sources(entries)
  local result = {}
  local seen = {}

  if type(entries) ~= "table" then
    return result
  end

  for _, entry in ipairs(entries) do
    local path = tostring(entry or "")
    if path ~= "" then
      local key = normalize_search_text(path)
      if not seen[key] then
        seen[key] = true
        result[#result + 1] = path
      end
    end
    if #result >= 20 then
      break
    end
  end

  return result
end

local function normalize_folder_name(name)
  name = trim(name or "")
  name = name:gsub("%s+", " ")
  return name
end

local function build_folder_parent_key(parent_id)
  return parent_id == nil and "__root__" or tostring(parent_id)
end

local function generate_library_folder_id(existing_lookup, seed)
  existing_lookup = existing_lookup or {}
  local attempt = 0
  repeat
    local candidate = "fld_" .. hash_string_djb2(table.concat({
      tostring(seed or ""),
      tostring(now_sec()),
      tostring(math.random()),
      tostring(attempt),
    }, "|"))
    if not existing_lookup[candidate] then
      return candidate
    end
    attempt = attempt + 1
  until attempt > 1000

  return "fld_" .. tostring(math.floor(now_sec() * 1000))
end

local function get_library_folder_lookup(folders)
  local by_id = {}
  local children_by_parent = {}

  for _, folder in ipairs(folders or {}) do
    if type(folder) == "table" and tostring(folder.id or "") ~= "" then
      local folder_id = tostring(folder.id)
      by_id[folder_id] = folder

      local parent_key = build_folder_parent_key(folder.parent_id ~= "" and folder.parent_id or nil)
      children_by_parent[parent_key] = children_by_parent[parent_key] or {}
      children_by_parent[parent_key][#children_by_parent[parent_key] + 1] = folder
    end
  end

  for _, list in pairs(children_by_parent) do
    table.sort(list, function(a, b)
      if a.name ~= b.name then
        return compare_text_case_insensitive(a.name, b.name)
      end
      return tostring(a.id) < tostring(b.id)
    end)
  end

  return by_id, children_by_parent
end

local function get_library_folder_display_path(folder_id, folders_by_id, cache)
  folder_id = tostring(folder_id or "")
  if folder_id == "" then
    return ""
  end

  cache = cache or {}
  if cache[folder_id] ~= nil then
    return cache[folder_id]
  end

  local folder = folders_by_id and folders_by_id[folder_id] or nil
  if not folder then
    cache[folder_id] = ""
    return ""
  end

  local parent_id = folder.parent_id ~= "" and folder.parent_id or nil
  local parent_path = parent_id and get_library_folder_display_path(parent_id, folders_by_id, cache) or ""
  local path = parent_path ~= "" and (parent_path .. "/" .. tostring(folder.name or "")) or tostring(folder.name or "")
  cache[folder_id] = path
  return path
end

local function sort_library_folder_entries(entries)
  local folders_by_id = get_library_folder_lookup(entries)
  local path_cache = {}
  table.sort(entries, function(a, b)
    local path_a = get_library_folder_display_path(a.id, folders_by_id, path_cache)
    local path_b = get_library_folder_display_path(b.id, folders_by_id, path_cache)
    if path_a ~= path_b then
      return compare_text_case_insensitive(path_a, path_b)
    end
    return tostring(a.id) < tostring(b.id)
  end)
end

local function normalize_library_folder_entries(entries)
  local result = {}
  local seen_ids = {}

  if type(entries) ~= "table" then
    return result
  end

  for _, entry in ipairs(entries) do
    if type(entry) == "table" then
      local folder_id = tostring(entry.id or "")
      local folder_name = normalize_folder_name(entry.name)
      local parent_id = tostring(entry.parent_id or "")
      if folder_id ~= "" and folder_name ~= "" and not seen_ids[folder_id] then
        seen_ids[folder_id] = true
        result[#result + 1] = {
          id = folder_id,
          name = folder_name,
          parent_id = parent_id ~= "" and parent_id or nil,
        }
      end
    end
  end

  local valid_ids = {}
  for _, folder in ipairs(result) do
    valid_ids[folder.id] = true
  end

  local sibling_seen = {}
  local filtered = {}
  for _, folder in ipairs(result) do
    if folder.parent_id and not valid_ids[folder.parent_id] then
      folder.parent_id = nil
    end
    if folder.parent_id == folder.id then
      folder.parent_id = nil
    end

    local sibling_key = build_folder_parent_key(folder.parent_id) .. "|" .. normalize_search_text(folder.name)
    if not sibling_seen[sibling_key] then
      sibling_seen[sibling_key] = true
      filtered[#filtered + 1] = folder
    end
  end

  sort_library_folder_entries(filtered)
  return filtered
end

local function migrate_legacy_library_folder_state(folder_paths, source_folder_paths)
  local folders = {}
  local source_assignments = {}
  local path_to_id = {}
  local id_lookup = {}

  local function ensure_legacy_folder_path(folder_path)
    folder_path = normalize_virtual_folder_path(folder_path)
    if folder_path == "" then
      return nil
    end

    local existing_id = path_to_id[folder_path]
    if existing_id then
      return existing_id
    end

    local current_path = ""
    local parent_id = nil
    for _, part in ipairs(split_virtual_folder_path(folder_path)) do
      current_path = current_path == "" and part or (current_path .. "/" .. part)
      local folder_id = path_to_id[current_path]
      if not folder_id then
        folder_id = generate_library_folder_id(id_lookup, current_path)
        id_lookup[folder_id] = true
        path_to_id[current_path] = folder_id
        folders[#folders + 1] = {
          id = folder_id,
          name = part,
          parent_id = parent_id,
        }
      end
      parent_id = folder_id
    end

    return parent_id
  end

  if type(folder_paths) == "table" then
    for _, folder_path in ipairs(folder_paths) do
      ensure_legacy_folder_path(folder_path)
    end
  end

  if type(source_folder_paths) == "table" then
    for raw_metadata_path, raw_folder_path in pairs(source_folder_paths) do
      local metadata_path = tostring(raw_metadata_path or "")
      local folder_id = ensure_legacy_folder_path(raw_folder_path)
      if metadata_path ~= "" and folder_id then
        source_assignments[metadata_path] = folder_id
      end
    end
  end

  sort_library_folder_entries(folders)
  return folders, source_assignments
end

local function normalize_source_folder_entries(entries, valid_folder_ids)
  local result = {}

  if type(entries) ~= "table" then
    return result
  end

  valid_folder_ids = valid_folder_ids or {}

  for raw_metadata_path, raw_folder_id in pairs(entries) do
    local metadata_path = tostring(raw_metadata_path or "")
    local folder_id = tostring(raw_folder_id or "")
    if metadata_path ~= "" and folder_id ~= "" and valid_folder_ids[folder_id] then
      result[metadata_path] = folder_id
    end
  end

  return result
end

local function normalize_source_order_entries(entries)
  local result = {}
  local seen = {}

  if type(entries) ~= "table" then
    return result
  end

  for _, entry in ipairs(entries) do
    local metadata_path = tostring(entry or "")
    if metadata_path ~= "" then
      local key = normalize_search_text(metadata_path)
      if not seen[key] then
        seen[key] = true
        result[#result + 1] = metadata_path
      end
    end
  end

  return result
end

local function normalize_left_panel_tab(value)
  local normalized = tostring(value or "")
  if normalized == "libraries" then
    return "libraries"
  end
  return "sources"
end

local function normalize_folder_open_state_entries(entries, valid_folder_ids)
  local result = {}
  if type(entries) ~= "table" then
    return result
  end

  valid_folder_ids = valid_folder_ids or {}
  for raw_folder_id, raw_is_open in pairs(entries) do
    local folder_id = tostring(raw_folder_id or "")
    if folder_id ~= "" and (not next(valid_folder_ids) or valid_folder_ids[folder_id]) then
      result[folder_id] = raw_is_open == true
    end
  end

  return result
end

local function build_settings_payload()
  local folders = normalize_library_folder_entries(app.settings.library_folders)
  local valid_folder_ids = {}
  for _, folder in ipairs(folders) do
    valid_folder_ids[folder.id] = true
  end

  local column_widths = {
    source = {},
    library = {},
  }
  for mode_name, entries in pairs(app.settings.item_table_column_widths or {}) do
    if type(entries) == "table" and column_widths[mode_name] then
      for column_key, value in pairs(entries) do
        local width = tonumber(value)
        if width and width > 0 then
          column_widths[mode_name][tostring(column_key)] = width
        end
      end
    end
  end

  return {
    app_name = APP_NAME,
    language = app.settings.language or UI_CONFIG.app.default_language,
    last_opened_srt_path = app.settings.last_opened_srt_path or "",
    last_srt_browse_dir = app.settings.last_srt_browse_dir or "",
    last_audio_browse_dir = app.settings.last_audio_browse_dir or "",
    hide_speaker_labels = app.settings.hide_speaker_labels == true,
    preview_volume = tonumber(app.settings.preview_volume) or 90,
    font_path = trim(app.settings.font_path or ""),
    font_size = tonumber(app.settings.font_size) or font_size or tonumber(UI_CONFIG.fonts.default.size) or 14,
    show_detail_pane = app.ui.show_detail_pane ~= false,
    startup_content_mode = app.ui.content_mode == "library" and "library" or "source",
    startup_library_id = app.ui.content_mode == "library" and tostring(app.ui.active_library_id or "") or "",
    left_panel_tab = normalize_left_panel_tab(app.ui.left_panel_tab),
    left_pane_width = tonumber(app.ui.left_pane_width) or UI_CONFIG.layout.left_pane_width or 400,
    detail_pane_height = tonumber(app.ui.detail_pane_height) or UI_CONFIG.layout.detail_pane_height or 260,
    item_table_column_widths = column_widths,
    recent_sources = normalize_recent_sources(app.settings.recent_sources),
    library_folders = folders,
    folder_open_state = normalize_folder_open_state_entries(app.library.folder_open_state, valid_folder_ids),
    source_folders = normalize_source_folder_entries(app.settings.source_folders, valid_folder_ids),
    source_order = normalize_source_order_entries(app.settings.source_order),
  }
end

local function mark_settings_dirty()
  app.settings.dirty = true
  app.settings.dirty_at = now_sec()
end

local function normalize_preview_volume_percent(value)
  local parsed = parse_integer(value, nil)
  if parsed == nil then
    return nil
  end
  return clamp(parsed, 0, 100)
end

local function get_preview_volume_scalar()
  local percent = normalize_preview_volume_percent(app.settings.preview_volume)
  if percent == nil then
    percent = 90
  end
  return percent / 100.0, percent
end

local function apply_preview_volume_to_active_handle()
  if not (app.preview.handle and reaper.CF_Preview_SetValue) then
    return false
  end
  local volume = (get_preview_volume_scalar())
  return reaper.CF_Preview_SetValue(app.preview.handle, "D_VOLUME", volume) == true
end

function set_left_panel_tab(tab_name)
  local normalized = normalize_left_panel_tab(tab_name)
  if app.ui.left_panel_tab == normalized then
    return false
  end
  app.ui.left_panel_tab = normalized
  app.ui.pending_left_panel_tab = normalized
  mark_settings_dirty()
  return true
end

function restore_startup_view_if_needed()
  if app.ui.startup_view_restored then
    return
  end
  app.ui.startup_view_restored = true

  if app.settings.startup_content_mode == "library" then
    local library_id = tostring(app.settings.startup_library_id or "")
    if library_id ~= "" and LibraryStore.get_by_id and LibraryStore.get_by_id(library_id) then
      local ok = LibraryPane.load_view(library_id, {
        reset_filters = false,
      })
      if ok then
        return
      end
    end

    app.settings.startup_content_mode = "source"
    app.settings.startup_library_id = nil
    mark_settings_dirty()
  end

  local startup_srt_path = app.settings.last_opened_srt_path
  if startup_srt_path and startup_srt_path ~= "" then
    if file_exists(startup_srt_path) then
      load_srt_from_path(startup_srt_path, { reset_filters = true })
    else
      app.ui.status = t("status.settings_last_srt_missing")
      app.settings.last_opened_srt_path = nil
      mark_settings_dirty()
    end
  end
end

local function remember_recent_source(path)
  path = tostring(path or "")
  if path == "" then
    return
  end

  local recent_sources = { path }
  for _, entry in ipairs(app.settings.recent_sources or {}) do
    if normalize_search_text(entry) ~= normalize_search_text(path) then
      recent_sources[#recent_sources + 1] = entry
    end
    if #recent_sources >= 20 then
      break
    end
  end

  local changed = #recent_sources ~= #(app.settings.recent_sources or {})
  if not changed then
    for i, entry in ipairs(recent_sources) do
      if app.settings.recent_sources[i] ~= entry then
        changed = true
        break
      end
    end
  end

  if not changed then
    return
  end

  app.settings.recent_sources = recent_sources
  mark_settings_dirty()
end

local function set_last_opened_srt_path(path)
  path = tostring(path or "")
  if path == "" then
    path = nil
  end

  if app.settings.last_opened_srt_path == path then
    return
  end

  app.settings.last_opened_srt_path = path
  mark_settings_dirty()
end

function normalize_browse_dir(path)
  path = trim(path or "")
  if path == "" then
    return nil
  end

  path = path:gsub("[/\\]+$", "")
  if path == "" then
    return nil
  end

  return path
end

function remember_browse_file_path(kind, path)
  kind = tostring(kind or "")
  path = tostring(path or "")
  if kind == "" or path == "" then
    return
  end

  local dir = normalize_browse_dir(Core.get_parent_dir(path))
  if not dir then
    return
  end

  local field = kind == "audio" and "last_audio_browse_dir" or "last_srt_browse_dir"
  if app.settings[field] == dir then
    return
  end

  app.settings[field] = dir
  mark_settings_dirty()
end

function get_dialog_browse_dir(kind)
  kind = tostring(kind or "")

  if kind == "audio" then
    if app.settings.last_audio_browse_dir then
      return app.settings.last_audio_browse_dir
    end
    if app.source.audio_path and app.source.audio_path ~= "" then
      local audio_dir = normalize_browse_dir(Core.get_parent_dir(app.source.audio_path))
      if audio_dir then
        return audio_dir
      end
    end
    if app.source.srt_path and app.source.srt_path ~= "" then
      local srt_dir = normalize_browse_dir(Core.get_parent_dir(app.source.srt_path))
      if srt_dir then
        return srt_dir
      end
    end
  else
    if app.settings.last_srt_browse_dir then
      return app.settings.last_srt_browse_dir
    end
    if app.source.srt_path and app.source.srt_path ~= "" then
      local source_dir = normalize_browse_dir(Core.get_parent_dir(app.source.srt_path))
      if source_dir then
        return source_dir
      end
    end
  end

  return Core.get_initial_browse_dir(reaper)
end

function build_library_env()
  return {
    app = app,
    reaper = reaper,
    t = t,
    trim = trim,
    normalize_search_text = normalize_search_text,
    normalize_folder_name = normalize_folder_name,
    normalize_virtual_folder_path = normalize_virtual_folder_path,
    split_virtual_folder_path = split_virtual_folder_path,
    generate_library_folder_id = generate_library_folder_id,
    get_library_folder_lookup = get_library_folder_lookup,
    get_library_folder_display_path = get_library_folder_display_path,
    sort_library_folder_entries = sort_library_folder_entries,
    compare_text_case_insensitive = compare_text_case_insensitive,
    mark_settings_dirty = mark_settings_dirty,
    get_default_metadata_dir = get_default_metadata_dir,
    read_text_file_utf8 = read_text_file_utf8,
    json_decode = json_decode,
    copy_audio_file_entries = copy_audio_file_entries,
    get_primary_audio_file_entry = get_primary_audio_file_entry,
    file_exists = file_exists,
    get_filename = get_filename,
    parse_integer = parse_integer,
    join_tags = join_tags,
    parse_tags_text = parse_tags_text,
    format_ms = format_ms,
    make_item_lookup_key = make_item_lookup_key,
    contains_icase_blob = contains_icase_blob,
    strip_leading_speaker_label = strip_leading_speaker_label,
    invalidate_source_library_cache = function()
      if invalidate_source_library_cache then
        return invalidate_source_library_cache()
      end
    end,
    invalidate_filter_cache = function()
      if invalidate_filter_cache then
        return invalidate_filter_cache()
      end
    end,
    find_item_by_key = function(...)
      if find_item_by_key then
        return find_item_by_key(...)
      end
    end,
    set_single_selection = function(...)
      if set_single_selection then
        return set_single_selection(...)
      end
    end,
    prune_source_selection = function()
      if prune_source_selection then
        return prune_source_selection()
      end
    end,
    stop_preview = function()
      if stop_preview then
        return stop_preview()
      end
    end,
    load_srt_from_path = function(...)
      if load_srt_from_path then
        return load_srt_from_path(...)
      end
    end,
  }
end

local library_env = build_library_env()
require("reasrt.library")(library_env)
get_library_folder_by_id = library_env.get_library_folder_by_id
get_source_folder_id = library_env.get_source_folder_id
get_folder_id_by_parent_and_name = library_env.get_folder_id_by_parent_and_name
ensure_library_folder_exists = library_env.ensure_library_folder_exists
create_library_folder = library_env.create_library_folder
get_library_folder_children_ids = library_env.get_library_folder_children_ids
is_descendant_folder_id = library_env.is_descendant_folder_id
rename_library_folder = library_env.rename_library_folder
move_library_folder = library_env.move_library_folder
delete_library_folder = library_env.delete_library_folder
assign_source_to_folder = library_env.assign_source_to_folder
remove_source_folder_assignment = library_env.remove_source_folder_assignment
append_source_to_order = library_env.append_source_to_order
remove_source_from_order = library_env.remove_source_from_order
get_source_order_lookup = library_env.get_source_order_lookup
move_source_order_entries_before_target = library_env.move_source_order_entries_before_target
move_source_order_entries_after_target = library_env.move_source_order_entries_after_target
refresh_source_library_cache = library_env.refresh_source_library_cache
search_library = library_env.search_library
load_library_result = library_env.load_library_result
prompt_create_library_folder = library_env.prompt_create_library_folder
prompt_rename_library_folder = library_env.prompt_rename_library_folder

function build_library_logic_env()
  return {
    app = app,
    t = t,
    LibraryPane = LibraryPane,
    LibraryStore = LibraryStore,
    read_text_file_utf8 = read_text_file_utf8,
    json_decode = json_decode,
    json_encode = json_encode,
    write_text_file_utf8 = write_text_file_utf8,
    invalidate_source_library_cache = invalidate_source_library_cache,
    make_item_lookup_key = make_item_lookup_key,
    get_media_length_sec = get_media_length_sec,
    get_filename = get_filename,
    refresh_source_library_cache = refresh_source_library_cache,
    copy_audio_file_entries = copy_audio_file_entries,
    get_primary_audio_file_entry = get_primary_audio_file_entry,
    parse_integer = parse_integer,
    parse_tags_text = parse_tags_text,
    join_tags = join_tags,
    file_exists = file_exists,
    flush_metadata_now = flush_metadata_now,
    stop_preview = stop_preview,
    prepare_all_runtime_fields = prepare_all_runtime_fields,
    invalidate_items = invalidate_items,
    clear_selection = clear_selection,
    find_item_by_key = find_item_by_key,
    set_single_selection = set_single_selection,
    invalidate_filter_cache = invalidate_filter_cache,
    set_left_panel_tab = set_left_panel_tab,
    mark_settings_dirty = mark_settings_dirty,
  }
end

local function load_settings_json()
  local settings_path = get_default_settings_path()
  if settings_path == "" then
    return false, t("error.settings_path_unresolved")
  end

  app.settings.path = settings_path

  local content, err = read_text_file_utf8(settings_path)
  if not content then
    if err and err:find("Failed to open file", 1, true) then
      app.settings.loaded = true
      app.settings.language = UI_CONFIG.app.default_language
      app.settings.recent_sources = {}
      app.settings.last_opened_srt_path = nil
      app.settings.last_srt_browse_dir = nil
      app.settings.last_audio_browse_dir = nil
      app.settings.hide_speaker_labels = false
      app.settings.preview_volume = 90
      app.settings.font_path = nil
      app.settings.font_size = tonumber(UI_CONFIG.fonts.default.size) or 14
      app.settings.show_detail_pane = true
      app.settings.startup_content_mode = "source"
      app.settings.startup_library_id = nil
      app.ui.left_panel_tab = "sources"
      app.ui.pending_left_panel_tab = "sources"
      app.settings.left_pane_width = UI_CONFIG.layout.left_pane_width or 400
      app.settings.detail_pane_height = UI_CONFIG.layout.detail_pane_height or 260
      app.settings.item_table_column_widths = { source = {}, library = {} }
      app.settings.library_folders = {}
      app.settings.source_folders = {}
      app.settings.source_order = {}
      app.library.folder_open_state = {}
      app.ui.show_detail_pane = app.settings.show_detail_pane
      app.ui.left_pane_width = app.settings.left_pane_width
      app.ui.detail_pane_height = app.settings.detail_pane_height
      return true, t("status.settings_file_missing")
    end
    return false, err or t("error.failed_read_settings")
  end

  if content == "" then
    app.settings.loaded = true
    app.settings.language = UI_CONFIG.app.default_language
    app.settings.recent_sources = {}
    app.settings.last_opened_srt_path = nil
    app.settings.last_srt_browse_dir = nil
    app.settings.last_audio_browse_dir = nil
    app.settings.hide_speaker_labels = false
    app.settings.preview_volume = 90
    app.settings.font_path = nil
    app.settings.font_size = tonumber(UI_CONFIG.fonts.default.size) or 14
    app.settings.show_detail_pane = true
    app.settings.startup_content_mode = "source"
    app.settings.startup_library_id = nil
    app.ui.left_panel_tab = "sources"
    app.ui.pending_left_panel_tab = "sources"
    app.settings.left_pane_width = UI_CONFIG.layout.left_pane_width or 400
    app.settings.detail_pane_height = UI_CONFIG.layout.detail_pane_height or 260
    app.settings.item_table_column_widths = { source = {}, library = {} }
    app.settings.library_folders = {}
    app.settings.source_folders = {}
    app.settings.source_order = {}
    app.library.folder_open_state = {}
    app.ui.show_detail_pane = app.settings.show_detail_pane
    app.ui.left_pane_width = app.settings.left_pane_width
    app.ui.detail_pane_height = app.settings.detail_pane_height
    return true, t("status.settings_file_empty")
  end

  local ok, decoded = pcall(json_decode, content)
  if not ok or type(decoded) ~= "table" then
    return false, t("error.failed_parse_settings_json")
  end

  app.settings.language = trim(decoded.language or "") ~= "" and tostring(decoded.language) or UI_CONFIG.app.default_language
  app.settings.recent_sources = normalize_recent_sources(decoded.recent_sources)
  local last_opened = tostring(decoded.last_opened_srt_path or "")
  app.settings.last_opened_srt_path = last_opened ~= "" and last_opened or nil
  app.settings.last_srt_browse_dir = normalize_browse_dir(decoded.last_srt_browse_dir)
  app.settings.last_audio_browse_dir = normalize_browse_dir(decoded.last_audio_browse_dir)
  app.settings.hide_speaker_labels = decoded.hide_speaker_labels == true
  app.settings.preview_volume = normalize_preview_volume_percent(decoded.preview_volume)
    or normalize_preview_volume_percent(decoded.preview_volume_percent)
    or 90
  app.settings.font_path = trim(decoded.font_path or "")
  if app.settings.font_path == "" then
    app.settings.font_path = nil
  end
  app.settings.font_size = tonumber(decoded.font_size) or tonumber(UI_CONFIG.fonts.default.size) or 14
  app.settings.show_detail_pane = decoded.show_detail_pane ~= false
  app.settings.startup_content_mode = tostring(decoded.startup_content_mode or "source") == "library" and "library" or "source"
  local startup_library_id = trim(decoded.startup_library_id or "")
  app.settings.startup_library_id = startup_library_id ~= "" and startup_library_id or nil
  app.ui.left_panel_tab = normalize_left_panel_tab(decoded.left_panel_tab)
  app.ui.pending_left_panel_tab = app.ui.left_panel_tab
  app.settings.left_pane_width = tonumber(decoded.left_pane_width) or UI_CONFIG.layout.left_pane_width or 400
  app.settings.detail_pane_height = tonumber(decoded.detail_pane_height) or UI_CONFIG.layout.detail_pane_height or 260
  app.settings.item_table_column_widths = { source = {}, library = {} }
  if type(decoded.item_table_column_widths) == "table" then
    for _, mode_name in ipairs({ "source", "library" }) do
      local mode_widths = decoded.item_table_column_widths[mode_name]
      if type(mode_widths) == "table" then
        for column_key, value in pairs(mode_widths) do
          local width = tonumber(value)
          if width and width > 0 then
            app.settings.item_table_column_widths[mode_name][tostring(column_key)] = width
          end
        end
      end
    end
  end
  app.ui.show_detail_pane = app.settings.show_detail_pane
  app.ui.left_pane_width = app.settings.left_pane_width
  app.ui.detail_pane_height = app.settings.detail_pane_height

  local use_legacy_folder_state = false
  if type(decoded.library_folders) == "table" then
    for _, entry in ipairs(decoded.library_folders) do
      use_legacy_folder_state = type(entry) ~= "table"
      break
    end
  end
  if not use_legacy_folder_state and type(decoded.source_folders) == "table" then
    local has_folder_objects = false
    if type(decoded.library_folders) == "table" then
      for _, entry in ipairs(decoded.library_folders) do
        if type(entry) == "table" then
          has_folder_objects = true
          break
        end
      end
    end
    if not has_folder_objects then
      for _, value in pairs(decoded.source_folders) do
        if tostring(value or "") ~= "" then
          use_legacy_folder_state = true
          break
        end
      end
    end
  end

  if use_legacy_folder_state then
    app.settings.library_folders, app.settings.source_folders =
      migrate_legacy_library_folder_state(decoded.library_folders, decoded.source_folders)
    app.settings.source_order = normalize_source_order_entries(decoded.source_order)
    local valid_folder_ids = {}
    for _, folder in ipairs(app.settings.library_folders) do
      valid_folder_ids[folder.id] = true
    end
    app.library.folder_open_state = normalize_folder_open_state_entries(decoded.folder_open_state, valid_folder_ids)
    mark_settings_dirty()
  else
    app.settings.library_folders = normalize_library_folder_entries(decoded.library_folders)
    local valid_folder_ids = {}
    for _, folder in ipairs(app.settings.library_folders) do
      valid_folder_ids[folder.id] = true
    end
    app.library.folder_open_state = normalize_folder_open_state_entries(decoded.folder_open_state, valid_folder_ids)
    app.settings.source_folders = normalize_source_folder_entries(decoded.source_folders, valid_folder_ids)
    app.settings.source_order = normalize_source_order_entries(decoded.source_order)
  end

  app.settings.loaded = true
  return true, t("status.settings_loaded")
end

local function save_settings_json()
  local settings_path = app.settings.path or get_default_settings_path()
  if not settings_path or settings_path == "" then
    return false, t("error.settings_path_unresolved")
  end

  local app_dir = get_default_app_storage_dir()
  if app_dir == "" then
    return false, t("error.settings_dir_unresolved")
  end

  local ok_dir, dir_err = ensure_directory_exists(app_dir)
  if not ok_dir then
    return false, dir_err or t("error.failed_create_settings_dir")
  end

  app.settings.path = settings_path
  local encoded = json_encode(build_settings_payload())
  local ok, err = write_text_file_utf8(settings_path, encoded)
  if not ok then
    return false, err or t("error.failed_save_settings")
  end

  app.settings.loaded = true
  return true, settings_path
end

local function flush_settings_if_needed(force)
  if not app.settings.dirty then
    return
  end

  local now = now_sec()
  local dirty_at = app.settings.dirty_at or now
  if force or (now - dirty_at >= app.settings.save_delay_sec) then
    local ok, err = save_settings_json()
    if ok then
      app.settings.dirty = false
      app.settings.dirty_at = nil
    elseif err and err ~= "" then
      app.ui.status = err
    end
  end
end

local function initialize_settings_state()
  if app.settings.initialized then
    return
  end

  local ok, message = load_settings_json()
  app.settings.initialized = true

  if not ok then
    set_app_language(app.settings.language)
    local font_ok = apply_ui_font_settings(app.settings.font_path, app.settings.font_size, {
      allow_fallback = true,
      allow_default_font = true,
    })
    if not font_ok then
      app.settings.font_path = nil
      mark_settings_dirty()
    end
    app.ui.status = message or t("status.settings_load_failed")
    return
  end

  set_app_language(app.settings.language)
  local font_ok, resolved_font_path, used_fallback = apply_ui_font_settings(app.settings.font_path, app.settings.font_size, {
    allow_fallback = true,
    allow_default_font = true,
  })
  if not font_ok then
    app.settings.font_path = nil
    mark_settings_dirty()
  else
    local normalized_font_path = trim(app.settings.font_path or "")
    local normalized_resolved_path = trim(resolved_font_path or "")
    if normalized_font_path ~= normalized_resolved_path then
      app.settings.font_path = normalized_resolved_path ~= "" and normalized_resolved_path or nil
      mark_settings_dirty()
    elseif used_fallback and normalized_resolved_path == "" and app.settings.font_path ~= nil then
      app.settings.font_path = nil
      mark_settings_dirty()
    end
  end

  if app.settings.startup_content_mode ~= "library" then
    local startup_srt_path = app.settings.last_opened_srt_path
    if startup_srt_path and startup_srt_path ~= "" then
      if file_exists(startup_srt_path) then
        load_srt_from_path(startup_srt_path, { reset_filters = true })
      else
        app.ui.status = t("status.settings_last_srt_missing")
        app.settings.last_opened_srt_path = nil
        mark_settings_dirty()
      end
    end
  end
end

function build_library_store_env()
  return {
    app = app,
    APP_NAME = APP_NAME,
    t = t,
    now_sec = now_sec,
    trim = trim,
    normalize_folder_name = normalize_folder_name,
    compare_text_case_insensitive = compare_text_case_insensitive,
    normalize_source_order_entries = normalize_source_order_entries,
    normalize_search_text = normalize_search_text,
    hash_string_djb2 = hash_string_djb2,
    invalidate_items = invalidate_items,
    clear_selection = clear_selection,
    get_default_libraries_path = get_default_libraries_path,
    read_text_file_utf8 = read_text_file_utf8,
    json_decode = json_decode,
    get_default_app_storage_dir = get_default_app_storage_dir,
    ensure_directory_exists = ensure_directory_exists,
    json_encode = json_encode,
    write_text_file_utf8 = write_text_file_utf8,
    LibraryStore = LibraryStore,
  }
end

--========================================================
-- Runtime preparation
--========================================================

local function prepare_item_runtime_fields(item)
  local display_text = tostring(item.text or "")
  if app.settings.hide_speaker_labels == true then
    display_text = strip_leading_speaker_label(display_text)
  end
  item.metadata_lookup_key = make_item_lookup_key(item.srt_index, item.start_ms, item.end_ms, item.text)
  item.key = item.metadata_lookup_key
  if item.source_metadata_path and item.source_metadata_path ~= "" then
    item.key = tostring(item.source_metadata_path) .. "|" .. item.metadata_lookup_key
  end
  item.tags = parse_tags_text(item.tags_text)
  item.tags_text = join_tags(item.tags)
  item.favorite = item.favorite == true
  item.display_text = display_text
  item.text_single_line = collapse_text_to_single_line(display_text)
  local effective_start_ms, effective_end_ms = get_effective_item_bounds_ms(item)
  item.display_start = format_ms(effective_start_ms)
  item.display_end = format_ms(effective_end_ms)
  item.display_start_raw = format_ms(item.start_ms)
  item.display_end_raw = format_ms(item.end_ms)

  local row_parts = {}
  if item.source_name and item.source_name ~= "" then
    row_parts[#row_parts + 1] = "[" .. tostring(item.source_name) .. "]"
  end
  row_parts[#row_parts + 1] = string.format("%d:", item.srt_index or 0)
  if item.favorite then
    row_parts[#row_parts + 1] = "★"
  end
  row_parts[#row_parts + 1] = tostring(item.text_single_line or item.display_text or item.text or "")
  if item.tags_text ~= "" then
    row_parts[#row_parts + 1] = " [" .. item.tags_text .. "]"
  end
  item.row_label = table.concat(row_parts, " ")

  item.search_blob = normalize_search_text(
    table.concat({
      tostring(item.source_name or ""),
      tostring(item.display_text or item.text or ""),
      tostring(item.note or ""),
      tostring(item.tags_text or ""),
      item.favorite and "favorite" or "",
    }, "\n")
  )
end

prepare_all_runtime_fields = function()
  for _, item in ipairs(app.data.items) do
    prepare_item_runtime_fields(item)
  end
end

invalidate_filter_cache = function()
  app.ui.filter_revision = app.ui.filter_revision + 1
end

invalidate_items = function()
  app.data.items_revision = app.data.items_revision + 1
  invalidate_filter_cache()
end

--========================================================
-- Selection helpers
--========================================================

find_item_by_key = function(key)
  if not key then
    return nil, nil
  end

  for i, item in ipairs(app.data.items) do
    if item.key == key then
      return item, i
    end
  end

  return nil, nil
end

local function is_item_selected(key)
  return key ~= nil and app.ui.selected_item_keys[key] == true
end

clear_selection = function()
  app.ui.selected_item_keys = {}
  app.ui.last_selected_item_key = nil
  app.ui.selection_anchor_key = nil
end

require("reasrt.library_store")(build_library_store_env())

set_single_selection = function(key)
  app.ui.selected_item_keys = {}
  if key then
    app.ui.selected_item_keys[key] = true
  end
  app.ui.last_selected_item_key = key
  app.ui.selection_anchor_key = key
end

function add_selection(key)
  if not key then
    return
  end
  app.ui.selected_item_keys[key] = true
  app.ui.last_selected_item_key = key
  app.ui.selection_anchor_key = key
end

function toggle_selection(key)
  if not key then
    return
  end

  if app.ui.selected_item_keys[key] then
    app.ui.selected_item_keys[key] = nil

    if app.ui.last_selected_item_key == key then
      app.ui.last_selected_item_key = nil
    end
    if app.ui.selection_anchor_key == key then
      app.ui.selection_anchor_key = nil
    end

    if not app.ui.last_selected_item_key then
      for _, idx in ipairs(app.cache.filtered_indices or {}) do
        local item = app.data.items[idx]
        if item and app.ui.selected_item_keys[item.key] then
          app.ui.last_selected_item_key = item.key
        end
      end
    end

    if not app.ui.selection_anchor_key then
      app.ui.selection_anchor_key = app.ui.last_selected_item_key
    end
  else
    app.ui.selected_item_keys[key] = true
    app.ui.last_selected_item_key = key
    app.ui.selection_anchor_key = key
  end
end

function get_filtered_pos_by_key(key)
  if not key then
    return nil
  end

  local filtered_indices = app.cache.filtered_indices
  for pos, idx in ipairs(filtered_indices) do
    local item = app.data.items[idx]
    if item and item.key == key then
      return pos
    end
  end

  return nil
end

function select_range_between(anchor_key, target_key, keep_existing)
  local anchor_pos = get_filtered_pos_by_key(anchor_key)
  local target_pos = get_filtered_pos_by_key(target_key)

  if not target_pos then
    return
  end

  if not anchor_pos then
    set_single_selection(target_key)
    return
  end

  if not keep_existing then
    app.ui.selected_item_keys = {}
  end

  local start_pos = math.min(anchor_pos, target_pos)
  local end_pos = math.max(anchor_pos, target_pos)

  for pos = start_pos, end_pos do
    local idx = app.cache.filtered_indices[pos]
    local item = idx and app.data.items[idx] or nil
    if item then
      app.ui.selected_item_keys[item.key] = true
    end
  end

  app.ui.last_selected_item_key = target_key
  app.ui.selection_anchor_key = anchor_key
end

function get_selected_items_in_filtered_order()
  local result = {}
  for _, idx in ipairs(app.cache.filtered_indices) do
    local item = app.data.items[idx]
    if item and app.ui.selected_item_keys[item.key] then
      result[#result + 1] = item
    end
  end
  return result
end

function get_or_create_insertion_track()
  local track = nil

  if reaper.CountSelectedTracks and reaper.GetSelectedTrack then
    if reaper.CountSelectedTracks(0) > 0 then
      track = reaper.GetSelectedTrack(0, 0)
    end
  end

  if track then
    return track, false
  end

  if not (reaper.CountTracks and reaper.InsertTrackAtIndex and reaper.GetTrack) then
    return nil, false, t("error.track_creation_api_unavailable")
  end

  local track_count = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_count, true)

  track = reaper.GetTrack(0, track_count)
  if not track then
    return nil, false, t("error.failed_create_track")
  end

  if reaper.SetOnlyTrackSelected then
    reaper.SetOnlyTrackSelected(track)
  end

  return track, true
end

function get_selected_items_in_index_order()
  local result = {}
  for _, filtered_index in ipairs(app.cache.filtered_indices or {}) do
    local item = app.data.items[filtered_index]
    if item and app.ui.selected_item_keys[item.key] then
      result[#result + 1] = item
    end
  end

  return result
end

function get_selected_count()
  local n = 0
  for _, _ in pairs(app.ui.selected_item_keys) do
    n = n + 1
  end
  return n
end

function get_last_selected_item()
  return find_item_by_key(app.ui.last_selected_item_key)
end

function ensure_valid_selection()
  local filtered_indices = app.cache.filtered_indices

  if #filtered_indices == 0 then
    clear_selection()
    return
  end

  local valid_keys = {}
  for _, idx in ipairs(filtered_indices) do
    local item = app.data.items[idx]
    if item then
      valid_keys[item.key] = true
    end
  end

  local new_selected = {}
  local count = 0
  for key, selected in pairs(app.ui.selected_item_keys) do
    if selected and valid_keys[key] then
      new_selected[key] = true
      count = count + 1
    end
  end
  app.ui.selected_item_keys = new_selected

  if app.ui.last_selected_item_key and not valid_keys[app.ui.last_selected_item_key] then
    app.ui.last_selected_item_key = nil
  end

  if app.ui.selection_anchor_key and not valid_keys[app.ui.selection_anchor_key] then
    app.ui.selection_anchor_key = nil
  end

  if count == 0 then
    local first_idx = filtered_indices[1]
    local first_item = app.data.items[first_idx]
    if first_item then
      set_single_selection(first_item.key)
    end
  elseif not app.ui.last_selected_item_key then
    for _, idx in ipairs(filtered_indices) do
      local item = app.data.items[idx]
      if item and app.ui.selected_item_keys[item.key] then
        app.ui.last_selected_item_key = item.key
        break
      end
    end
    app.ui.selection_anchor_key = app.ui.selection_anchor_key or app.ui.last_selected_item_key
  end
end

function rebuild_filtered_cache_if_needed()
  local cache = app.cache
  if cache.filter_revision == app.ui.filter_revision
     and cache.items_revision == app.data.items_revision then
    return
  end

  local result = {}
  local needle = normalize_search_text(app.ui.filter_text)
  local include_tags = {}
  local exclude_tags = {}

  for raw in tostring(app.ui.filter_tags or ""):gmatch("%S+") do
    if raw:sub(1, 1) == "-" then
      local tag = normalize_search_text(normalize_tag(raw:sub(2)))
      if tag ~= "" then
        exclude_tags[#exclude_tags + 1] = tag
      end
    else
      local tag = normalize_search_text(normalize_tag(raw))
      if tag ~= "" then
        include_tags[#include_tags + 1] = tag
      end
    end
  end

  for i, item in ipairs(app.data.items) do
    local passes = contains_icase_blob(item.search_blob, needle)

    if passes and app.ui.filter_favorites_only and not item.favorite then
      passes = false
    end

    if passes and (#include_tags > 0 or #exclude_tags > 0) then
      local tag_lookup = {}
      for _, tag in ipairs(item.tags or {}) do
        tag_lookup[normalize_search_text(tag)] = true
      end

      for _, tag in ipairs(include_tags) do
        if not tag_lookup[tag] then
          passes = false
          break
        end
      end

      if passes then
        for _, tag in ipairs(exclude_tags) do
          if tag_lookup[tag] then
            passes = false
            break
          end
        end
      end
    end

    if passes then
      result[#result + 1] = i
    end
  end

  local sort_state = get_item_sort_state()
  table.sort(result, function(a_index, b_index)
    local a_item = app.data.items[a_index]
    local b_item = app.data.items[b_index]
    if not a_item or not b_item then
      return a_index < b_index
    end

    local comparison = compare_item_sort_values(
      get_item_sort_value(a_item, sort_state.column_key),
      get_item_sort_value(b_item, sort_state.column_key),
      sort_state.descending
    )
    if comparison ~= 0 then
      return comparison < 0
    end
    return a_index < b_index
  end)

  cache.filtered_indices = result
  cache.filter_revision = app.ui.filter_revision
  cache.items_revision = app.data.items_revision

  ensure_valid_selection()
end

function get_selected_filtered_pos()
  return get_filtered_pos_by_key(app.ui.last_selected_item_key)
end

function select_filtered_pos(pos)
  local filtered_indices = app.cache.filtered_indices
  local idx = filtered_indices[pos]
  local item = idx and app.data.items[idx] or nil
  if item then
    set_single_selection(item.key)
  else
    clear_selection()
  end
end

function select_next_filtered_item()
  local filtered_indices = app.cache.filtered_indices
  if #filtered_indices == 0 then
    app.ui.status = t("status.no_item_to_select")
    return
  end

  local pos = get_selected_filtered_pos()
  if not pos then
    select_filtered_pos(1)
    app.ui.status = t("status.selected_first_filtered_item")
    return
  end

  if pos < #filtered_indices then
    select_filtered_pos(pos + 1)
    app.ui.status = t("status.moved_to_next_filtered_item")
  else
    app.ui.status = t("status.already_last_filtered_item")
  end
end

--========================================================
-- Dirty / save framework
--========================================================

invalidate_source_library_cache = function()
  app.library.sources_dirty = true
end

function build_source_env()
  return {
    app = app,
    reaper = reaper,
    t = t,
    parse_tags_text = parse_tags_text,
    join_tags = join_tags,
    make_item_lookup_key = make_item_lookup_key,
    copy_audio_file_entries = copy_audio_file_entries,
    get_primary_audio_file_entry = get_primary_audio_file_entry,
    file_exists = file_exists,
    get_media_length_sec = get_media_length_sec,
    get_filename = get_filename,
    json_decode = json_decode,
    json_encode = json_encode,
    parse_integer = parse_integer,
    sync_offset_input_from_state = sync_offset_input_from_state,
    write_text_file_utf8 = write_text_file_utf8,
    read_text_file_utf8 = read_text_file_utf8,
    build_metadata_path_for_srt = build_metadata_path_for_srt,
    get_global_offset_ms = get_global_offset_ms,
    parse_srt_content = parse_srt_content,
    prepare_all_runtime_fields = prepare_all_runtime_fields,
    invalidate_items = invalidate_items,
    clear_selection = clear_selection,
    set_single_selection = set_single_selection,
    clear_source_selection = function()
      if clear_source_selection then
        return clear_source_selection()
      end
    end,
    invalidate_filter_cache = invalidate_filter_cache,
    invalidate_source_library_cache = invalidate_source_library_cache,
    now_sec = now_sec,
    remember_recent_source = remember_recent_source,
    set_last_opened_srt_path = set_last_opened_srt_path,
    remember_browse_file_path = remember_browse_file_path,
    append_source_to_order = append_source_to_order,
    mark_settings_dirty = mark_settings_dirty,
    set_left_panel_tab = set_left_panel_tab,
    normalize_search_text = normalize_search_text,
    compare_text_case_insensitive = compare_text_case_insensitive,
    join_path = Core.join_path,
    get_parent_dir = Core.get_parent_dir,
    get_file_stem = Core.get_file_stem,
    set_single_source_selection = function(metadata_path)
      if set_single_source_selection then
        return set_single_source_selection(metadata_path)
      end
    end,
    stop_preview = function()
      if stop_preview then
        return stop_preview()
      end
    end,
  }
end

local source_env = build_source_env()
require("reasrt.source")(source_env)
clear_loaded_items = source_env.clear_loaded_items
mark_metadata_dirty = source_env.mark_metadata_dirty
save_metadata_json = source_env.save_metadata_json
flush_metadata_now = source_env.flush_metadata_now
load_srt_from_path = source_env.load_srt_from_path
load_audio_from_path = source_env.load_audio_from_path
load_source_entry = source_env.load_source_entry

local function flush_metadata_if_needed(force)
  if not app.data.metadata_dirty then
    return
  end

  local now = now_sec()
  local dirty_at = app.data.metadata_dirty_at or now

  if force or (now - dirty_at >= app.data.save_delay_sec) then
    flush_metadata_now()
  end
end

--========================================================
-- Source loading
--========================================================

local function prompt_add_srt()
  local paths, multi_err = prompt_select_multiple_srt_paths_windows()
  if paths ~= nil then
    if #paths == 0 then
      app.ui.status = t("status.add_srt_canceled")
      return
    end
    remember_browse_file_path("srt", paths[1])
    add_srt_paths_to_library(paths)
    return
  end

  local initial_dir = get_dialog_browse_dir("srt")
  local retval, path = reaper.GetUserFileNameForRead(initial_dir, t("prompt.add_srt_title"), ".srt")
  if not retval or not path or path == "" then
    app.ui.status = t("status.add_srt_canceled")
    return
  end

  remember_browse_file_path("srt", path)
  if multi_err and multi_err ~= "" then
    app.ui.status = t("status.multi_select_unavailable_added_one")
  end
  add_srt_paths_to_library({ path })
end

local function prompt_open_audio()
  local initial_dir = get_dialog_browse_dir("audio")
  local retval, path = reaper.GetUserFileNameForRead(
    initial_dir,
    t("prompt.open_audio_title"),
    "wav;flac;mp3;aif;aiff;ogg"
  )
  if not retval or not path or path == "" then
    app.ui.status = t("status.audio_load_canceled")
    return
  end

  remember_browse_file_path("audio", path)
  if app.ui.content_mode == "library" then
    local item = get_last_selected_item()
    if not item or not item.source_metadata_path then
      app.ui.status = t("status.no_library_item_selected")
      return
    end
    LibraryPane.bind_audio_to_item(item, path)
    return
  end

  load_audio_from_path(path)
end

--========================================================
-- Preview helpers (SWS backend)
--========================================================

local function destroy_preview_sources()
  if app.preview.section_source then
    reaper.PCM_Source_Destroy(app.preview.section_source)
    app.preview.section_source = nil
  end

  if app.preview.root_source then
    reaper.PCM_Source_Destroy(app.preview.root_source)
    app.preview.root_source = nil
  end
end

local function clear_preview_state(keep_error)
  app.preview.handle = nil
  app.preview.is_playing = false
  app.preview.backend = "none"

  if not keep_error then
    app.preview.last_error = nil
  end

  destroy_preview_sources()
end

stop_preview = function()
  if app.preview.handle and reaper.CF_Preview_Stop then
    pcall(reaper.CF_Preview_Stop, app.preview.handle)
  end

  clear_preview_state(false)
end

require("reasrt.library_logic")(build_library_logic_env())

local function validate_item_against_audio(item)
  if not item then
    return false, t("status.no_subtitle_item_selected")
  end

  local audio_context = LibraryPane.resolve_item_audio_context(item)
  if audio_context.missing then
    return false, t("status.bound_audio_file_missing")
  end

  if not audio_context.loaded or not audio_context.path then
    return false, t("status.no_audio_file_bound")
  end

  local start_ms, end_ms = get_effective_item_bounds_ms(item)
  local start_sec = start_ms / 1000.0
  local end_sec   = end_ms / 1000.0
  local length_sec = end_sec - start_sec

  if length_sec <= 0 then
    return false, t("status.subtitle_invalid_duration", tostring(item.srt_index or "?"))
  end

  if start_sec < 0 then
    return false, t("status.subtitle_begins_before_audio", tostring(item.srt_index or "?"))
  end

  if audio_context.length_sec then
    if start_sec >= audio_context.length_sec then
      return false, t("status.subtitle_exceeds_audio_length", tostring(item.srt_index or "?"))
    end

    if end_sec > audio_context.length_sec then
      return false, t(
        "status.subtitle_end_exceeds_audio_length",
        tostring(item.srt_index or "?"),
        end_sec,
        audio_context.length_sec
      )
    end
  end

  return true, {
    item = item,
    audio_path = audio_context.path,
    audio_name = audio_context.name,
    start_sec = start_sec,
    end_sec = end_sec,
    length_sec = length_sec,
  }
end

local function validate_preview_target_against_audio()
  local item = get_last_selected_item()
  return validate_item_against_audio(item)
end

local function validate_multiple_items_against_audio(items)
  if not items or #items == 0 then
    return false, t("status.no_subtitle_item_selected")
  end

  local validated = {}

  for _, item in ipairs(items) do
    local ok, info = validate_item_against_audio(item)
    if not ok then
      return false, info
    end
    validated[#validated + 1] = info
  end

  return true, validated
end


local function build_sws_preview_for_selected()
  local sws_ok, sws_message = Core.get_preview_backend_status(reaper)
  if not sws_ok then
    return false, sws_message
  end

  local ok_validate, info = validate_preview_target_against_audio()
  if not ok_validate then
    return false, info
  end

  local item = info.item
  local start_sec = info.start_sec
  local end_sec = info.end_sec
  local length_sec = info.length_sec

  local root_source = reaper.PCM_Source_CreateFromFile(info.audio_path)
  if not root_source then
    return false, t("status.failed_create_pcm_source")
  end

  local section_source = reaper.PCM_Source_CreateFromType("SECTION")
  if not section_source then
    reaper.PCM_Source_Destroy(root_source)
    return false, t("status.failed_create_section_source")
  end

  local ok = reaper.CF_PCM_Source_SetSectionInfo(
    section_source,
    root_source,
    start_sec,
    length_sec,
    false
  )

  if not ok then
    reaper.PCM_Source_Destroy(section_source)
    reaper.PCM_Source_Destroy(root_source)
    return false, t("status.failed_set_section_info")
  end

  local preview = reaper.CF_CreatePreview(section_source)
  if not preview then
    reaper.PCM_Source_Destroy(section_source)
    reaper.PCM_Source_Destroy(root_source)
    return false, t("status.failed_create_preview")
  end

  -- 末尾クリック軽減用のごく短いフェード
  reaper.CF_Preview_SetValue(preview, "D_FADEINLEN", 0.005)
  reaper.CF_Preview_SetValue(preview, "D_FADEOUTLEN", 0.005)
  reaper.CF_Preview_SetValue(preview, "D_VOLUME", (get_preview_volume_scalar()))
  reaper.CF_Preview_SetValue(preview, "D_PLAYRATE", 1.0)

  app.preview.handle = preview
  app.preview.root_source = root_source
  app.preview.section_source = section_source
  app.preview.backend = "sws"
  app.preview.is_playing = false
  app.preview.last_error = nil

  return true, {
    subtitle = item,
    expected_length = length_sec,
  }
end

local function start_preview_selected()
  stop_preview()

  local ok, result = build_sws_preview_for_selected()
  if not ok then
    app.preview.last_error = result
    app.ui.status = result
    return
  end

  local play_ok = reaper.CF_Preview_Play(app.preview.handle)
  if not play_ok then
    app.preview.last_error = t("status.failed_preview_play")
    app.ui.status = app.preview.last_error
    stop_preview()
    return
  end

  app.preview.is_playing = true
  local preview_label = tostring(result.subtitle.srt_index or "")
  if result.subtitle.source_name and result.subtitle.source_name ~= "" then
    preview_label = ("%s / %s"):format(tostring(result.subtitle.source_name), preview_label)
  end
  app.ui.status = t("status.preview_subtitle", preview_label)
end

local function update_preview_playback()
  if not app.preview.handle then
    return
  end

  if not reaper.CF_Preview_GetValue then
    app.preview.last_error = t("status.preview_api_unavailable")
    clear_preview_state(true)
    app.ui.status = app.preview.last_error
    return
  end

  local ok_pos, pos = reaper.CF_Preview_GetValue(app.preview.handle, "D_POSITION", 0)
  local ok_len, len = reaper.CF_Preview_GetValue(app.preview.handle, "D_LENGTH", 0)

  -- preview が自動破棄済み、または取得不能になった場合
  if not ok_pos or not ok_len then
    clear_preview_state(false)
    return
  end

  if pos >= (len - 0.001) then
    stop_preview()
    app.ui.status = t("status.preview_finished")
  end
end

local function set_take_name(take, name)
  if not take then
    return
  end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", tostring(name or ""), true)
end

local function insert_item_at_position(item, position_sec, track)
  local ok_validate, info = validate_item_against_audio(item)
  if not ok_validate then
    return false, info
  end

  local start_sec = info.start_sec
  local length_sec = info.length_sec

  local src = reaper.PCM_Source_CreateFromFile(info.audio_path)
  if not src then
    return false, t("status.failed_create_pcm_source")
  end

  local media_item = reaper.AddMediaItemToTrack(track)
  if not media_item then
    reaper.PCM_Source_Destroy(src)
    return false, t("status.failed_create_media_item")
  end

  local take = reaper.AddTakeToMediaItem(media_item)
  if not take then
    reaper.DeleteTrackMediaItem(track, media_item)
    reaper.PCM_Source_Destroy(src)
    return false, t("status.failed_create_take")
  end

  reaper.SetMediaItemInfo_Value(media_item, "D_POSITION", position_sec)
  reaper.SetMediaItemInfo_Value(media_item, "D_LENGTH", length_sec)

  local ok_source = reaper.SetMediaItemTake_Source(take, src)
  if ok_source == false then
    reaper.DeleteTrackMediaItem(track, media_item)
    reaper.PCM_Source_Destroy(src)
    return false, t("status.failed_set_take_source")
  end

  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_sec)
  set_take_name(take, item.display_text or item.text)

  reaper.UpdateItemInProject(media_item)

  return true, media_item, length_sec
end

local function insert_selected_items_at_cursor()
  if not reaper.GetCursorPosition then
    app.ui.status = t("status.cursor_api_unavailable")
    return false, app.ui.status
  end

  local items = get_selected_items_in_index_order()
  if #items == 0 then
    app.ui.status = t("status.no_subtitle_item_selected")
    return false, app.ui.status
  end

  local ok_validate, validated_or_err = validate_multiple_items_against_audio(items)
  if not ok_validate then
    app.ui.status = validated_or_err
    return false, app.ui.status
  end

  local track, created, track_err = get_or_create_insertion_track()
  if not track then
    app.ui.status = track_err or t("status.no_insertion_track_available")
    return false, app.ui.status
  end

  local insert_pos = reaper.GetCursorPosition()
  local current_pos = insert_pos

  for _, info in ipairs(validated_or_err) do
    local ok_insert, media_item_or_err, length_sec = insert_item_at_position(info.item, current_pos, track)
    if not ok_insert then
      app.ui.status = media_item_or_err
      reaper.UpdateArrange()
      return false, app.ui.status
    end

    current_pos = current_pos + length_sec
  end

  reaper.UpdateArrange()

  if reaper.SetEditCurPos then
    reaper.SetEditCurPos(current_pos, false, false)
  end

  if created then
    app.ui.status = t("status.inserted_items_new_track", #items, current_pos)
  else
    app.ui.status = t("status.inserted_items", #items, current_pos)
  end

  return true, true
end


--========================================================
-- Update helpers
--========================================================

local function update_selected_favorite(new_value)
  local item = get_last_selected_item()
  if not item then
    return
  end

  local favorite = new_value == true
  if item.favorite == favorite then
    return
  end

  if app.ui.content_mode == "library" and item.source_metadata_path then
    local ok, err = LibraryPane.update_item_metadata(item, function(_, meta_item)
      meta_item.favorite = favorite
    end)
    if not ok then
      app.ui.status = err or t("status.failed_update_favorite")
      return
    end
  else
    mark_metadata_dirty()
  end

  item.favorite = favorite
  prepare_item_runtime_fields(item)
  invalidate_items()
  app.ui.status = favorite and t("status.favorite_enabled") or t("status.favorite_disabled")
end

local function update_selected_tags_text(new_tags_text)
  local item = get_last_selected_item()
  if not item then
    return
  end

  local normalized = join_tags(parse_tags_text(new_tags_text))
  if item.tags_text == normalized then
    return
  end

  if app.ui.content_mode == "library" and item.source_metadata_path then
    local tags = parse_tags_text(normalized)
    local ok, err = LibraryPane.update_item_metadata(item, function(_, meta_item)
      meta_item.tags = tags
      meta_item.tags_text = join_tags(tags)
    end)
    if not ok then
      app.ui.status = err or t("status.failed_update_tags")
      return
    end
  else
    mark_metadata_dirty()
  end

  item.tags_text = normalized
  item.tags = parse_tags_text(normalized)
  prepare_item_runtime_fields(item)
  invalidate_items()
  app.ui.status = t("status.tags_updated")
end

local function prompt_edit_selected_tags()
  local item = get_last_selected_item()
  if not item then
    app.ui.status = t("empty.no_item_selected")
    return false
  end

  if not reaper.GetUserInputs then
    app.ui.status = t("status.failed_update_tags")
    return false
  end

  local ok, value = reaper.GetUserInputs(
    t("prompt.edit_tags_title"),
    1,
    t("prompt.edit_tags_value"),
    tostring(item.tags_text or "")
  )
  if not ok then
    return false
  end

  update_selected_tags_text(value)
  return true
end

local function set_global_offset_ms(new_offset_ms)
  local normalized = parse_integer(new_offset_ms, 0) or 0
  if normalized == get_global_offset_ms() then
    sync_offset_input_from_state()
    app.ui.status = t("status.global_offset_unchanged", format_signed_ms(normalized))
    return false
  end

  if app.preview.is_playing then
    stop_preview()
  end

  app.data.global_offset_ms = normalized
  sync_offset_input_from_state()
  prepare_all_runtime_fields()
  invalidate_items()
  mark_metadata_dirty()
  app.ui.status = t("status.global_offset_set", format_signed_ms(normalized))
  return true
end

local function extract_speaker_tag(text)
  text = tostring(text or "")
  local full_open = string.char(239, 188, 136)
  local full_close = string.char(239, 188, 137)
  local speaker = text:match("^%s*" .. full_open .. "%s*(.-)%s*" .. full_close)
  if not speaker then
    speaker = text:match("^%s*%(%s*(.-)%s*%)")
  end
  speaker = normalize_tag(speaker)
  if speaker == "" then
    return nil
  end
  if speaker:find("[\r\n]") then
    return nil
  end
  return speaker
end

local function apply_speaker_tags_to_items()
  if not app.source.srt_loaded then
    app.ui.status = t("status.no_srt_loaded")
    return false
  end

  local detected_count = 0
  local added_count = 0

  for _, item in ipairs(app.data.items) do
    local speaker = extract_speaker_tag(item.text)
    if speaker then
      detected_count = detected_count + 1
      local tags = item.tags or parse_tags_text(item.tags_text)
      local exists = false
      for _, tag in ipairs(tags) do
        if normalize_search_text(tag) == normalize_search_text(speaker) then
          exists = true
          break
        end
      end
      if not exists then
        tags[#tags + 1] = speaker
        item.tags = tags
        item.tags_text = join_tags(tags)
        prepare_item_runtime_fields(item)
        added_count = added_count + 1
      end
    end
  end

  if added_count > 0 then
    invalidate_items()
    mark_metadata_dirty()
    app.ui.status = t("status.speaker_tags_added", added_count)
    return true
  end

  if detected_count > 0 then
    app.ui.status = t("status.speaker_tags_already_present")
    return false
  end

  app.ui.status = t("status.speaker_tags_none_found")
  return false
end

local function set_hide_speaker_labels_enabled(enabled)
  enabled = enabled == true
  if app.settings.hide_speaker_labels == enabled then
    return false
  end

  app.settings.hide_speaker_labels = enabled
  prepare_all_runtime_fields()
  invalidate_items()
  mark_settings_dirty()

  if app.library.query and app.library.query ~= "" then
    search_library(app.library.query)
  end

  app.ui.status = enabled
    and t("status.hide_speaker_labels_enabled")
    or t("status.hide_speaker_labels_disabled")
  return true
end

function prompt_set_font_size()
  if not reaper.GetUserInputs then
    app.ui.status = t("error.invalid_font_size")
    return false
  end

  local current_value = tostring(app.settings.font_size or font_size or tonumber(UI_CONFIG.fonts.default.size) or 14)
  local ok, value = reaper.GetUserInputs(
    t("prompt.font_size_title"),
    1,
    t("prompt.font_size_value"),
    current_value
  )
  if not ok then
    return false
  end

  local new_size = parse_integer(value, nil)
  if not new_size or new_size <= 0 then
    app.ui.status = t("error.invalid_font_size")
    return false
  end

  local applied, err = apply_ui_font_settings(app.settings.font_path, new_size, {
    allow_fallback = true,
    allow_default_font = true,
  })
  if not applied then
    app.ui.status = err or t("error.invalid_font_size")
    return false
  end

  app.settings.font_size = new_size
  mark_settings_dirty()
  app.ui.status = t("status.font_size_updated", new_size)
  return true
end

function prompt_set_preview_volume()
  if not reaper.GetUserInputs then
    app.ui.status = t("error.invalid_preview_volume")
    return false
  end

  local current_value = tostring(normalize_preview_volume_percent(app.settings.preview_volume) or 90)
  local ok, value = reaper.GetUserInputs(
    t("prompt.preview_volume_title"),
    1,
    t("prompt.preview_volume_value"),
    current_value
  )
  if not ok then
    return false
  end

  local new_volume = normalize_preview_volume_percent(value)
  if new_volume == nil then
    app.ui.status = t("error.invalid_preview_volume")
    return false
  end

  app.settings.preview_volume = new_volume
  mark_settings_dirty()
  apply_preview_volume_to_active_handle()
  app.ui.status = t("status.preview_volume_updated", new_volume)
  return true
end

function prompt_set_font_path()
  if not reaper.GetUserInputs then
    app.ui.status = t("error.failed_create_font", get_default_font_path())
    return false
  end

  local current_value = tostring(app.settings.font_path or get_default_font_path() or "")
  local ok, value = reaper.GetUserInputs(
    t("prompt.font_path_title"),
    1,
    t("prompt.font_path_value"),
    current_value
  )
  if not ok then
    return false
  end

  local new_path = trim(value or "")
  if new_path == "" then
    new_path = nil
  end

  local applied, resolved_path = apply_ui_font_settings(new_path, app.settings.font_size or font_size, {
    allow_fallback = new_path == nil,
    allow_default_font = true,
  })
  if not applied then
    app.ui.status = resolved_path or t("error.failed_create_font", get_default_font_path())
    return false
  end

  if new_path == nil then
    app.settings.font_path = resolved_path and resolved_path ~= "" and resolved_path or nil
  else
    app.settings.font_path = resolved_path
  end
  mark_settings_dirty()
  app.ui.status = t("status.font_path_updated", resolved_path or t("label.none"))
  return true
end

clear_source_selection = function()
  app.library.selected_metadata_paths = {}
  app.library.last_selected_metadata_path = nil
  app.library.selection_anchor_metadata_path = nil
end

local function get_selected_source_count()
  local count = 0
  for _, selected in pairs(app.library.selected_metadata_paths or {}) do
    if selected then
      count = count + 1
    end
  end
  return count
end

local function is_source_selected(metadata_path)
  return metadata_path ~= nil and app.library.selected_metadata_paths[metadata_path] == true
end

set_single_source_selection = function(metadata_path)
  app.library.selected_metadata_paths = {}
  if metadata_path then
    app.library.selected_metadata_paths[metadata_path] = true
  end
  app.library.last_selected_metadata_path = metadata_path
  app.library.selection_anchor_metadata_path = metadata_path
end

local function toggle_source_selection(metadata_path)
  if not metadata_path then
    return
  end

  if app.library.selected_metadata_paths[metadata_path] then
    app.library.selected_metadata_paths[metadata_path] = nil

    if app.library.last_selected_metadata_path == metadata_path then
      app.library.last_selected_metadata_path = nil
    end
    if app.library.selection_anchor_metadata_path == metadata_path then
      app.library.selection_anchor_metadata_path = nil
    end
  else
    app.library.selected_metadata_paths[metadata_path] = true
    app.library.last_selected_metadata_path = metadata_path
    app.library.selection_anchor_metadata_path = metadata_path
  end
end

function build_source_logic_env()
  return {
    app = app,
    ctx = ctx,
    reaper = reaper,
    t = t,
    trim = trim,
    normalize_search_text = normalize_search_text,
    contains_icase_blob = contains_icase_blob,
    get_selected_source_count = get_selected_source_count,
    set_single_source_selection = set_single_source_selection,
    is_source_selected = is_source_selected,
    toggle_source_selection = toggle_source_selection,
    clear_source_selection = clear_source_selection,
    refresh_source_library_cache = refresh_source_library_cache,
    invalidate_source_library_cache = invalidate_source_library_cache,
    get_library_folder_lookup = get_library_folder_lookup,
    get_library_folder_display_path = get_library_folder_display_path,
    move_source_order_entries_before_target = move_source_order_entries_before_target,
    move_source_order_entries_after_target = move_source_order_entries_after_target,
    compare_text_case_insensitive = compare_text_case_insensitive,
    get_source_order_lookup = get_source_order_lookup,
    load_source_entry = load_source_entry,
    prompt_open_audio = prompt_open_audio,
    flush_metadata_now = flush_metadata_now,
    LibraryStore = LibraryStore,
    remove_source_folder_assignment = remove_source_folder_assignment,
    remove_source_from_order = remove_source_from_order,
    file_exists = file_exists,
    delete_file = delete_file,
    stop_preview = stop_preview,
    clear_loaded_items = clear_loaded_items,
    set_last_opened_srt_path = set_last_opened_srt_path,
    prune_source_selection = prune_source_selection,
    get_filename = get_filename,
    save_metadata_json = save_metadata_json,
    load_srt_from_path = load_srt_from_path,
    now_sec = now_sec,
    assign_source_to_folder = assign_source_to_folder,
    get_source_folder_id = get_source_folder_id,
    mark_settings_dirty = mark_settings_dirty,
    SourcePane = SourcePane,
    LibraryPane = LibraryPane,
  }
end

prune_source_selection = function()
  local valid = {}
  for _, entry in ipairs(app.library.sources or {}) do
    if entry.metadata_path then
      valid[entry.metadata_path] = true
    end
  end

  local new_selected = {}
  local count = 0
  for metadata_path, selected in pairs(app.library.selected_metadata_paths or {}) do
    if selected and valid[metadata_path] then
      new_selected[metadata_path] = true
      count = count + 1
    end
  end
  app.library.selected_metadata_paths = new_selected

  if app.library.last_selected_metadata_path and not valid[app.library.last_selected_metadata_path] then
    app.library.last_selected_metadata_path = nil
  end

  if app.library.selection_anchor_metadata_path and not valid[app.library.selection_anchor_metadata_path] then
    app.library.selection_anchor_metadata_path = nil
  end

  if count == 0 and app.source.metadata_path then
    set_single_source_selection(app.source.metadata_path)
  end
end

require("reasrt.source_logic")(build_source_logic_env())

local function build_minimal_metadata_payload_for_srt(path, items)
  local payload_items = {}

  for _, item in ipairs(items or {}) do
    payload_items[#payload_items + 1] = {
      key = {
        srt_index = item.srt_index,
        start_ms = item.start_ms,
        end_ms = item.end_ms,
        text = item.text,
      },
      tags = {},
      note = "",
      favorite = false,
    }
  end

  return {
    version = 1,
    source = {
      srt_path = path or "",
      srt_filename = get_filename(path) or "",
    },
    audio_files = {},
    global_offset_ms = 0,
    items = payload_items,
  }
end

function find_auto_audio_path_for_srt(path)
  path = tostring(path or "")
  if path == "" or not (reaper and reaper.EnumerateFiles) then
    return nil
  end

  local dir_path = Core.get_parent_dir(path)
  local srt_stem = normalize_search_text(Core.get_file_stem(path))
  if dir_path == "" or srt_stem == "" then
    return nil
  end

  local exact = {}
  local partial = {}
  local index = 0
  while true do
    local name = reaper.EnumerateFiles(dir_path, index)
    if not name or name == "" then
      break
    end

    local normalized_name = normalize_search_text(name)
    if normalized_name:match("%.wav$") then
      local stem = normalize_search_text(Core.get_file_stem(name))
      if stem == srt_stem then
        exact[#exact + 1] = name
      elseif stem:find(srt_stem, 1, true) then
        partial[#partial + 1] = name
      end
    end

    index = index + 1
  end

  local candidates = #exact > 0 and exact or partial
  if #candidates == 0 then
    return nil
  end

  table.sort(candidates, function(a, b)
    if #a ~= #b then
      return #a < #b
    end

    local normalized_a = normalize_search_text(a)
    local normalized_b = normalize_search_text(b)
    if normalized_a ~= normalized_b then
      return compare_text_case_insensitive(a, b)
    end

    return a < b
  end)

  return Core.join_path(dir_path, candidates[1])
end

local function ensure_srt_in_library(path)
  path = tostring(path or "")
  if path == "" then
    return false, t("status.srt_path_empty")
  end

  if not file_exists(path) then
    return false, t("status.selected_srt_file_missing")
  end

  local metadata_path, metadata_err = build_metadata_path_for_srt(path)
  if not metadata_path then
    return false, metadata_err or t("status.failed_resolve_metadata_path")
  end

  if file_exists(metadata_path) then
    return true, metadata_path, false
  end

  local content, err = read_text_file_utf8(path)
  if not content then
    return false, err or t("status.failed_read_srt")
  end

  local items = parse_srt_content(content)
  if #items == 0 then
    return false, t("status.no_subtitle_items_in_srt")
  end

  local payload = build_minimal_metadata_payload_for_srt(path, items)
  local auto_audio_path = find_auto_audio_path_for_srt(path)
  if auto_audio_path then
    payload.audio_files = {
      {
        path = auto_audio_path,
        label = "primary",
        is_primary = true,
      }
    }
  end
  local encoded = json_encode(payload)
  local ok, write_err = write_text_file_utf8(metadata_path, encoded)
  if not ok then
    return false, write_err or t("status.failed_create_metadata")
  end

  return true, metadata_path, true
end

prompt_select_multiple_srt_paths_windows = function()
  if not reaper.ExecProcess then
    return nil, t("status.execprocess_unavailable")
  end

  local output_path, path_err = build_temp_output_path("srt_picker", ".txt")
  if not output_path then
    return nil, path_err or t("status.failed_resolve_temp_output_path")
  end

  local output_path_escaped = escape_powershell_single_quoted(output_path)
  local initial_dir = get_dialog_browse_dir("srt")
  local initial_dir_command = ""
  if initial_dir and initial_dir ~= "" then
    initial_dir_command = "$dlg.InitialDirectory = '" .. escape_powershell_single_quoted(initial_dir) .. "'; "
  end
  local command = [[powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Multiselect = $true; $dlg.Filter = 'SRT files (*.srt)|*.srt|All files (*.*)|*.*'; ]] .. initial_dir_command .. [[$dlg.Title = ']] .. escape_powershell_single_quoted(t("prompt.add_srt_title")) .. [['; if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $enc = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllLines(']] .. output_path_escaped .. [[', $dlg.FileNames, $enc) }"]]
  local output = reaper.ExecProcess(command, 0)
  if output == nil then
    return nil, t("status.failed_launch_multi_select_dialog")
  end

  local exit_code = parse_execprocess_result(output)
  if exit_code ~= 0 then
    return nil, t("status.multi_select_exit_code", tostring(exit_code))
  end

  local content = nil
  if file_exists(output_path) then
    local read_err = nil
    content, read_err = read_text_file_utf8(output_path)
    delete_file(output_path)
    if not content then
      return nil, read_err or t("status.failed_read_selected_srt_paths")
    end
  else
    return {}
  end

  local paths = {}
  local seen = {}
  for _, line in ipairs(split_lines_preserve_empty(content)) do
    local path = trim(line)
    if path ~= "" then
      local key = normalize_search_text(path)
      if not seen[key] then
        seen[key] = true
        paths[#paths + 1] = path
      end
    end
  end

  return paths
end

add_srt_paths_to_library = function(paths)
  local unique_paths = {}
  local seen = {}

  for _, raw_path in ipairs(paths or {}) do
    local path = trim(raw_path)
    if path ~= "" then
      local key = normalize_search_text(path)
      if not seen[key] then
        seen[key] = true
        unique_paths[#unique_paths + 1] = path
      end
    end
  end

  if #unique_paths == 0 then
    app.ui.status = t("status.no_srt_selected")
    return false
  end

  if #unique_paths == 1 then
    return load_srt_from_path(unique_paths[1])
  end

  local added_count = 0
  local existing_count = 0
  local failed_count = 0
  local first_metadata_path = nil
  local first_error = nil

  for _, path in ipairs(unique_paths) do
    local ok, result, created = ensure_srt_in_library(path)
    if ok then
      append_source_to_order(result)
      if not first_metadata_path then
        first_metadata_path = result
      end
      if created then
        added_count = added_count + 1
      else
        existing_count = existing_count + 1
      end
    else
      failed_count = failed_count + 1
      first_error = first_error or result
    end
  end

  invalidate_source_library_cache()
  refresh_source_library_cache()

  if first_metadata_path then
    set_single_source_selection(first_metadata_path)
  end

  local status_parts = {}
  status_parts[#status_parts + 1] = t("status.added_srts_to_source_library", added_count)
  if existing_count > 0 then
    status_parts[#status_parts + 1] = t("status.srts_already_existed_count", existing_count)
  end
  if failed_count > 0 then
    status_parts[#status_parts + 1] = t("status.srts_failed_count", failed_count)
  end
  if first_error then
    status_parts[#status_parts + 1] = first_error
  end

  app.ui.status = table.concat(status_parts, " / ")
  return failed_count < #unique_paths
end

function build_pane_module_env()
  return {
    app = app,
    ctx = ctx,
    reaper = reaper,
    t = t,
    get_font_small = get_current_font_small,
    get_font_small_size = get_current_font_small_size,
    now_sec = now_sec,
    trim = trim,
    is_srt_file_path = is_srt_file_path,
    compare_text_case_insensitive = compare_text_case_insensitive,
    get_library_folder_display_path = get_library_folder_display_path,
    get_library_folder_lookup = get_library_folder_lookup,
    mark_settings_dirty = mark_settings_dirty,
    prompt_create_library_folder = prompt_create_library_folder,
    prompt_rename_library_folder = prompt_rename_library_folder,
    move_library_folder = move_library_folder,
    is_descendant_folder_id = is_descendant_folder_id,
    delete_library_folder = delete_library_folder,
    get_selected_source_count = get_selected_source_count,
    set_single_source_selection = set_single_source_selection,
    is_source_selected = is_source_selected,
    load_source_entry = load_source_entry,
    add_srt_paths_to_library = add_srt_paths_to_library,
    refresh_source_library_cache = refresh_source_library_cache,
    prompt_add_srt = prompt_add_srt,
    SourcePane = SourcePane,
    LibraryPane = LibraryPane,
    LibraryStore = LibraryStore,
  }
end

require("reasrt.source_pane")(build_pane_module_env())
require("reasrt.library_pane")(build_pane_module_env())

--========================================================
-- UI helpers
--========================================================

function draw_library_search_section()
  local header_open = false
  if reaper.ImGui_CollapsingHeader then
    header_open = reaper.ImGui_CollapsingHeader(ctx, t("pane.library_search"))
  else
    header_open = true
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, t("pane.library_search"))
  end

  app.ui.library_search_open = header_open

  if not header_open then
    return
  end

  reaper.ImGui_SetNextItemWidth(ctx, -120)
  local changed, new_query = reaper.ImGui_InputTextWithHint(
    ctx,
    "##library_query",
    t("hint.library_query"),
    app.library.query
  )
  if changed then
    app.library.query = new_query
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, t("button.search_library")) then
    search_library(app.library.query)
  end

  reaper.ImGui_TextWrapped(ctx, app.library.status)

  if #app.library.results == 0 then
    return
  end

  local child_height = 160
  local child_visible = reaper.ImGui_BeginChild(
    ctx,
    "library_results",
    0,
    child_height,
    reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0,
    reaper.ImGui_WindowFlags_None and reaper.ImGui_WindowFlags_None() or 0
  )
  if child_visible then
    for _, result in ipairs(app.library.results) do
      local preview_text = tostring(result.display_text or result.text or ""):gsub("[\r\n]+", " ")
      local label = ("%s | %s | %s"):format(
        tostring(result.source_name or "(unknown)"),
        tostring(result.srt_index or "?"),
        preview_text
      )
      if reaper.ImGui_Selectable(ctx, label, false) then
        load_library_result(result)
      end
      if reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
        local tooltip_parts = {
          t("label.source_path", tostring(result.source_path or "")),
          t("label.time_range", tostring(result.display_start or ""), tostring(result.display_end or "")),
        }
        if result.tags_text and result.tags_text ~= "" then
          tooltip_parts[#tooltip_parts + 1] = t("label.tags_tooltip", result.tags_text)
        end
        if result.note and result.note ~= "" then
          tooltip_parts[#tooltip_parts + 1] = t("label.note_tooltip", result.note)
        end
        reaper.ImGui_SetTooltip(ctx, table.concat(tooltip_parts, "\n"))
      end
    end
    reaper.ImGui_EndChild(ctx)
  end
end

function draw_source_summary()
  local srt_summary = t("label.none")
  local audio_summary = t("label.none")

  if app.ui.content_mode == "library" then
    local item = get_last_selected_item()
    if item then
      srt_summary = tostring(item.source_name or t("label.none"))
      if item.source_audio_missing and item.source_audio_name and item.source_audio_name ~= "" then
        audio_summary = t("label.audio_missing_file", tostring(item.source_audio_name))
      elseif item.source_audio_name and item.source_audio_name ~= "" then
        audio_summary = tostring(item.source_audio_name)
      end
    end
  else
    srt_summary = app.source.srt_loaded and tostring(app.source.srt_name or "") or t("label.none")
    audio_summary = SourcePane.get_current_audio_path_summary()
  end

  reaper.ImGui_TextWrapped(ctx, t("label.srt") .. ": " .. srt_summary)
  if app.ui.content_mode ~= "library" then
    if reaper.ImGui_Button(ctx, t("button.open_audio")) then
      trigger_ui_action("open_audio")
    end
    reaper.ImGui_SameLine(ctx)
  end
  reaper.ImGui_TextWrapped(ctx, t("label.audio") .. ": " .. audio_summary)
end

function get_current_item_sort_mode()
  return app.ui.content_mode == "library" and "library" or "source"
end

function get_item_sort_state()
  local mode_name = get_current_item_sort_mode()
  app.ui.item_sort = app.ui.item_sort or {}
  app.ui.item_sort[mode_name] = app.ui.item_sort[mode_name]
    or {
      column_key = mode_name == "library" and "item.column.srt" or "item.column.index",
      descending = false,
    }
  return app.ui.item_sort[mode_name], mode_name
end

function toggle_item_sort(column_key)
  local sort_state = get_item_sort_state()
  if sort_state.column_key == column_key then
    sort_state.descending = not sort_state.descending
  else
    sort_state.column_key = column_key
    sort_state.descending = false
  end
  invalidate_filter_cache()
end

function get_item_sort_value(item, column_key)
  if column_key == "item.column.srt" then
    return tostring(item.source_name or "")
  end
  if column_key == "item.column.index" then
    return tonumber(item.srt_index) or 0
  end
  if column_key == "item.column.text" then
    return tostring(item.display_text or item.text or "")
  end
  if column_key == "item.column.start" then
    local start_ms = get_effective_item_bounds_ms(item)
    return tonumber(start_ms) or 0
  end
  if column_key == "item.column.end" then
    local _, end_ms = get_effective_item_bounds_ms(item)
    return tonumber(end_ms) or 0
  end
  if column_key == "item.column.favorite_short" then
    return item.favorite and 1 or 0
  end
  if column_key == "item.column.tags" then
    return tostring(item.tags_text or "")
  end
  return tostring(item.row_label or "")
end

function compare_item_sort_values(a_value, b_value, descending)
  local a_type = type(a_value)
  local b_type = type(b_value)
  local comparison = 0

  if a_type == "number" and b_type == "number" then
    if a_value < b_value then
      comparison = -1
    elseif a_value > b_value then
      comparison = 1
    end
  else
    local a_text = normalize_search_text(tostring(a_value or ""))
    local b_text = normalize_search_text(tostring(b_value or ""))
    if a_text < b_text then
      comparison = -1
    elseif a_text > b_text then
      comparison = 1
    end
  end

  if descending then
    comparison = -comparison
  end

  return comparison
end

function handle_global_shortcuts()
  if app.ui.content_mode ~= "library" and not app.source.srt_loaded then
    return
  end

  -- テキスト入力中はショートカットを無効化
  if reaper.ImGui_IsAnyItemActive and reaper.ImGui_IsAnyItemActive(ctx) then
    return
  end

  local filtered_indices = app.cache.filtered_indices
  if #filtered_indices == 0 then
    return
  end

  -- 上キー: 1つ上へ
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_UpArrow then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow(), false) then
      local pos = get_selected_filtered_pos()
      if not pos then
        select_filtered_pos(1)
      elseif pos > 1 then
        select_filtered_pos(pos - 1)
      end

      local item = find_item_by_key(app.ui.last_selected_item_key)
      if item then
        app.ui.status = t("status.selected_item_index", tostring(item.srt_index))
      end
    end
  end

  -- 下キー: 1つ下へ
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_DownArrow then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow(), false) then
      local pos = get_selected_filtered_pos()
      if not pos then
        select_filtered_pos(1)
      elseif pos < #filtered_indices then
        select_filtered_pos(pos + 1)
      end

      local item = find_item_by_key(app.ui.last_selected_item_key)
      if item then
        app.ui.status = t("status.selected_item_index", tostring(item.srt_index))
      end
    end
  end

  -- スペースキー: preview のトグル
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Space then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space(), false) then
      if app.preview.is_playing then
        stop_preview()
        app.ui.status = t("status.preview_stopped")
      else
        start_preview_selected()
      end
    end
  end
  
  -- Enter / KeypadEnter: insert selected subtitle item at cursor
  local enter_pressed = false
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Enter then
    enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) or enter_pressed
  end
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_KeypadEnter then
    enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false) or enter_pressed
  end

  if enter_pressed then
    insert_selected_items_at_cursor()
  end
end

--========================================================
-- UI
--========================================================

trigger_ui_action = function(action_id)
  if action_id == "add_srt" then
    prompt_add_srt()
  elseif action_id == "new_folder" then
    prompt_create_library_folder()
  elseif action_id == "new_library" then
    LibraryPane.prompt_create_library()
  elseif action_id == "open_audio" then
    prompt_open_audio()
  elseif action_id == "reload_library" then
    LibraryPane.reload_active_view({
      reset_filters = false,
      selected_item_key = app.ui.last_selected_item_key,
    })
  elseif action_id == "save_metadata" then
    SourcePane.save_metadata_now_and_clear_dirty()
  elseif action_id == "clear_srt" then
    SourcePane.clear_selected_sources_from_library()
  elseif action_id == "insert_selected_items" then
    insert_selected_items_at_cursor()
  elseif action_id == "preview_selected_items" then
    start_preview_selected()
  elseif action_id == "favorite_selected_item" then
    update_selected_favorite(true)
  elseif action_id == "edit_selected_tags" then
    prompt_edit_selected_tags()
  elseif action_id == "add_speaker_tags" then
    apply_speaker_tags_to_items()
  elseif action_id == "apply_offset" then
    set_global_offset_ms(app.ui.offset_input)
  elseif action_id == "reset_offset" then
    set_global_offset_ms(0)
  elseif action_id == "toggle_hide_speaker_labels" then
    set_hide_speaker_labels_enabled(not app.settings.hide_speaker_labels)
  elseif action_id == "toggle_edit_panel" then
    app.ui.show_detail_pane = app.ui.show_detail_pane == false
    app.settings.show_detail_pane = app.ui.show_detail_pane
    mark_settings_dirty()
    app.ui.status = app.ui.show_detail_pane
      and t("status.edit_panel_shown")
      or t("status.edit_panel_hidden")
  elseif action_id == "set_preview_volume" then
    prompt_set_preview_volume()
  elseif action_id == "set_font_size" then
    prompt_set_font_size()
  elseif action_id == "set_font_path" then
    prompt_set_font_path()
  elseif action_id == "set_language_en" then
    set_app_language("en")
    mark_settings_dirty()
    app.ui.status = t("status.language_changed", t("menu.language_en"))
  elseif action_id == "set_language_ja" then
    set_app_language("ja")
    mark_settings_dirty()
    app.ui.status = t("status.language_changed", t("menu.language_ja"))
  end
end

function draw_menu_entries(entries)
  local previous_separator = true

  for _, entry in ipairs(entries or {}) do
    if is_ui_entry_visible(entry) then
      if entry.type == "separator" then
        if not previous_separator and reaper.ImGui_Separator then
          reaper.ImGui_Separator(ctx)
          previous_separator = true
        end
      elseif entry.items then
        if reaper.ImGui_BeginMenu and reaper.ImGui_EndMenu and reaper.ImGui_BeginMenu(ctx, t(entry.label)) then
          draw_menu_entries(entry.items)
          reaper.ImGui_EndMenu(ctx)
        end
        previous_separator = false
      else
        if reaper.ImGui_MenuItem(ctx, t(entry.label)) then
          trigger_ui_action(entry.action)
        end
        previous_separator = false
      end
    end
  end
end

function draw_top_bar_actions()
  local first_item = true

  for _, entry in ipairs(UI_CONFIG.top_bar_actions or {}) do
    if is_ui_entry_visible(entry) then
      if not first_item then
        reaper.ImGui_SameLine(ctx)
      end

      if reaper.ImGui_Button(ctx, t(entry.label)) then
        trigger_ui_action(entry.action)
      end

      first_item = false
    end
  end
end

function draw_toggle_button(label, enabled)
  local pushed_colors = 0
  local pushed_vars = 0

  if reaper.ImGui_PushStyleVar then
    if reaper.ImGui_StyleVar_FrameRounding then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
      pushed_vars = pushed_vars + 1
    end
    if reaper.ImGui_StyleVar_FrameBorderSize then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), enabled and 2.0 or 1.0)
      pushed_vars = pushed_vars + 1
    end
  end

  if reaper.ImGui_PushStyleColor then
    if reaper.ImGui_Col_Button then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), enabled and 0x25394DFF or 0x1D2732FF)
      pushed_colors = pushed_colors + 1
    end
    if reaper.ImGui_Col_ButtonHovered then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), enabled and 0x2E4761FF or 0x263444FF)
      pushed_colors = pushed_colors + 1
    end
    if reaper.ImGui_Col_ButtonActive then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), enabled and 0x1F3142FF or 0x18212BFF)
      pushed_colors = pushed_colors + 1
    end
    if reaper.ImGui_Col_Border then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), enabled and 0x7AA5CFFF or 0x53657AFF)
      pushed_colors = pushed_colors + 1
    end
  end

  local clicked = reaper.ImGui_Button(ctx, label)

  if pushed_colors > 0 and reaper.ImGui_PopStyleColor then
    reaper.ImGui_PopStyleColor(ctx, pushed_colors)
  end
  if pushed_vars > 0 and reaper.ImGui_PopStyleVar then
    reaper.ImGui_PopStyleVar(ctx, pushed_vars)
  end

  return clicked
end

function draw_menu_section(menu_definition)
  if not (reaper.ImGui_BeginMenu and reaper.ImGui_EndMenu and reaper.ImGui_MenuItem) then
    return
  end

  if not reaper.ImGui_BeginMenu(ctx, t(menu_definition.label)) then
    return
  end

  draw_menu_entries(menu_definition.items)
  reaper.ImGui_EndMenu(ctx)
end

function draw_top_bar()
  draw_top_bar_actions()

  reaper.ImGui_Separator(ctx)

  draw_source_summary()

  reaper.ImGui_Separator(ctx)

  if draw_toggle_button(t("toggle.favorites_only"), app.ui.filter_favorites_only) then
    app.ui.filter_favorites_only = not app.ui.filter_favorites_only
    invalidate_filter_cache()
    app.ui.status = t("status.filter_favorites_updated")
  end

  reaper.ImGui_SameLine(ctx)
  if draw_toggle_button(t("toggle.hide_speaker_labels"), app.settings.hide_speaker_labels == true) then
    set_hide_speaker_labels_enabled(not (app.settings.hide_speaker_labels == true))
  end

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 220)
  local tags_changed, new_filter_tags = reaper.ImGui_InputTextWithHint(
    ctx,
    "##filter_tags",
    t("hint.filter_tags"),
    app.ui.filter_tags
  )
  if tags_changed then
    app.ui.filter_tags = new_filter_tags
    invalidate_filter_cache()
    app.ui.status = t("status.filter_tags_updated")
  end

  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local changed, new_filter = reaper.ImGui_InputTextWithHint(
    ctx,
    "##filter",
    t("hint.search_items"),
    app.ui.filter_text
  )
  if changed then
    app.ui.filter_text = new_filter
    invalidate_filter_cache()
    app.ui.status = t("status.filter_updated")
  end

  reaper.ImGui_Separator(ctx)
end

function draw_menu_bar()
  if not (reaper.ImGui_BeginMenuBar and reaper.ImGui_EndMenuBar) then
    return
  end

  if not reaper.ImGui_BeginMenuBar(ctx) then
    return
  end

  for _, menu_definition in ipairs(UI_CONFIG.main_menu or {}) do
    draw_menu_section(menu_definition)
  end

  reaper.ImGui_EndMenuBar(ctx)
end

function begin_left_panel_tab(label, should_select)
  if not reaper.ImGui_BeginTabItem then
    return false
  end

  local flags = 0
  if should_select and reaper.ImGui_TabItemFlags_SetSelected then
    flags = flags | reaper.ImGui_TabItemFlags_SetSelected()
  end

  local ok, visible = pcall(reaper.ImGui_BeginTabItem, ctx, label, nil, flags)
  if ok then
    return visible
  end

  ok, visible = pcall(reaper.ImGui_BeginTabItem, ctx, label)
  if ok then
    return visible
  end

  return false
end

function handle_item_selection_interaction(item)
  if not item then
    return
  end

  local shift_down = false
  local ctrl_down = false

  if reaper.ImGui_IsKeyDown and reaper.ImGui_Mod_Shift then
    shift_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
  end
  if reaper.ImGui_IsKeyDown and reaper.ImGui_Mod_Ctrl then
    ctrl_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
  end

  if shift_down then
    local anchor_key = app.ui.selection_anchor_key or app.ui.last_selected_item_key or item.key
    select_range_between(anchor_key, item.key, false)
    app.ui.status = t("status.range_selected")
  elseif ctrl_down then
    toggle_selection(item.key)
    app.ui.status = t("status.selection_toggled")
  else
    set_single_selection(item.key)
    app.ui.status = t("status.selected_item_index", tostring(item.srt_index))
  end
end

function prepare_item_context_selection(item)
  if not item then
    return
  end

  if is_item_selected(item.key) then
    app.ui.last_selected_item_key = item.key
    app.ui.selection_anchor_key = item.key
    return
  end

  set_single_selection(item.key)
end

function draw_item_context_menu(item, popup_id)
  if not item then
    return
  end
  if not (reaper.ImGui_BeginPopupContextItem and reaper.ImGui_EndPopup and reaper.ImGui_MenuItem) then
    return
  end

  if reaper.ImGui_BeginPopupContextItem(ctx, popup_id) then
    prepare_item_context_selection(item)

    if reaper.ImGui_MenuItem(ctx, t("menu.insert_selected_items")) then
      insert_selected_items_at_cursor()
    end
    if reaper.ImGui_MenuItem(ctx, t("menu.preview_selected_items")) then
      start_preview_selected()
    end
    if reaper.ImGui_MenuItem(ctx, t("menu.favorite_selected_item")) then
      update_selected_favorite(true)
    end
    if reaper.ImGui_MenuItem(ctx, t("menu.edit_selected_tags")) then
      prompt_edit_selected_tags()
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

function draw_list_row_fallback(original_index)
  local item = app.data.items[original_index]
  if not item then
    return
  end

  local selected = is_item_selected(item.key)

  if reaper.ImGui_Selectable(ctx, item.row_label, selected) then
    handle_item_selection_interaction(item)
  end

  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    insert_selected_items_at_cursor()
  end

  draw_item_context_menu(item, "item_context_fallback##" .. tostring(item.key))
end

function get_item_table_flags()
  local flags = 0

  if reaper.ImGui_TableFlags_Borders then
    flags = flags | reaper.ImGui_TableFlags_Borders()
  end
  if reaper.ImGui_TableFlags_RowBg then
    flags = flags | reaper.ImGui_TableFlags_RowBg()
  end
  if reaper.ImGui_TableFlags_Resizable then
    flags = flags | reaper.ImGui_TableFlags_Resizable()
  end
  if reaper.ImGui_TableFlags_Reorderable then
    flags = flags | reaper.ImGui_TableFlags_Reorderable()
  end
  if reaper.ImGui_TableFlags_Hideable then
    flags = flags | reaper.ImGui_TableFlags_Hideable()
  end
  if reaper.ImGui_TableFlags_ScrollY then
    flags = flags | reaper.ImGui_TableFlags_ScrollY()
  end
  if reaper.ImGui_TableFlags_SizingStretchProp then
    flags = flags | reaper.ImGui_TableFlags_SizingStretchProp()
  end
  if reaper.ImGui_TableFlags_Sortable then
    flags = flags | reaper.ImGui_TableFlags_Sortable()
  end

  return flags
end

function setup_item_table_columns()
  if reaper.ImGui_TableSetupColumn then
    local stretch = reaper.ImGui_TableColumnFlags_WidthStretch and reaper.ImGui_TableColumnFlags_WidthStretch() or 0
    local fixed = reaper.ImGui_TableColumnFlags_WidthFixed and reaper.ImGui_TableColumnFlags_WidthFixed() or 0
    local no_hide = reaper.ImGui_TableColumnFlags_NoHide and reaper.ImGui_TableColumnFlags_NoHide() or 0
    local columns = get_item_table_columns_for_mode()
    local mode_name = app.ui.content_mode == "library" and "library" or "source"
    local saved_widths = app.settings.item_table_column_widths and app.settings.item_table_column_widths[mode_name] or nil

    for _, column in ipairs(columns) do
      local flags = column.width_mode == "stretch" and stretch or fixed
      if column.no_hide then
        flags = flags | no_hide
      end
      local width = tonumber(column.width) or 0.0
      if saved_widths and tonumber(saved_widths[column.key]) then
        width = tonumber(saved_widths[column.key]) or width
      end
      reaper.ImGui_TableSetupColumn(ctx, t(column.key), flags, width)
    end
  end

  if reaper.ImGui_TableSetupScrollFreeze then
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
  end

end

function draw_item_table_header()
  local columns = get_item_table_columns_for_mode()
  local header_height = math.max(font_size or 14, font_small_size or 12) + 8

  reaper.ImGui_TableNextRow(ctx)
  for column_index, column in ipairs(columns) do
    reaper.ImGui_TableSetColumnIndex(ctx, column_index - 1)
    local label = t(column.key)
    local use_small_font = (column.key == "item.column.start" or column.key == "item.column.end")
    local cell_x, cell_y = 0, 0
    if reaper.ImGui_GetCursorScreenPos then
      cell_x, cell_y = reaper.ImGui_GetCursorScreenPos(ctx)
    end

    local clicked = false
    local should_draw_label = true
    if reaper.ImGui_InvisibleButton and reaper.ImGui_SetCursorScreenPos and reaper.ImGui_GetCursorScreenPos then
      clicked = reaper.ImGui_InvisibleButton(ctx, "##sort_" .. column.key, -1, header_height)
      reaper.ImGui_SetCursorScreenPos(ctx, cell_x + 4, cell_y + 4)
    else
      if use_small_font and font_small and reaper.ImGui_PushFont then
        reaper.ImGui_PushFont(ctx, font_small, font_small_size)
      end
      reaper.ImGui_Text(ctx, label)
      if use_small_font and font_small and reaper.ImGui_PopFont then
        reaper.ImGui_PopFont(ctx)
      end
      if reaper.ImGui_IsItemHovered and reaper.ImGui_IsMouseClicked then
        clicked = reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0)
      end
      should_draw_label = false
    end

    if should_draw_label then
      if use_small_font and font_small and reaper.ImGui_PushFont then
        reaper.ImGui_PushFont(ctx, font_small, font_small_size)
      end
      if reaper.ImGui_Text then
        reaper.ImGui_Text(ctx, label)
      end
      if use_small_font and font_small and reaper.ImGui_PopFont then
        reaper.ImGui_PopFont(ctx)
      end
    end

    if clicked then
      toggle_item_sort(column.key)
    end
  end
end

function draw_item_table_row(original_index)
  local item = app.data.items[original_index]
  if not item then
    return
  end

  local selected = is_item_selected(item.key)
  local selectable_flags = 0
  if reaper.ImGui_SelectableFlags_SpanAllColumns then
    selectable_flags = selectable_flags | reaper.ImGui_SelectableFlags_SpanAllColumns()
  end
  if reaper.ImGui_SelectableFlags_AllowDoubleClick then
    selectable_flags = selectable_flags | reaper.ImGui_SelectableFlags_AllowDoubleClick()
  end

  reaper.ImGui_TableNextRow(ctx)

  if app.ui.content_mode == "library" then
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    reaper.ImGui_Text(ctx, tostring(item.source_name or ""))
  end

  reaper.ImGui_TableSetColumnIndex(ctx, app.ui.content_mode == "library" and 1 or 0)
  local index_label = tostring(item.srt_index or 0)
  if reaper.ImGui_Selectable(ctx, index_label .. "##" .. item.key, selected, selectable_flags) then
    handle_item_selection_interaction(item)
    if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      insert_selected_items_at_cursor()
    end
  end
  draw_item_context_menu(item, "item_context_table##" .. tostring(item.key))

  reaper.ImGui_TableSetColumnIndex(ctx, app.ui.content_mode == "library" and 2 or 1)
  reaper.ImGui_Text(ctx, tostring(item.text_single_line or item.display_text or item.text or ""))
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, make_tooltip_text(item.display_text or item.text or "", 1200))
  end

  reaper.ImGui_TableSetColumnIndex(ctx, app.ui.content_mode == "library" and 3 or 2)
  if font_small and reaper.ImGui_PushFont then
    reaper.ImGui_PushFont(ctx, font_small, font_small_size)
  end
  reaper.ImGui_Text(ctx, tostring(item.display_start or ""))
  if font_small and reaper.ImGui_PopFont then
    reaper.ImGui_PopFont(ctx)
  end

  reaper.ImGui_TableSetColumnIndex(ctx, app.ui.content_mode == "library" and 4 or 3)
  if font_small and reaper.ImGui_PushFont then
    reaper.ImGui_PushFont(ctx, font_small, font_small_size)
  end
  reaper.ImGui_Text(ctx, tostring(item.display_end or ""))
  if font_small and reaper.ImGui_PopFont then
    reaper.ImGui_PopFont(ctx)
  end

  reaper.ImGui_TableSetColumnIndex(ctx, app.ui.content_mode == "library" and 5 or 4)
  reaper.ImGui_Text(ctx, item.favorite and "★" or "")

  reaper.ImGui_TableSetColumnIndex(ctx, app.ui.content_mode == "library" and 6 or 5)
  reaper.ImGui_Text(ctx, tostring(item.tags_text or ""))
end

function draw_item_list_pane()
  rebuild_filtered_cache_if_needed()
  local filtered_indices = app.cache.filtered_indices

  reaper.ImGui_Text(ctx, t("pane.item_list"))
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, t("label.item_count", #filtered_indices))
  reaper.ImGui_Separator(ctx)

  if app.ui.content_mode ~= "library" and not app.source.srt_loaded then
    reaper.ImGui_TextWrapped(ctx, t("empty.no_srt_loaded"))
    reaper.ImGui_TextWrapped(ctx, t("empty.use_add_srt"))
    return
  end

  if app.ui.content_mode == "library" and not app.ui.active_library_id then
    reaper.ImGui_TextWrapped(ctx, t("empty.no_library_opened"))
    reaper.ImGui_TextWrapped(ctx, t("empty.open_library_left_pane"))
    return
  end

  if #app.data.items == 0 then
    if app.ui.content_mode == "library" then
      reaper.ImGui_TextWrapped(ctx, t("empty.library_has_no_items"))
    else
      reaper.ImGui_TextWrapped(ctx, t("empty.no_items_matched"))
    end
    return
  end

  if #filtered_indices == 0 then
    if app.ui.content_mode == "library" and #app.data.items == 0 then
      reaper.ImGui_TextWrapped(ctx, t("empty.library_has_no_items"))
    else
      reaper.ImGui_TextWrapped(ctx, t("empty.no_items_matched"))
    end
    return
  end

  if not reaper.ImGui_BeginTable then
    for _, original_index in ipairs(filtered_indices) do
      draw_list_row_fallback(original_index)
    end
    return
  end

  local outer_size_w = -1
  local outer_size_h = -1
  local table_flags = get_item_table_flags()

  local table_id = app.ui.content_mode == "library"
    and "item_list_table_library"
    or "item_list_table_source"

  if reaper.ImGui_BeginTable(ctx, table_id, app.ui.content_mode == "library" and 7 or 6, table_flags, outer_size_w, outer_size_h) then
    setup_item_table_columns()
    draw_item_table_header()
    local clipped = false
    if reaper.ImGui_ListClipper_Begin
      and reaper.ImGui_ListClipper_Step
      and reaper.ImGui_ListClipper_End
      and reaper.ImGui_ListClipper_GetDisplayRange then
      local ok = pcall(function()
        local clipper = app.ui.item_list_clipper
        if reaper.ImGui_ValidatePtr and clipper and not reaper.ImGui_ValidatePtr(clipper, "ImGui_ListClipper*") then
          clipper = nil
          app.ui.item_list_clipper = nil
        end
        if not clipper and reaper.ImGui_CreateListClipper then
          clipper = reaper.ImGui_CreateListClipper(ctx)
          app.ui.item_list_clipper = clipper
          if clipper and reaper.ImGui_Attach then
            reaper.ImGui_Attach(ctx, clipper)
          end
        end
        if not clipper then
          return
        end
        reaper.ImGui_ListClipper_Begin(clipper, #filtered_indices)
        while reaper.ImGui_ListClipper_Step(clipper) do
          local display_start, display_end = reaper.ImGui_ListClipper_GetDisplayRange(clipper)
          display_start = tonumber(display_start) or 0
          display_end = tonumber(display_end) or #filtered_indices
          for pos = display_start + 1, display_end do
            local original_index = filtered_indices[pos]
            if original_index then
              draw_item_table_row(original_index)
            end
          end
        end
        reaper.ImGui_ListClipper_End(clipper)
        clipped = true
      end)
      if not ok then
        clipped = false
      end
    end

    if not clipped then
      for _, original_index in ipairs(filtered_indices) do
        draw_item_table_row(original_index)
      end
    end

    if reaper.ImGui_TableGetColumnWidth then
      local mode_name = app.ui.content_mode == "library" and "library" or "source"
      local columns = get_item_table_columns_for_mode()
      app.settings.item_table_column_widths = app.settings.item_table_column_widths or { source = {}, library = {} }
      app.settings.item_table_column_widths[mode_name] = app.settings.item_table_column_widths[mode_name] or {}
      for column_index, column in ipairs(columns) do
        local width = tonumber(reaper.ImGui_TableGetColumnWidth(ctx, column_index - 1))
        if width and width > 0 then
          local previous = tonumber(app.settings.item_table_column_widths[mode_name][column.key]) or 0
          if math.abs(previous - width) >= 0.5 then
            app.settings.item_table_column_widths[mode_name][column.key] = width
            mark_settings_dirty()
          end
        end
      end
    end

    reaper.ImGui_EndTable(ctx)
  end
end

function draw_detail_pane()
  reaper.ImGui_Text(ctx, t("pane.detail"))
  reaper.ImGui_Separator(ctx)

  if app.ui.content_mode ~= "library" and not app.source.srt_loaded then
    reaper.ImGui_TextWrapped(ctx, t("empty.no_srt_loaded"))
    return
  end

  if app.ui.content_mode == "library" and not app.ui.active_library_id then
    reaper.ImGui_TextWrapped(ctx, t("empty.no_library_opened"))
    return
  end

  if app.ui.content_mode == "library" and app.ui.active_library_id and #app.data.items == 0 then
    reaper.ImGui_TextWrapped(ctx, t("empty.library_has_no_items"))
    return
  end

  if app.ui.content_mode ~= "library" then
    reaper.ImGui_Text(ctx, t("label.global_offset"))
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_TextDisabled then
      reaper.ImGui_TextDisabled(ctx, "(?)")
    else
      reaper.ImGui_Text(ctx, "(?)")
    end
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, t("hint.global_offset_help"))
    end
    reaper.ImGui_SetNextItemWidth(ctx, 140)
    local offset_changed, new_offset_input = reaper.ImGui_InputText(
      ctx,
      "##global_offset_input",
      tostring(app.ui.offset_input or "0")
    )
    if offset_changed then
      app.ui.offset_input = new_offset_input
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, t("button.apply")) then
      set_global_offset_ms(app.ui.offset_input)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, t("button.reset")) then
      set_global_offset_ms(0)
    end
    reaper.ImGui_Separator(ctx)
  end

  local item = get_last_selected_item()

  if not item then
    reaper.ImGui_TextWrapped(ctx, t("empty.no_item_selected"))
    return
  end

  local fav_changed, new_favorite = reaper.ImGui_Checkbox(ctx, t("label.favorite"), item.favorite == true)
  if fav_changed then
    update_selected_favorite(new_favorite)
    item = get_last_selected_item() or item
  end

  reaper.ImGui_Text(ctx, t("label.tags"))
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_TextDisabled then
    reaper.ImGui_TextDisabled(ctx, "(?)")
  else
    reaper.ImGui_Text(ctx, "(?)")
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, t("hint.tags_help"))
  end
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local tags_changed, new_tags = reaper.ImGui_InputText(
    ctx,
    "##tags_editor",
    tostring(item.tags_text or "")
  )
  if tags_changed then
    update_selected_tags_text(new_tags)
    item = get_last_selected_item() or item
  end
end

--========================================================
-- Main loop
--========================================================

function loop()
  initialize_settings_state()
  LibraryStore.initialize_state()
  restore_startup_view_if_needed()
  rebuild_filtered_cache_if_needed()
  flush_metadata_if_needed(false)
  flush_settings_if_needed(false)
  LibraryStore.flush_if_needed(false)
  update_preview_playback()
  refresh_source_library_cache()

  if font and reaper.ImGui_PushFont then
    reaper.ImGui_PushFont(ctx, font, font_size)
  end

  local window_flags = 0
  if reaper.ImGui_WindowFlags_NoCollapse then
    window_flags = window_flags | reaper.ImGui_WindowFlags_NoCollapse()
  end
  if reaper.ImGui_WindowFlags_MenuBar then
    window_flags = window_flags | reaper.ImGui_WindowFlags_MenuBar()
  end

  if reaper.ImGui_SetNextWindowSizeConstraints then
    local min_window_w = (UI_CONFIG.layout.min_source_width or 220)
      + (UI_CONFIG.layout.splitter_width or 6)
      + (UI_CONFIG.layout.min_main_width or 420)
    local min_window_h = 420
    if app.ui.show_detail_pane ~= false then
      min_window_h = (UI_CONFIG.layout.min_item_list_height or 180)
        + (UI_CONFIG.layout.min_detail_height or 160)
        + (UI_CONFIG.layout.splitter_width or 6)
        + 90
    end
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, min_window_w, min_window_h, 10000, 10000)
  end

  local visible, open = reaper.ImGui_Begin(
    ctx,
    WINDOW_TITLE,
    true,
    window_flags
  )

  if visible then
    draw_menu_bar()

    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local splitter_w = UI_CONFIG.layout.splitter_width or 6
    local min_source_w = UI_CONFIG.layout.min_source_width or 220
    local min_main_w = UI_CONFIG.layout.min_main_width or 420
    local splitter_line_color = UI_CONFIG.colors and UI_CONFIG.colors.splitter_line or 0x66FFFFFF
    local splitter_line_active_color = UI_CONFIG.colors and UI_CONFIG.colors.splitter_line_active or splitter_line_color
    local max_source_w = math.max(min_source_w, avail_w - min_main_w - splitter_w)
    local source_w = clamp(app.ui.left_pane_width or math.floor(avail_w * 0.5), min_source_w, max_source_w)
    app.ui.left_pane_width = source_w

    local source_visible = reaper.ImGui_BeginChild(
      ctx,
      "source_pane",
      source_w,
      0,
      reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0,
      reaper.ImGui_WindowFlags_None and reaper.ImGui_WindowFlags_None() or 0
    )
    if source_visible then
      local tab_drawn = false
      if reaper.ImGui_BeginTabBar and reaper.ImGui_EndTabBar and reaper.ImGui_BeginTabItem and reaper.ImGui_EndTabItem then
        if reaper.ImGui_BeginTabBar(ctx, "left_panel_tabs") then
          local active_left_panel_tab = nil
          for _, tab_name in ipairs({ "sources", "libraries" }) do
            local label = tab_name == "libraries" and t(UI_CONFIG.tabs.libraries) or t(UI_CONFIG.tabs.sources)
            local tab_open = begin_left_panel_tab(label, app.ui.pending_left_panel_tab == tab_name)
            if tab_open then
              active_left_panel_tab = tab_name
              if tab_name == "libraries" then
                LibraryPane.draw_list()
              else
                SourcePane.draw_list()
              end
              reaper.ImGui_EndTabItem(ctx)
            end
          end
          if active_left_panel_tab and app.ui.left_panel_tab ~= active_left_panel_tab then
            app.ui.left_panel_tab = active_left_panel_tab
            mark_settings_dirty()
          end
          if active_left_panel_tab and app.ui.pending_left_panel_tab == active_left_panel_tab then
            app.ui.pending_left_panel_tab = nil
          end

          reaper.ImGui_EndTabBar(ctx)
          tab_drawn = true
        end
      end

      if not tab_drawn then
        local showing_sources = app.ui.left_panel_tab ~= "libraries"
        if reaper.ImGui_Button(ctx, t("button.sources")) then
          set_left_panel_tab("sources")
          showing_sources = true
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, t("button.libraries")) then
          set_left_panel_tab("libraries")
          showing_sources = false
        end
        reaper.ImGui_Separator(ctx)

        if showing_sources then
          SourcePane.draw_list()
        else
          LibraryPane.draw_list()
        end
      end
    end
    reaper.ImGui_EndChild(ctx)

    reaper.ImGui_SameLine(ctx)

    local splitter_x, splitter_y = 0, 0
    if reaper.ImGui_GetCursorScreenPos then
      splitter_x, splitter_y = reaper.ImGui_GetCursorScreenPos(ctx)
    end

    if reaper.ImGui_InvisibleButton then
      reaper.ImGui_InvisibleButton(ctx, "source_splitter", splitter_w, -1)

      if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine then
        local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
        local line_x = splitter_x + math.floor(splitter_w / 2)
        local line_col = splitter_line_color
        if reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx) then
          line_col = splitter_line_active_color
        elseif reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) then
          line_col = splitter_line_active_color
        end
        reaper.ImGui_DrawList_AddLine(draw_list, line_x, splitter_y, line_x, splitter_y + math.max(avail_h, 200), line_col, 1.0)
      end

      if reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) then
        if reaper.ImGui_SetMouseCursor and reaper.ImGui_MouseCursor_ResizeEW then
          reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
        end
      end

      if reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_GetMouseDelta then
        local delta_x = reaper.ImGui_GetMouseDelta(ctx)
        if delta_x and delta_x ~= 0 then
          local new_width = clamp((app.ui.left_pane_width or source_w) + delta_x, min_source_w, max_source_w)
          if new_width ~= app.ui.left_pane_width then
            app.ui.left_pane_width = new_width
            app.settings.left_pane_width = new_width
            mark_settings_dirty()
          end
        end
      end
    end

    reaper.ImGui_SameLine(ctx)

    local main_visible = reaper.ImGui_BeginChild(
      ctx,
      "main_pane",
      0,
      0,
      reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0,
      reaper.ImGui_WindowFlags_None and reaper.ImGui_WindowFlags_None() or 0
    )
    if main_visible then
      draw_top_bar()
      handle_global_shortcuts()

      local main_avail_w, main_avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
      local show_detail_pane = app.ui.show_detail_pane ~= false

      local splitter_h = UI_CONFIG.layout.splitter_width or 6
      local min_list_h = UI_CONFIG.layout.min_item_list_height or 180
      local min_detail_h = UI_CONFIG.layout.min_detail_height or 160
      local configured_max_detail_h = tonumber(UI_CONFIG.layout.max_detail_height)
      local detail_h = 0
      local list_h = main_avail_h
      local max_detail_h = math.max(min_detail_h, main_avail_h - min_list_h - splitter_h)
      if configured_max_detail_h and configured_max_detail_h > 0 then
        max_detail_h = math.max(min_detail_h, math.min(max_detail_h, configured_max_detail_h))
      end
      if show_detail_pane then
        detail_h = clamp(app.ui.detail_pane_height or UI_CONFIG.layout.detail_pane_height or 260, min_detail_h, max_detail_h)
        app.ui.detail_pane_height = detail_h
        list_h = math.max(min_list_h, main_avail_h - detail_h - splitter_h)
      end

      local top_visible = reaper.ImGui_BeginChild(
        ctx,
        "top_pane",
        0,
        list_h,
        reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0,
        reaper.ImGui_WindowFlags_None and reaper.ImGui_WindowFlags_None() or 0
      )
      if top_visible then
        draw_item_list_pane()
      end
      reaper.ImGui_EndChild(ctx)

      if show_detail_pane then
        if reaper.ImGui_InvisibleButton then
          local cursor_x, cursor_y = 0, 0
          if reaper.ImGui_GetCursorScreenPos then
            cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
          end
          if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine then
            local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
            local line_y = cursor_y + math.floor(splitter_h / 2)
            local line_col = splitter_line_color
            local avail_split_w = main_avail_w > 0 and main_avail_w or 200
            reaper.ImGui_DrawList_AddLine(draw_list, cursor_x, line_y, cursor_x + avail_split_w, line_y, line_col, 1.0)
          end

          reaper.ImGui_InvisibleButton(ctx, "detail_splitter", -1, splitter_h)

          if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine then
            local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
            local line_y = cursor_y + math.floor(splitter_h / 2)
            local line_col = splitter_line_color
            if reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx) then
              line_col = splitter_line_active_color
            elseif reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) then
              line_col = splitter_line_active_color
            end
            local avail_split_w = main_avail_w > 0 and main_avail_w or 200
            reaper.ImGui_DrawList_AddLine(draw_list, cursor_x, line_y, cursor_x + avail_split_w, line_y, line_col, 1.0)
          end

          if reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) then
            app.ui.status = t("status.splitter_detail_resize")
            if reaper.ImGui_SetMouseCursor and reaper.ImGui_MouseCursor_ResizeNS then
              reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
            end
          end

          if reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_GetMouseDelta then
            local _, delta_y = reaper.ImGui_GetMouseDelta(ctx)
            if delta_y and delta_y ~= 0 then
              local new_height = clamp((app.ui.detail_pane_height or detail_h) - delta_y, min_detail_h, max_detail_h)
              if new_height ~= app.ui.detail_pane_height then
                app.ui.detail_pane_height = new_height
                app.settings.detail_pane_height = new_height
                mark_settings_dirty()
              end
            end
          end
        end

        local bottom_visible = reaper.ImGui_BeginChild(
          ctx,
          "bottom_pane",
          0,
          0,
          reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0,
          reaper.ImGui_WindowFlags_None and reaper.ImGui_WindowFlags_None() or 0
        )
        if bottom_visible then
          draw_detail_pane()
        end
        reaper.ImGui_EndChild(ctx)
      end
    end
    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_End(ctx)

  if font and reaper.ImGui_PopFont then
    reaper.ImGui_PopFont(ctx)
  end

  if open then
    reaper.defer(loop)
  else
    stop_preview(true)
    flush_metadata_if_needed(true)
    flush_settings_if_needed(true)
    LibraryStore.flush_if_needed(true)
  end
end

loop()
