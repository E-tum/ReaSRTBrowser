return function(env)
  local app = env.app
  local reaper = env.reaper
  local t = env.t
  local trim = env.trim
  local normalize_search_text = env.normalize_search_text
  local normalize_folder_name = env.normalize_folder_name
  local normalize_virtual_folder_path = env.normalize_virtual_folder_path
  local split_virtual_folder_path = env.split_virtual_folder_path
  local generate_library_folder_id = env.generate_library_folder_id
  local get_library_folder_lookup = env.get_library_folder_lookup
  local get_library_folder_display_path = env.get_library_folder_display_path
  local sort_library_folder_entries = env.sort_library_folder_entries
  local compare_text_case_insensitive = env.compare_text_case_insensitive
  local mark_settings_dirty = env.mark_settings_dirty
  local get_default_metadata_dir = env.get_default_metadata_dir
  local read_text_file_utf8 = env.read_text_file_utf8
  local json_decode = env.json_decode
  local copy_audio_file_entries = env.copy_audio_file_entries
  local get_selected_audio_entry = env.get_selected_audio_entry
  local file_exists = env.file_exists
  local get_filename = env.get_filename
  local parse_integer = env.parse_integer
  local join_tags = env.join_tags
  local parse_tags_text = env.parse_tags_text
  local format_ms = env.format_ms
  local make_item_lookup_key = env.make_item_lookup_key
  local contains_icase_blob = env.contains_icase_blob
  local strip_leading_speaker_label = env.strip_leading_speaker_label

  env.get_library_folder_by_id = function(folder_id)
    folder_id = tostring(folder_id or "")
    if folder_id == "" then
      return nil
    end

    for _, folder in ipairs(app.settings.library_folders or {}) do
      if folder.id == folder_id then
        return folder
      end
    end

    return nil
  end

  env.get_source_folder_id = function(metadata_path)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return nil
    end

    local folder_id = tostring((app.settings.source_folders or {})[metadata_path] or "")
    return folder_id ~= "" and folder_id or nil
  end

  env.get_folder_id_by_parent_and_name = function(parent_id, folder_name)
    folder_name = normalize_folder_name(folder_name)
    if folder_name == "" then
      return nil
    end

    for _, folder in ipairs(app.settings.library_folders or {}) do
      local same_parent = (folder.parent_id or nil) == (parent_id or nil)
      if same_parent and normalize_search_text(folder.name) == normalize_search_text(folder_name) then
        return folder.id
      end
    end

    return nil
  end

  env.ensure_library_folder_exists = function(folder_path)
    folder_path = normalize_virtual_folder_path(folder_path)
    if folder_path == "" then
      return false, nil
    end

    local current_parent_id = nil
    local created = false
    for _, part in ipairs(split_virtual_folder_path(folder_path)) do
      local existing_id = env.get_folder_id_by_parent_and_name(current_parent_id, part)
      if existing_id then
        current_parent_id = existing_id
      else
        local folder_id = generate_library_folder_id(select(1, get_library_folder_lookup(app.settings.library_folders)), folder_path .. "|" .. tostring(current_parent_id or "root"))
        app.settings.library_folders[#app.settings.library_folders + 1] = {
          id = folder_id,
          name = part,
          parent_id = current_parent_id,
        }
        current_parent_id = folder_id
        created = true
      end
    end

    if created then
      sort_library_folder_entries(app.settings.library_folders)
      mark_settings_dirty()
    end

    return created, current_parent_id
  end

  env.create_library_folder = function(folder_name, parent_id)
    folder_name = normalize_folder_name(folder_name)
    if folder_name == "" then
      return false, t("error.folder_name_empty")
    end

    if folder_name:find("[/\\]") then
      return false, t("error.folder_name_slashes")
    end

    if parent_id then
      parent_id = tostring(parent_id)
      if not env.get_library_folder_by_id(parent_id) then
        return false, t("error.folder_parent_not_found")
      end
    end

    if env.get_folder_id_by_parent_and_name(parent_id, folder_name) then
      return false, t("error.folder_name_exists_here")
    end

    local folder_id = generate_library_folder_id(select(1, get_library_folder_lookup(app.settings.library_folders)), folder_name .. "|" .. tostring(parent_id or "root"))
    app.settings.library_folders[#app.settings.library_folders + 1] = {
      id = folder_id,
      name = folder_name,
      parent_id = parent_id,
    }
    sort_library_folder_entries(app.settings.library_folders)
    app.library.folder_open_state[parent_id or "__root__"] = true
    app.library.folder_open_state[folder_id] = true
    mark_settings_dirty()
    return true, folder_id
  end

  env.get_library_folder_children_ids = function(folder_id)
    local ids = {}
    for _, folder in ipairs(app.settings.library_folders or {}) do
      if (folder.parent_id or nil) == (folder_id or nil) then
        ids[#ids + 1] = folder.id
      end
    end
    return ids
  end

  env.is_descendant_folder_id = function(folder_id, ancestor_id)
    local current = env.get_library_folder_by_id(folder_id)
    while current do
      if current.parent_id == ancestor_id then
        return true
      end
      current = current.parent_id and env.get_library_folder_by_id(current.parent_id) or nil
    end
    return false
  end

  env.rename_library_folder = function(folder_id, new_name)
    local folder = env.get_library_folder_by_id(folder_id)
    if not folder then
      return false, t("error.folder_not_found")
    end

    new_name = normalize_folder_name(new_name)
    if new_name == "" then
      return false, t("error.folder_name_empty")
    end
    if new_name:find("[/\\]") then
      return false, t("error.folder_name_slashes")
    end

    local sibling_id = env.get_folder_id_by_parent_and_name(folder.parent_id, new_name)
    if sibling_id and sibling_id ~= folder.id then
      return false, t("error.folder_name_exists_here")
    end

    if folder.name == new_name then
      return false, t("error.folder_name_unchanged")
    end

    folder.name = new_name
    sort_library_folder_entries(app.settings.library_folders)
    env.invalidate_source_library_cache()
    mark_settings_dirty()
    return true, folder.id
  end

  env.move_library_folder = function(folder_id, new_parent_id)
    local folder = env.get_library_folder_by_id(folder_id)
    if not folder then
      return false, t("error.folder_not_found")
    end

    if new_parent_id ~= nil then
      new_parent_id = tostring(new_parent_id)
      if not env.get_library_folder_by_id(new_parent_id) then
        return false, t("error.folder_target_not_found")
      end
    end

    if new_parent_id == folder.id then
      return false, t("error.folder_move_into_self")
    end
    if new_parent_id and env.is_descendant_folder_id(new_parent_id, folder.id) then
      return false, t("error.folder_move_into_descendant")
    end

    local sibling_id = env.get_folder_id_by_parent_and_name(new_parent_id, folder.name)
    if sibling_id and sibling_id ~= folder.id then
      return false, t("error.folder_name_exists_target")
    end

    if (folder.parent_id or nil) == (new_parent_id or nil) then
      return false, t("error.folder_already_in_location")
    end

    folder.parent_id = new_parent_id
    sort_library_folder_entries(app.settings.library_folders)
    env.invalidate_source_library_cache()
    mark_settings_dirty()
    return true, folder.id
  end

  env.delete_library_folder = function(folder_id)
    local folder = env.get_library_folder_by_id(folder_id)
    if not folder then
      return false, t("error.folder_not_found")
    end

    local parent_id = folder.parent_id
    for _, child in ipairs(app.settings.library_folders or {}) do
      if child.parent_id == folder_id then
        child.parent_id = parent_id
      end
    end

    for metadata_path, assigned_folder_id in pairs(app.settings.source_folders or {}) do
      if assigned_folder_id == folder_id then
        app.settings.source_folders[metadata_path] = parent_id or nil
      end
    end

    for index = #app.settings.library_folders, 1, -1 do
      if app.settings.library_folders[index].id == folder_id then
        table.remove(app.settings.library_folders, index)
        break
      end
    end

    app.library.folder_open_state[folder_id] = nil
    sort_library_folder_entries(app.settings.library_folders)
    env.invalidate_source_library_cache()
    mark_settings_dirty()
    return true, parent_id
  end

  env.assign_source_to_folder = function(metadata_path, folder_id)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return false, t("error.metadata_path_empty")
    end

    folder_id = tostring(folder_id or "")
    if folder_id == "" then
      folder_id = nil
    elseif not env.get_library_folder_by_id(folder_id) then
      return false, t("error.folder_target_not_found")
    end

    local current_folder_id = env.get_source_folder_id(metadata_path)
    if current_folder_id == folder_id then
      return false, folder_id
    end

    app.settings.source_folders[metadata_path] = folder_id
    mark_settings_dirty()
    return true, folder_id
  end

  env.remove_source_folder_assignment = function(metadata_path)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return false
    end

    if (app.settings.source_folders or {})[metadata_path] == nil then
      return false
    end

    app.settings.source_folders[metadata_path] = nil
    mark_settings_dirty()
    return true
  end

  env.append_source_to_order = function(metadata_path)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return false
    end

    for _, existing_path in ipairs(app.settings.source_order or {}) do
      if existing_path == metadata_path then
        return false
      end
    end

    app.settings.source_order[#app.settings.source_order + 1] = metadata_path
    mark_settings_dirty()
    return true
  end

  env.remove_source_from_order = function(metadata_path)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return false
    end

    for index = #app.settings.source_order, 1, -1 do
      if app.settings.source_order[index] == metadata_path then
        table.remove(app.settings.source_order, index)
        mark_settings_dirty()
        return true
      end
    end

    return false
  end

  env.get_source_order_lookup = function()
    local lookup = {}
    for index, metadata_path in ipairs(app.settings.source_order or {}) do
      lookup[metadata_path] = index
    end
    return lookup
  end

  env.move_source_order_entries_before_target = function(metadata_paths, target_metadata_path)
    metadata_paths = metadata_paths or {}
    target_metadata_path = tostring(target_metadata_path or "")
    if #metadata_paths == 0 or target_metadata_path == "" then
      return false
    end

    local moving = {}
    for _, metadata_path in ipairs(metadata_paths) do
      metadata_path = tostring(metadata_path or "")
      if metadata_path ~= "" and metadata_path ~= target_metadata_path then
        moving[metadata_path] = true
      end
    end

    local filtered = {}
    for _, metadata_path in ipairs(app.settings.source_order or {}) do
      if not moving[metadata_path] then
        filtered[#filtered + 1] = metadata_path
      end
    end

    local insert_index = #filtered + 1
    for index, metadata_path in ipairs(filtered) do
      if metadata_path == target_metadata_path then
        insert_index = index
        break
      end
    end

    local ordered_moving = {}
    local seen = {}
    for _, metadata_path in ipairs(app.settings.source_order or {}) do
      if moving[metadata_path] and not seen[metadata_path] then
        seen[metadata_path] = true
        ordered_moving[#ordered_moving + 1] = metadata_path
      end
    end

    for offset, metadata_path in ipairs(ordered_moving) do
      table.insert(filtered, insert_index + offset - 1, metadata_path)
    end

    local changed = #filtered ~= #(app.settings.source_order or {})
    if not changed then
      for index, metadata_path in ipairs(filtered) do
        if app.settings.source_order[index] ~= metadata_path then
          changed = true
          break
        end
      end
    end

    if not changed then
      return false
    end

    app.settings.source_order = filtered
    mark_settings_dirty()
    return true
  end

  env.move_source_order_entries_after_target = function(metadata_paths, target_metadata_path)
    metadata_paths = metadata_paths or {}
    target_metadata_path = tostring(target_metadata_path or "")
    if #metadata_paths == 0 or target_metadata_path == "" then
      return false
    end

    local moving = {}
    for _, metadata_path in ipairs(metadata_paths) do
      metadata_path = tostring(metadata_path or "")
      if metadata_path ~= "" and metadata_path ~= target_metadata_path then
        moving[metadata_path] = true
      end
    end

    if moving[target_metadata_path] then
      return false
    end

    local filtered = {}
    for _, metadata_path in ipairs(app.settings.source_order or {}) do
      if not moving[metadata_path] then
        filtered[#filtered + 1] = metadata_path
      end
    end

    local insert_index = #filtered + 1
    for index, metadata_path in ipairs(filtered) do
      if metadata_path == target_metadata_path then
        insert_index = index + 1
        break
      end
    end

    local ordered_moving = {}
    local seen = {}
    for _, metadata_path in ipairs(app.settings.source_order or {}) do
      if moving[metadata_path] and not seen[metadata_path] then
        seen[metadata_path] = true
        ordered_moving[#ordered_moving + 1] = metadata_path
      end
    end

    for offset, metadata_path in ipairs(ordered_moving) do
      table.insert(filtered, insert_index + offset - 1, metadata_path)
    end

    local changed = #filtered ~= #(app.settings.source_order or {})
    if not changed then
      for index, metadata_path in ipairs(filtered) do
        if app.settings.source_order[index] ~= metadata_path then
          changed = true
          break
        end
      end
    end

    if not changed then
      return false
    end

    app.settings.source_order = filtered
    mark_settings_dirty()
    return true
  end

  local function enumerate_metadata_json_files()
    local dir = get_default_metadata_dir()
    if dir == "" then
      return nil, t("error.metadata_base_dir_unresolved")
    end

    local files = {}
    local index = 0
    while reaper.EnumerateFiles do
      local name = reaper.EnumerateFiles(dir, index)
      if not name then
        break
      end
      if name:lower():match("%.json$") then
        files[#files + 1] = dir .. "\\" .. name
      end
      index = index + 1
    end

    return files
  end

  env.refresh_source_library_cache = function()
    if not app.library.sources_dirty then
      return true
    end

    local files, err = enumerate_metadata_json_files()
    if not files then
      app.library.sources = {}
      app.library.sources_status = err or t("error.failed_enumerate_metadata")
      app.library.sources_dirty = false
      return false
    end

    local sources = {}
    local folders_by_id = get_library_folder_lookup(app.settings.library_folders)
    local folder_path_cache = {}

    for _, metadata_path in ipairs(files) do
      local content = read_text_file_utf8(metadata_path)
      if content and content ~= "" then
        local ok, decoded = pcall(json_decode, content)
        if ok and type(decoded) == "table" then
          local source = type(decoded.source) == "table" and decoded.source or {}
          local source_path = tostring(source.srt_path or "")
          local source_name = tostring(source.srt_filename or "")
          if source_name == "" then
            source_name = get_filename(source_path)
          end
          if source_name == "" then
            source_name = get_filename(metadata_path) or t("label.unknown")
          end

          local audio_files = copy_audio_file_entries(decoded.audio_files)
          local active_audio = get_selected_audio_entry(audio_files, decoded.selected_audio_path)
          local audio_path = active_audio and tostring(active_audio.path or "") or ""
          local audio_missing = audio_path ~= "" and not file_exists(audio_path)

          if app.source.srt_loaded and app.source.metadata_path == metadata_path then
            if app.source.audio_loaded and app.source.audio_path and app.source.audio_path ~= "" then
              audio_path = tostring(app.source.audio_path)
              audio_missing = false
            elseif app.source.audio_missing and app.source.audio_missing_path and app.source.audio_missing_path ~= "" then
              audio_path = tostring(app.source.audio_missing_path)
              audio_missing = true
            else
              audio_path = ""
              audio_missing = false
            end
          end

          local folder_id = env.get_source_folder_id(metadata_path)
          local folder_path = folder_id and get_library_folder_display_path(folder_id, folders_by_id, folder_path_cache) or ""

          sources[#sources + 1] = {
            metadata_path = metadata_path,
            source_path = source_path,
            source_name = source_name,
            folder_id = folder_id,
            folder_path = folder_path,
            source_missing = source_path == "" or not file_exists(source_path),
            item_count = type(decoded.items) == "table" and #decoded.items or 0,
            audio_path = audio_path,
            audio_name = get_filename(audio_path) or "",
            audio_missing = audio_missing,
            search_blob = normalize_search_text(table.concat({
              source_name,
              folder_path,
              source_path,
              audio_path,
            }, "\n")),
          }
        end
      end
    end

    local valid_metadata_paths = {}
    for _, entry in ipairs(sources) do
      valid_metadata_paths[entry.metadata_path] = true
    end

    local new_source_order = {}
    local seen_in_order = {}
    for _, metadata_path in ipairs(app.settings.source_order or {}) do
      if valid_metadata_paths[metadata_path] and not seen_in_order[metadata_path] then
        seen_in_order[metadata_path] = true
        new_source_order[#new_source_order + 1] = metadata_path
      end
    end
    for _, entry in ipairs(sources) do
      if not seen_in_order[entry.metadata_path] then
        seen_in_order[entry.metadata_path] = true
        new_source_order[#new_source_order + 1] = entry.metadata_path
      end
    end

    local source_order_changed = #new_source_order ~= #(app.settings.source_order or {})
    if not source_order_changed then
      for index, metadata_path in ipairs(new_source_order) do
        if app.settings.source_order[index] ~= metadata_path then
          source_order_changed = true
          break
        end
      end
    end
    if source_order_changed then
      app.settings.source_order = new_source_order
      mark_settings_dirty()
    end

    local source_order_lookup = env.get_source_order_lookup()

    table.sort(sources, function(a, b)
      local a_missing = a.source_missing and 1 or 0
      local b_missing = b.source_missing and 1 or 0
      if a_missing ~= b_missing then
        return a_missing < b_missing
      end
      if a.folder_path ~= b.folder_path then
        if a.folder_path == "" then
          return true
        end
        if b.folder_path == "" then
          return false
        end
        if compare_text_case_insensitive(a.folder_path, b.folder_path) then
          return true
        end
        if compare_text_case_insensitive(b.folder_path, a.folder_path) then
          return false
        end
      end
      local a_order = source_order_lookup[a.metadata_path] or math.huge
      local b_order = source_order_lookup[b.metadata_path] or math.huge
      if a_order ~= b_order then
        return a_order < b_order
      end
      if a.source_name ~= b.source_name then
        return compare_text_case_insensitive(a.source_name, b.source_name)
      end
      return a.metadata_path < b.metadata_path
    end)

    app.library.sources = sources
    app.library.sources_status = t("status.source_library_entries", #sources)
    app.library.sources_dirty = false
    if env.prune_source_selection then
      env.prune_source_selection()
    end
    return true
  end

  env.search_library = function(query)
    query = trim(query or app.library.query or "")
    app.library.query = query
    app.library.results = {}

    if query == "" then
      app.library.status = t("status.library_search_enter_text")
      app.library.scanned_files = 0
      app.ui.status = app.library.status
      return false
    end

    local files, err = enumerate_metadata_json_files()
    if not files then
      app.library.status = err or t("error.failed_enumerate_metadata")
      app.library.scanned_files = 0
      app.ui.status = app.library.status
      return false
    end

    local needle = normalize_search_text(query)
    local results = {}

    for _, metadata_path in ipairs(files) do
      local content = read_text_file_utf8(metadata_path)
      if content and content ~= "" then
        local ok, decoded = pcall(json_decode, content)
        if ok and type(decoded) == "table" and type(decoded.items) == "table" then
          local source = type(decoded.source) == "table" and decoded.source or {}
          local source_path = tostring(source.srt_path or "")
          local source_name = tostring(source.srt_filename or "")
          if source_name == "" then
            source_name = get_filename(source_path)
          end
          if source_name == "" then
            source_name = get_filename(metadata_path)
          end
          local audio_files = copy_audio_file_entries(decoded.audio_files)
          local active_audio = get_selected_audio_entry(audio_files, decoded.selected_audio_path)
          local offset_ms = active_audio and (parse_integer(active_audio.offset_ms, 0) or 0)
            or (parse_integer(decoded.global_offset_ms, 0) or 0)

          for _, meta_item in ipairs(decoded.items) do
            local key = type(meta_item.key) == "table" and meta_item.key or {}
            local text_value = tostring(key.text or "")
            local display_text = app.settings.hide_speaker_labels == true
              and strip_leading_speaker_label(text_value)
              or text_value
            local note_value = tostring(meta_item.note or "")
            local tags = type(meta_item.tags) == "table" and meta_item.tags or parse_tags_text(meta_item.tags_text)
            local tags_text = join_tags(tags)
            local search_blob = normalize_search_text(table.concat({
              source_name,
              source_path,
              display_text,
              note_value,
              tags_text,
            }, "\n"))

            if contains_icase_blob(search_blob, needle) then
              local start_ms = parse_integer(key.start_ms, 0) or 0
              local end_ms = parse_integer(key.end_ms, 0) or 0
              results[#results + 1] = {
                source_name = source_name,
                source_path = source_path,
                metadata_path = metadata_path,
                srt_index = parse_integer(key.srt_index, 0) or 0,
                text = text_value,
                display_text = display_text,
                note = note_value,
                tags_text = tags_text,
                favorite = meta_item.favorite == true,
                start_ms = start_ms,
                end_ms = end_ms,
                display_start = format_ms(start_ms + offset_ms),
                display_end = format_ms(end_ms + offset_ms),
                item_key = make_item_lookup_key(
                  key.srt_index,
                  key.start_ms,
                  key.end_ms,
                  key.text
                ),
              }
            end
          end
        end
      end
    end

    table.sort(results, function(a, b)
      if a.source_name ~= b.source_name then
        return a.source_name < b.source_name
      end
      if a.srt_index ~= b.srt_index then
        return a.srt_index < b.srt_index
      end
      return a.start_ms < b.start_ms
    end)

    app.library.results = results
    app.library.scanned_files = #files
    app.library.status = t("status.library_search_summary", #results, #files)
    app.ui.status = app.library.status
    return true
  end

  env.load_library_result = function(result)
    if not result then
      app.ui.status = t("status.no_library_result_selected")
      return false
    end

    if not result.source_path or result.source_path == "" then
      app.ui.status = t("status.library_result_missing_source_path")
      return false
    end

    if not file_exists(result.source_path) then
      app.ui.status = t("status.library_result_source_missing")
      return false
    end

    if app.preview.is_playing and env.stop_preview then
      env.stop_preview()
    end

    local ok, message = env.load_srt_from_path(result.source_path)
    if not ok then
      app.ui.status = message or t("status.failed_load_source_from_library")
      return false
    end

    app.ui.filter_text = ""
    app.ui.filter_tags = ""
    app.ui.filter_favorites_only = false
    env.invalidate_filter_cache()

    local item = select(1, env.find_item_by_key(result.item_key))
    if item then
      env.set_single_selection(item.key)
      app.ui.status = t(
        "status.loaded_library_selected_subtitle",
        tostring(app.source.srt_name or result.source_name),
        tostring(item.srt_index or "?")
      )
      return true
    end

    app.ui.status = t(
      "status.loaded_library_match_not_selected",
      tostring(app.source.srt_name or result.source_name)
    )
    return true
  end

  env.prompt_create_library_folder = function(parent_id)
    if not reaper.GetUserInputs then
      app.ui.status = t("status.folder_creation_unavailable")
      return false
    end

    local parent_label = ""
    if parent_id then
      local folders_by_id = get_library_folder_lookup(app.settings.library_folders)
      parent_label = get_library_folder_display_path(parent_id, folders_by_id) or ""
    end

    local title = parent_id and t("prompt.create_subfolder_title") or t("prompt.create_folder_title")
    local prompt = parent_id
      and t("prompt.folder_name_under", parent_label)
      or t("prompt.folder_name")
    local ok, value = reaper.GetUserInputs(title, 1, prompt, "")
    if not ok then
      app.ui.status = parent_id and t("status.create_subfolder_canceled") or t("status.create_folder_canceled")
      return false
    end

    local created, result = env.create_library_folder(value, parent_id)
    if not created then
      app.ui.status = result or t("status.failed_create_folder")
      return false
    end

    env.invalidate_source_library_cache()
    local folders_by_id = get_library_folder_lookup(app.settings.library_folders)
    local folder_label = get_library_folder_display_path(result, folders_by_id)
    app.ui.status = t("status.created_folder", folder_label ~= "" and folder_label or t("label.folder"))
    return true
  end

  env.prompt_rename_library_folder = function(folder_id)
    local folder = env.get_library_folder_by_id(folder_id)
    if not folder then
      app.ui.status = t("error.folder_not_found")
      return false
    end

    if not reaper.GetUserInputs then
      app.ui.status = t("status.folder_rename_unavailable")
      return false
    end

    local ok, value = reaper.GetUserInputs(
      t("prompt.rename_folder_title"),
      1,
      t("prompt.folder_name"),
      tostring(folder.name or "")
    )
    if not ok then
      app.ui.status = t("status.rename_folder_canceled")
      return false
    end

    local renamed, result = env.rename_library_folder(folder_id, value)
    if not renamed then
      app.ui.status = result or t("status.failed_rename_folder")
      return false
    end

    local folders_by_id = get_library_folder_lookup(app.settings.library_folders)
    local folder_label = get_library_folder_display_path(result, folders_by_id)
    app.ui.status = t("status.renamed_folder", folder_label ~= "" and folder_label or t("label.folder"))
    return true
  end
end
