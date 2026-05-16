return function(env)
  local app = env.app
  local reaper = env.reaper
  local t = env.t
  local parse_tags_text = env.parse_tags_text
  local join_tags = env.join_tags
  local make_item_lookup_key = env.make_item_lookup_key
  local copy_audio_file_entries = env.copy_audio_file_entries
  local get_selected_audio_entry = env.get_selected_audio_entry
  local find_audio_entry_index = env.find_audio_entry_index
  local is_supported_audio_file_path = env.is_supported_audio_file_path
  local file_exists = env.file_exists
  local get_media_length_sec = env.get_media_length_sec
  local get_filename = env.get_filename
  local json_decode = env.json_decode
  local json_encode = env.json_encode
  local parse_integer = env.parse_integer
  local sync_offset_input_from_state = env.sync_offset_input_from_state
  local write_text_file_utf8 = env.write_text_file_utf8
  local read_text_file_utf8 = env.read_text_file_utf8
  local build_metadata_path_for_srt = env.build_metadata_path_for_srt
  local get_global_offset_ms = env.get_global_offset_ms
  local parse_srt_content = env.parse_srt_content
  local prepare_all_runtime_fields = env.prepare_all_runtime_fields
  local invalidate_items = env.invalidate_items
  local clear_selection = env.clear_selection
  local set_single_selection = env.set_single_selection
  local clear_source_selection = env.clear_source_selection
  local invalidate_filter_cache = env.invalidate_filter_cache
  local invalidate_source_library_cache = env.invalidate_source_library_cache
  local now_sec = env.now_sec
  local remember_recent_source = env.remember_recent_source
  local set_last_opened_srt_path = env.set_last_opened_srt_path
  local remember_browse_file_path = env.remember_browse_file_path
  local append_source_to_order = env.append_source_to_order
  local mark_settings_dirty = env.mark_settings_dirty or function()
  end
  local set_left_panel_tab = env.set_left_panel_tab or function(tab_name)
    app.ui.left_panel_tab = tab_name
  end
  local normalize_search_text = env.normalize_search_text
  local compare_text_case_insensitive = env.compare_text_case_insensitive
  local join_path = env.join_path
  local get_parent_dir = env.get_parent_dir
  local get_file_stem = env.get_file_stem
  local set_single_source_selection = env.set_single_source_selection
  local stop_preview = env.stop_preview

  local function sync_current_audio_offset_to_entry()
    local entry = get_selected_audio_entry(app.source.audio_files, app.source.selected_audio_path)
    if entry then
      entry.offset_ms = get_global_offset_ms()
    end
  end

  local function build_metadata_payload()
    sync_current_audio_offset_to_entry()
    local items = {}

    for _, item in ipairs(app.data.items) do
      items[#items + 1] = {
        key = {
          srt_index = item.srt_index,
          start_ms = item.start_ms,
          end_ms = item.end_ms,
          text = item.text,
        },
        tags = item.tags or parse_tags_text(item.tags_text),
        note = item.note or "",
        favorite = item.favorite == true,
      }
    end

    local audio_files = copy_audio_file_entries(app.source.audio_files)

    if #audio_files == 0 and app.source.audio_path then
      audio_files[#audio_files + 1] = {
        path = app.source.audio_path,
        label = "primary",
        is_primary = true,
        offset_ms = get_global_offset_ms(),
        length_sec = app.source.audio_length_sec,
      }
    end

    return {
      version = 1,
      source = {
        srt_path = app.source.srt_path or "",
        srt_filename = app.source.srt_name or "",
      },
      audio_files = audio_files,
      global_offset_ms = get_global_offset_ms(),
      selected_audio_path = app.source.selected_audio_path or "",
      items = items,
    }
  end

  local function apply_metadata_to_items(metadata)
    local lookup = {}

    if metadata and metadata.items then
      for _, meta_item in ipairs(metadata.items) do
        if meta_item and meta_item.key then
          local key = make_item_lookup_key(
            meta_item.key.srt_index,
            meta_item.key.start_ms,
            meta_item.key.end_ms,
            meta_item.key.text
          )
          lookup[key] = meta_item
        end
      end
    end

    for _, item in ipairs(app.data.items) do
      local key = make_item_lookup_key(item.srt_index, item.start_ms, item.end_ms, item.text)
      local meta_item = lookup[key]

      if meta_item then
        item.note = tostring(meta_item.note or "")
        item.favorite = meta_item.favorite == true
        if type(meta_item.tags) == "table" then
          item.tags = meta_item.tags
          item.tags_text = join_tags(meta_item.tags)
        else
          item.tags_text = tostring(meta_item.tags_text or item.tags_text or "")
          item.tags = parse_tags_text(item.tags_text)
        end
      else
        item.note = tostring(item.note or "")
        item.favorite = item.favorite == true
        item.tags = parse_tags_text(item.tags_text)
        item.tags_text = join_tags(item.tags)
      end
    end
  end

  local function reset_audio_runtime_state()
    app.source.audio_path = nil
    app.source.audio_name = nil
    app.source.audio_loaded = false
    app.source.audio_length_sec = nil
    app.source.selected_audio_path = nil
    app.source.audio_missing = false
    app.source.audio_missing_path = nil
  end

  local function set_audio_binding_entries(entries)
    app.source.audio_files = copy_audio_file_entries(entries)
  end

  local function select_audio_entry(entry)
    reset_audio_runtime_state()

    if not entry then
      app.data.global_offset_ms = 0
      sync_offset_input_from_state()
      return true, t("status.metadata_loaded")
    end

    local audio_path = tostring(entry.path or "")
    app.source.selected_audio_path = audio_path
    app.data.global_offset_ms = parse_integer(entry.offset_ms, 0) or 0
    sync_offset_input_from_state()

    if audio_path == "" then
      return true, t("status.metadata_loaded")
    end

    if not file_exists(audio_path) then
      app.source.audio_missing = true
      app.source.audio_missing_path = audio_path
      return true, t("status.metadata_loaded_missing_audio")
    end

    local audio_length_sec = tonumber(entry.length_sec) or get_media_length_sec(audio_path)
    if not audio_length_sec then
      app.source.audio_missing = true
      app.source.audio_missing_path = audio_path
      return true, t("status.failed_get_audio_length")
    end
    app.source.audio_path = audio_path
    app.source.audio_name = get_filename(audio_path)
    app.source.audio_loaded = true
    app.source.audio_length_sec = audio_length_sec
    entry.length_sec = audio_length_sec
    return true, t("status.metadata_loaded_audio_restored")
  end

  local function apply_audio_binding_from_metadata(metadata)
    local audio_files = copy_audio_file_entries(metadata and metadata.audio_files or {})
    local fallback_offset_ms = parse_integer(metadata and metadata.global_offset_ms, 0) or 0
    for index, entry in ipairs(audio_files) do
      if entry.offset_ms == nil then
        entry.offset_ms = index == 1 and fallback_offset_ms or 0
      end
    end
    set_audio_binding_entries(audio_files)
    local selected_entry = get_selected_audio_entry(audio_files, metadata and metadata.selected_audio_path)
    return select_audio_entry(selected_entry)
  end

  local function load_metadata_json(metadata_path)
    if not metadata_path or metadata_path == "" then
      return false, t("error.metadata_path_empty")
    end

    local content, err = read_text_file_utf8(metadata_path)
    if not content then
      if err and err:find("Failed to open file", 1, true) then
        return false, t("error.metadata_file_missing")
      end
      return false, err or t("error.failed_read_metadata_file")
    end

    if content == "" then
      return false, t("error.metadata_file_empty")
    end

    local ok, decoded = pcall(json_decode, content)
    if not ok then
      return false, t("error.failed_parse_metadata_json", tostring(decoded))
    end

    app.data.global_offset_ms = parse_integer(decoded.global_offset_ms, 0) or 0
    sync_offset_input_from_state()
    apply_metadata_to_items(decoded)
    local _, audio_message = apply_audio_binding_from_metadata(decoded)
    app.source.metadata_loaded = true
    return true, audio_message or t("status.metadata_loaded")
  end

  local function clear_audio_binding()
    reset_audio_runtime_state()
    app.source.audio_files = {}
  end

  local function enumerate_files_in_directory(dir_path)
    local files = {}
    dir_path = tostring(dir_path or "")
    if dir_path == "" or not (reaper and reaper.EnumerateFiles) then
      return files
    end

    local index = 0
    while true do
      local name = reaper.EnumerateFiles(dir_path, index)
      if not name or name == "" then
        break
      end
      files[#files + 1] = name
      index = index + 1
    end

    return files
  end

  local function find_auto_audio_paths_for_srt(srt_path)
    local dir_path = get_parent_dir(srt_path)
    local srt_stem = normalize_search_text(get_file_stem(srt_path))
    if dir_path == "" or srt_stem == "" then
      return {}
    end

    local exact = {}
    local partial = {}
    for _, name in ipairs(enumerate_files_in_directory(dir_path)) do
      local normalized_name = normalize_search_text(name)
      if is_supported_audio_file_path(name) then
        local stem = normalize_search_text(get_file_stem(name))
        if stem == srt_stem then
          exact[#exact + 1] = name
        elseif stem:find(srt_stem, 1, true) then
          partial[#partial + 1] = name
        end
      end
    end

    local function sort_candidates(candidates)
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
    end

    sort_candidates(exact)
    sort_candidates(partial)

    local candidates = {}
    for _, name in ipairs(exact) do
      candidates[#candidates + 1] = name
    end
    for _, name in ipairs(partial) do
      candidates[#candidates + 1] = name
    end
    if #candidates == 0 then
      return {}
    end

    local paths = {}
    for _, name in ipairs(candidates) do
      paths[#paths + 1] = join_path(dir_path, name)
    end

    return paths
  end

  local function should_try_auto_bind_audio()
    if #(app.source.audio_files or {}) > 0 then
      return false
    end

    return app.source.srt_loaded == true
  end

  local function reset_filtered_view_state()
    app.cache.filtered_indices = {}
    app.cache.filter_revision = -1
    app.cache.items_revision = -1
    app.ui.item_list_clipper = nil
  end

  env.clear_loaded_items = function()
    app.source.srt_path = nil
    app.source.srt_name = nil
    app.source.srt_loaded = false
    app.source.metadata_path = nil
    app.source.metadata_loaded = false

    clear_audio_binding()

    app.data.items = {}
    app.data.global_offset_ms = 0
    app.data.metadata_dirty = false
    app.data.metadata_dirty_at = nil
    invalidate_items()

    sync_offset_input_from_state()
    app.ui.selected_item_keys = {}
    app.ui.last_selected_item_key = nil
    app.ui.selection_anchor_key = nil

    app.ui.filter_text = ""
    invalidate_filter_cache()
    clear_source_selection()
    reset_filtered_view_state()
  end

  env.mark_metadata_dirty = function()
    if not app.source.srt_loaded then
      return
    end
    app.data.metadata_dirty = true
    app.data.metadata_dirty_at = now_sec()
  end

  env.save_metadata_json = function()
    if not app.source.srt_loaded then
      return false, t("status.no_srt_loaded")
    end

    local metadata_path = app.source.metadata_path
    if not metadata_path or metadata_path == "" then
      local resolved_path, path_err = build_metadata_path_for_srt(app.source.srt_path)
      if not resolved_path then
        app.ui.status = path_err or t("status.failed_resolve_metadata_path")
        return false, app.ui.status
      end
      metadata_path = resolved_path
      app.source.metadata_path = resolved_path
    end

    local payload = build_metadata_payload()
    local encoded = json_encode(payload)
    local ok, err = write_text_file_utf8(metadata_path, encoded)

    if not ok then
      app.ui.status = err or t("status.failed_save_metadata")
      return false, app.ui.status
    end

    app.source.metadata_loaded = true
    invalidate_source_library_cache()
    app.ui.status = t("status.metadata_saved")
    return true, metadata_path
  end

  env.flush_metadata_now = function()
    if not app.data.metadata_dirty then
      return true
    end

    local ok = env.save_metadata_json()
    if ok then
      app.data.metadata_dirty = false
      app.data.metadata_dirty_at = nil
      app.data.last_save_at = now_sec()
      return true
    end

    return false
  end

  env.load_srt_from_path = function(path, options)
    options = options or {}

    if not path or path == "" then
      return false, t("status.no_file_selected")
    end

    local previous_path = app.source.srt_path
    local is_switching_source = app.source.srt_loaded and previous_path and previous_path ~= path

    if is_switching_source and not env.flush_metadata_now() then
      app.ui.status = t("status.failed_save_metadata_before_switch_srt")
      return false, app.ui.status
    end

    if is_switching_source and app.preview.is_playing then
      stop_preview()
    end

    local content, err = read_text_file_utf8(path)
    if not content then
      env.clear_loaded_items()
      app.ui.status = err or t("status.failed_read_srt")
      return false, app.ui.status
    end

    local items = parse_srt_content(content)
    if #items == 0 then
      env.clear_loaded_items()
      app.ui.status = t("status.no_subtitle_items_in_srt")
      return false, app.ui.status
    end

    app.data.items = items

    app.source.srt_path = path
    app.source.srt_name = get_filename(path)
    app.source.srt_loaded = true
    set_audio_binding_entries({})
    reset_audio_runtime_state()
    app.data.global_offset_ms = 0
    sync_offset_input_from_state()

    local metadata_path, metadata_err = build_metadata_path_for_srt(path)
    app.source.metadata_path = metadata_path
    app.source.metadata_loaded = false

    local metadata_message = nil
    local metadata_missing = false
    local metadata_missing_message = t("error.metadata_file_missing")
    if metadata_path then
      local loaded, new_metadata_message = load_metadata_json(metadata_path)
      metadata_message = new_metadata_message
      if not loaded and metadata_message == metadata_missing_message then
        metadata_missing = true
      elseif not loaded and metadata_message ~= metadata_missing_message then
        app.ui.status = metadata_message
      end
    else
      app.ui.status = metadata_err or t("status.failed_resolve_metadata_path")
    end

    prepare_all_runtime_fields()
    invalidate_items()
    reset_filtered_view_state()

    clear_selection()
    if app.data.items[1] then
      set_single_selection(app.data.items[1].key)
    end

    app.ui.content_mode = "source"
    set_left_panel_tab("sources")
    if app.ui.active_library_id ~= nil then
      app.ui.active_library_id = nil
    end
    mark_settings_dirty()

    if options.reset_filters or is_switching_source then
      app.ui.filter_text = ""
      app.ui.filter_tags = ""
      app.ui.filter_favorites_only = false
      invalidate_filter_cache()
    end

    if metadata_missing and metadata_path then
      local created_ok = env.save_metadata_json()
      if created_ok then
        app.data.metadata_dirty = false
        app.data.metadata_dirty_at = nil
        app.data.last_save_at = now_sec()
        metadata_message = t("status.metadata_created")
      else
        metadata_message = app.ui.status
      end
    end

    if should_try_auto_bind_audio() then
      local auto_audio_paths = find_auto_audio_paths_for_srt(path)
      local auto_bound_count = 0
      local first_bound_audio_path = nil
      for _, auto_audio_path in ipairs(auto_audio_paths) do
        local auto_bound_ok = env.load_audio_from_path(auto_audio_path, {
          update_metadata = true,
          mark_dirty = app.source.metadata_path ~= nil,
        })
        if auto_bound_ok then
          auto_bound_count = auto_bound_count + 1
          first_bound_audio_path = first_bound_audio_path or auto_audio_path
        end
      end
      if auto_bound_count > 0 then
        if first_bound_audio_path then
          env.select_audio_by_path(first_bound_audio_path)
        end
        local auto_bound_message = t("status.auto_bound_audio_from_srt_dir", auto_bound_count)
        if metadata_message and metadata_message ~= "" then
          metadata_message = metadata_message .. " / " .. auto_bound_message
        else
          metadata_message = auto_bound_message
        end
      end
    end

    local base_message = t("status.loaded_srt_items", app.source.srt_name, #app.data.items)
    if metadata_message and metadata_message ~= "" then
      app.ui.status = t("status.loaded_srt_with_message", base_message, metadata_message)
    elseif app.source.metadata_loaded then
      app.ui.status = t("status.loaded_srt_metadata_loaded", base_message)
    elseif app.source.metadata_path then
      app.ui.status = t("status.loaded_srt_metadata_ready", base_message)
    else
      app.ui.status = base_message
    end

    invalidate_source_library_cache()
    set_single_source_selection(app.source.metadata_path)
    append_source_to_order(app.source.metadata_path)
    remember_recent_source(path)
    set_last_opened_srt_path(path)
    remember_browse_file_path("srt", path)

    return true, app.ui.status
  end

  env.load_audio_from_path = function(path, options)
    options = options or {}

    if not path or path == "" then
      return false, t("status.no_audio_file_selected")
    end
    if is_supported_audio_file_path and not is_supported_audio_file_path(path) then
      return false, t("status.unsupported_audio_file")
    end

    local audio_length_sec = get_media_length_sec(path)
    if not audio_length_sec then
      return false, t("status.failed_get_audio_length")
    end

    sync_current_audio_offset_to_entry()

    local audio_files = copy_audio_file_entries(app.source.audio_files)
    local existing_index = find_audio_entry_index(audio_files, path)
    local entry = existing_index and audio_files[existing_index] or nil
    if not entry then
      entry = {
        path = path,
        label = "",
        is_primary = #audio_files == 0,
        offset_ms = 0,
        length_sec = audio_length_sec,
      }
      audio_files[#audio_files + 1] = entry
    else
      entry.length_sec = audio_length_sec
      entry.offset_ms = parse_integer(entry.offset_ms, 0) or 0
    end

    set_audio_binding_entries(audio_files)
    select_audio_entry(entry)

    if options.update_metadata ~= false then
      sync_current_audio_offset_to_entry()
    end

    app.ui.status = t("status.bound_audio_with_length", app.source.audio_name or path, audio_length_sec)

    if options.mark_dirty ~= false then
      env.mark_metadata_dirty()
    end
    invalidate_source_library_cache()
    remember_browse_file_path("audio", path)
    return true, app.ui.status
  end

  env.select_audio_by_path = function(path)
    sync_current_audio_offset_to_entry()
    local entry = get_selected_audio_entry(app.source.audio_files, path)
    if not entry then
      app.ui.status = t("status.no_audio_file_bound")
      return false, app.ui.status
    end

    select_audio_entry(entry)
    env.mark_metadata_dirty()
    invalidate_source_library_cache()
    app.ui.status = t("status.selected_audio_binding", get_filename(entry.path) or entry.path)
    return true, app.ui.status
  end

  env.load_source_entry = function(entry)
    if not entry then
      app.ui.status = t("status.no_source_selected")
      return false
    end

    if not entry.source_path or entry.source_path == "" or entry.source_missing then
      app.ui.status = t("status.selected_srt_file_missing")
      return false
    end

    return env.load_srt_from_path(entry.source_path, { reset_filters = true })
  end
end
