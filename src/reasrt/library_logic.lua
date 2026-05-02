return function(env)
  local app = env.app
  local t = env.t
  local LibraryPane = env.LibraryPane
  local LibraryStore = env.LibraryStore
  local read_text_file_utf8 = env.read_text_file_utf8
  local json_decode = env.json_decode
  local json_encode = env.json_encode
  local write_text_file_utf8 = env.write_text_file_utf8
  local invalidate_source_library_cache = env.invalidate_source_library_cache
  local make_item_lookup_key = env.make_item_lookup_key
  local get_media_length_sec = env.get_media_length_sec
  local get_filename = env.get_filename
  local refresh_source_library_cache = env.refresh_source_library_cache
  local copy_audio_file_entries = env.copy_audio_file_entries
  local get_primary_audio_file_entry = env.get_primary_audio_file_entry
  local parse_integer = env.parse_integer
  local parse_tags_text = env.parse_tags_text
  local join_tags = env.join_tags
  local file_exists = env.file_exists
  local flush_metadata_now = env.flush_metadata_now
  local stop_preview = env.stop_preview
  local prepare_all_runtime_fields = env.prepare_all_runtime_fields
  local invalidate_items = env.invalidate_items
  local clear_selection = env.clear_selection
  local find_item_by_key = env.find_item_by_key
  local set_single_selection = env.set_single_selection
  local invalidate_filter_cache = env.invalidate_filter_cache
  local set_left_panel_tab = env.set_left_panel_tab or function(tab_name)
    app.ui.left_panel_tab = tab_name
  end
  local mark_settings_dirty = env.mark_settings_dirty or function()
  end

  local function reset_filtered_view_state()
    app.cache.filtered_indices = {}
    app.cache.filter_revision = app.ui.filter_revision
    app.cache.items_revision = app.data.items_revision
    app.ui.item_list_clipper = nil
  end

  function LibraryPane.read_metadata_payload(metadata_path)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return false, t("error.metadata_path_empty")
    end

    local content, err = read_text_file_utf8(metadata_path)
    if not content then
      return false, err or t("error.failed_read_metadata_file")
    end
    if content == "" then
      return false, t("error.metadata_file_empty")
    end

    local ok, decoded = pcall(json_decode, content)
    if not ok or type(decoded) ~= "table" then
      return false, t("error.failed_parse_metadata_json", tostring(decoded))
    end

    return true, decoded
  end

  function LibraryPane.write_metadata_payload(metadata_path, payload)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return false, t("error.metadata_path_empty")
    end

    local encoded = json_encode(payload)
    local ok, err = write_text_file_utf8(metadata_path, encoded)
    if not ok then
      return false, err or t("status.failed_save_metadata")
    end

    invalidate_source_library_cache()
    return true
  end

  function LibraryPane.find_metadata_item(payload, item)
    if type(payload) ~= "table" or type(payload.items) ~= "table" or not item then
      return nil
    end

    local target_key = tostring(item.metadata_lookup_key or "")
    if target_key == "" then
      return nil
    end

    for _, meta_item in ipairs(payload.items) do
      local key = type(meta_item.key) == "table" and meta_item.key or {}
      local lookup_key = make_item_lookup_key(key.srt_index, key.start_ms, key.end_ms, key.text)
      if lookup_key == target_key then
        return meta_item
      end
    end

    return nil
  end

  function LibraryPane.bind_audio_to_item(item, path)
    if not item or not item.source_metadata_path then
      return false, t("status.no_library_item_selected")
    end

    path = tostring(path or "")
    if path == "" then
      return false, t("status.no_audio_file_selected")
    end

    local ok, err = LibraryPane.update_item_metadata(item, function(payload)
      payload.audio_files = {
        {
          path = path,
          label = "primary",
          is_primary = true,
        }
      }
    end)
    if not ok then
      return false, err or t("status.failed_bind_audio")
    end

    app.user_libraries.audio_length_cache[path] = get_media_length_sec(path)
    if app.ui.content_mode == "library" and app.ui.active_library_id then
      LibraryPane.reload_active_view({
        reset_filters = false,
        selected_item_key = item.key,
      })
    end

    local audio_name = get_filename(path) or path
    app.ui.status = t("status.bound_audio", audio_name)
    return true, app.ui.status
  end

  function LibraryPane.get_library_display_name(library_id)
    local entry = LibraryStore.get_by_id(library_id)
    if not entry then
      return t("label.library")
    end
    return tostring(entry.name or t("label.library"))
  end

  function LibraryPane.get_member_entries(library_id)
    refresh_source_library_cache()

    local by_metadata_path = {}
    for _, entry in ipairs(app.library.sources or {}) do
      if entry.metadata_path then
        by_metadata_path[entry.metadata_path] = entry
      end
    end

    local result = {}
    for _, metadata_path in ipairs(LibraryStore.get_member_paths(library_id)) do
      local entry = by_metadata_path[metadata_path]
      if entry then
        result[#result + 1] = entry
      end
    end

    return result
  end

  function LibraryPane.load_view(library_id, options)
    options = options or {}

    local library = LibraryStore.get_by_id(library_id)
    if not library then
      return false, t("status.library_not_found")
    end

    if app.source.srt_loaded and not flush_metadata_now() then
      app.ui.status = t("status.failed_save_metadata_before_switch_library")
      return false, app.ui.status
    end

    if app.preview.is_playing then
      stop_preview()
    end

    local aggregated_items = {}
    local member_paths = LibraryStore.get_member_paths(library_id)
    local loaded_sources = 0

    if #member_paths == 0 then
      app.data.items = {}
      prepare_all_runtime_fields()
      invalidate_items()
      clear_selection()

      if options.reset_filters ~= false then
        app.ui.filter_text = ""
        app.ui.filter_tags = ""
        app.ui.filter_favorites_only = false
        invalidate_filter_cache()
      end

      reset_filtered_view_state()

      app.ui.content_mode = "library"
      set_left_panel_tab("libraries")
      app.ui.active_library_id = library_id
      app.user_libraries.selected_library_id = library_id
      app.user_libraries.selected_member_metadata_path = nil
      mark_settings_dirty()
      app.ui.status = t("status.opened_empty_library", LibraryPane.get_library_display_name(library_id))
      return true, app.ui.status
    end

    for _, metadata_path in ipairs(member_paths) do
      local ok, payload_or_err = LibraryPane.read_metadata_payload(metadata_path)
      if ok then
        local payload = payload_or_err
        local source = type(payload.source) == "table" and payload.source or {}
        local source_path = tostring(source.srt_path or "")
        local source_name = tostring(source.srt_filename or "")
        if source_name == "" then
          source_name = get_filename(source_path) or get_filename(metadata_path) or "(unknown)"
        end

        local audio_files = copy_audio_file_entries(payload.audio_files)
        local primary_audio = get_primary_audio_file_entry(audio_files)
        local primary_audio_path = primary_audio and tostring(primary_audio.path or "") or ""
        local primary_audio_name = primary_audio_path ~= "" and (get_filename(primary_audio_path) or primary_audio_path) or ""
        local audio_missing = primary_audio_path ~= "" and not file_exists(primary_audio_path)
        local source_global_offset_ms = parse_integer(payload.global_offset_ms, 0) or 0

        if type(payload.items) == "table" then
          for _, meta_item in ipairs(payload.items) do
            local key = type(meta_item.key) == "table" and meta_item.key or {}
            aggregated_items[#aggregated_items + 1] = {
              srt_index = parse_integer(key.srt_index, 0) or 0,
              text = tostring(key.text or ""),
              start_ms = parse_integer(key.start_ms, 0) or 0,
              end_ms = parse_integer(key.end_ms, 0) or 0,
              note = tostring(meta_item.note or ""),
              tags = type(meta_item.tags) == "table" and meta_item.tags or parse_tags_text(meta_item.tags_text),
              tags_text = type(meta_item.tags) == "table" and join_tags(meta_item.tags) or tostring(meta_item.tags_text or ""),
              favorite = meta_item.favorite == true,
              source_metadata_path = metadata_path,
              source_srt_path = source_path,
              source_name = source_name,
              source_global_offset_ms = source_global_offset_ms,
              source_audio_files = audio_files,
              source_audio_path = primary_audio_path,
              source_audio_name = primary_audio_name,
              source_audio_missing = audio_missing,
            }
          end
        end

        loaded_sources = loaded_sources + 1
      end
    end

    app.data.items = aggregated_items
    prepare_all_runtime_fields()
    invalidate_items()
    app.ui.item_list_clipper = nil

    clear_selection()
    local selected_key = options.selected_item_key
    if selected_key then
      local selected_item = find_item_by_key(selected_key)
      if selected_item then
        set_single_selection(selected_item.key)
      end
    end
    if not app.ui.last_selected_item_key and app.data.items[1] then
      set_single_selection(app.data.items[1].key)
    end

    if options.reset_filters ~= false then
      app.ui.filter_text = ""
      app.ui.filter_tags = ""
      app.ui.filter_favorites_only = false
      invalidate_filter_cache()
    end

    app.ui.content_mode = "library"
    set_left_panel_tab("libraries")
    app.ui.active_library_id = library_id
    app.user_libraries.selected_library_id = library_id
    app.user_libraries.selected_member_metadata_path = nil
    mark_settings_dirty()
    app.ui.status = t(
      "status.opened_library_items_sources",
      LibraryPane.get_library_display_name(library_id),
      #aggregated_items,
      loaded_sources
    )
    return true, app.ui.status
  end

  function LibraryPane.reload_active_view(options)
    local library_id = app.ui.active_library_id or app.user_libraries.selected_library_id
    if not library_id then
      app.ui.status = t("status.no_library_open")
      return false, app.ui.status
    end
    return LibraryPane.load_view(library_id, options)
  end

  function LibraryPane.resolve_item_audio_context(item)
    if item and item.source_metadata_path then
      local audio_path = tostring(item.source_audio_path or "")
      if audio_path == "" then
        return {
          loaded = false,
          missing = false,
          path = nil,
          name = nil,
          length_sec = nil,
        }
      end

      local missing = item.source_audio_missing == true or not file_exists(audio_path)
      local length_sec = nil
      if not missing then
        length_sec = app.user_libraries.audio_length_cache[audio_path]
        if length_sec == nil then
          length_sec = get_media_length_sec(audio_path)
          app.user_libraries.audio_length_cache[audio_path] = length_sec
        end
      end

      return {
        loaded = not missing,
        missing = missing,
        path = audio_path,
        name = tostring(item.source_audio_name or get_filename(audio_path) or audio_path),
        length_sec = length_sec,
      }
    end

    return {
      loaded = app.source.audio_loaded and app.source.audio_path ~= nil,
      missing = app.source.audio_missing == true,
      path = app.source.audio_path,
      name = app.source.audio_name,
      length_sec = app.source.audio_length_sec,
    }
  end

  function LibraryPane.update_item_metadata(item, update_fn)
    if not item or not item.source_metadata_path then
      return false, t("status.no_library_item_selected")
    end

    local ok, payload_or_err = LibraryPane.read_metadata_payload(item.source_metadata_path)
    if not ok then
      return false, payload_or_err
    end

    local payload = payload_or_err
    local meta_item = LibraryPane.find_metadata_item(payload, item)
    if not meta_item then
      return false, t("status.selected_item_not_resolved_in_metadata")
    end

    update_fn(payload, meta_item)
    local save_ok, save_err = LibraryPane.write_metadata_payload(item.source_metadata_path, payload)
    if not save_ok then
      return false, save_err
    end

    return true, payload
  end
end
