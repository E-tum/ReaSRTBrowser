return function(env)
  local app = env.app
  local APP_NAME = env.APP_NAME
  local t = env.t
  local now_sec = env.now_sec
  local trim = env.trim
  local normalize_folder_name = env.normalize_folder_name
  local compare_text_case_insensitive = env.compare_text_case_insensitive
  local normalize_source_order_entries = env.normalize_source_order_entries
  local normalize_search_text = env.normalize_search_text
  local hash_string_djb2 = env.hash_string_djb2
  local invalidate_items = env.invalidate_items
  local clear_selection = env.clear_selection
  local get_default_libraries_path = env.get_default_libraries_path
  local read_text_file_utf8 = env.read_text_file_utf8
  local json_decode = env.json_decode
  local get_default_app_storage_dir = env.get_default_app_storage_dir
  local ensure_directory_exists = env.ensure_directory_exists
  local json_encode = env.json_encode
  local write_text_file_utf8 = env.write_text_file_utf8
  local LibraryStore = env.LibraryStore

  function LibraryStore.normalize_entries(entries)
    local result = {}
    local seen = {}

    if type(entries) ~= "table" then
      return result
    end

    for _, entry in ipairs(entries) do
      if type(entry) == "table" then
        local library_id = trim(entry.id)
        local library_name = normalize_folder_name(entry.name)
        if library_id ~= "" and library_name ~= "" and not seen[library_id] then
          seen[library_id] = true
          result[#result + 1] = {
            id = library_id,
            name = library_name,
          }
        end
      end
    end

    table.sort(result, function(a, b)
      if a.name ~= b.name then
        return compare_text_case_insensitive(a.name, b.name)
      end
      return tostring(a.id) < tostring(b.id)
    end)

    return result
  end

  function LibraryStore.normalize_memberships(memberships, valid_library_ids)
    local result = {}
    valid_library_ids = valid_library_ids or {}

    if type(memberships) ~= "table" then
      return result
    end

    for raw_library_id, raw_entries in pairs(memberships) do
      local library_id = tostring(raw_library_id or "")
      if library_id ~= "" and valid_library_ids[library_id] and type(raw_entries) == "table" then
        local normalized = normalize_source_order_entries(raw_entries)
        if #normalized > 0 then
          result[library_id] = normalized
        end
      end
    end

    return result
  end

  function LibraryStore.build_payload()
    local entries = LibraryStore.normalize_entries(app.user_libraries.entries)
    local valid_library_ids = {}
    for _, entry in ipairs(entries) do
      valid_library_ids[entry.id] = true
    end

    return {
      app_name = APP_NAME,
      libraries = entries,
      library_sources = LibraryStore.normalize_memberships(app.user_libraries.source_memberships, valid_library_ids),
    }
  end

  function LibraryStore.mark_dirty()
    app.user_libraries.dirty = true
    app.user_libraries.dirty_at = now_sec()
  end

  function LibraryStore.get_by_id(library_id)
    library_id = tostring(library_id or "")
    if library_id == "" then
      return nil
    end

    for _, entry in ipairs(app.user_libraries.entries or {}) do
      if entry.id == library_id then
        return entry
      end
    end

    return nil
  end

  function LibraryStore.generate_id(seed)
    local existing = {}
    for _, entry in ipairs(app.user_libraries.entries or {}) do
      existing[entry.id] = true
    end

    local attempt = 0
    repeat
      local candidate = "lib_" .. hash_string_djb2(table.concat({
        tostring(seed or ""),
        tostring(now_sec()),
        tostring(math.random()),
        tostring(attempt),
      }, "|"))
      if not existing[candidate] then
        return candidate
      end
      attempt = attempt + 1
    until attempt > 1000

    return "lib_" .. tostring(math.floor(now_sec() * 1000))
  end

  function LibraryStore.ensure_selected_library_valid()
    local selected_id = tostring(app.user_libraries.selected_library_id or "")
    if selected_id == "" then
      return
    end
    if LibraryStore.get_by_id(selected_id) then
      return
    end

    app.user_libraries.selected_library_id = nil
    app.user_libraries.selected_member_metadata_path = nil
    if app.ui.content_mode == "library" then
      app.ui.content_mode = "source"
      app.ui.active_library_id = nil
    end
  end

  function LibraryStore.get_member_paths(library_id)
    library_id = tostring(library_id or "")
    if library_id == "" then
      return {}
    end
    return normalize_source_order_entries((app.user_libraries.source_memberships or {})[library_id])
  end

  function LibraryStore.create(name)
    name = normalize_folder_name(name)
    if name == "" then
      return false, t("error.library_name_empty")
    end

    for _, entry in ipairs(app.user_libraries.entries or {}) do
      if normalize_search_text(entry.name) == normalize_search_text(name) then
        return false, t("error.library_name_exists")
      end
    end

    local library_id = LibraryStore.generate_id(name)
    app.user_libraries.entries[#app.user_libraries.entries + 1] = {
      id = library_id,
      name = name,
    }
    app.user_libraries.entries = LibraryStore.normalize_entries(app.user_libraries.entries)
    app.user_libraries.source_memberships[library_id] = app.user_libraries.source_memberships[library_id] or {}
    app.user_libraries.selected_library_id = library_id
    LibraryStore.mark_dirty()
    return true, library_id
  end

  function LibraryStore.rename(library_id, name)
    local entry = LibraryStore.get_by_id(library_id)
    if not entry then
      return false, t("error.library_not_found")
    end

    name = normalize_folder_name(name)
    if name == "" then
      return false, t("error.library_name_empty")
    end

    for _, other in ipairs(app.user_libraries.entries or {}) do
      if other.id ~= entry.id and normalize_search_text(other.name) == normalize_search_text(name) then
        return false, t("error.library_name_exists")
      end
    end

    entry.name = name
    app.user_libraries.entries = LibraryStore.normalize_entries(app.user_libraries.entries)
    LibraryStore.mark_dirty()
    return true, entry.id
  end

  function LibraryStore.delete(library_id)
    local entry = LibraryStore.get_by_id(library_id)
    if not entry then
      return false, t("error.library_not_found")
    end

    for index = #app.user_libraries.entries, 1, -1 do
      if app.user_libraries.entries[index].id == library_id then
        table.remove(app.user_libraries.entries, index)
        break
      end
    end
    app.user_libraries.source_memberships[library_id] = nil
    if app.user_libraries.selected_library_id == library_id then
      app.user_libraries.selected_library_id = nil
      app.user_libraries.selected_member_metadata_path = nil
    end
    if app.ui.active_library_id == library_id then
      app.ui.active_library_id = nil
      app.ui.content_mode = "source"
      app.data.items = {}
      invalidate_items()
      clear_selection()
    end
    LibraryStore.mark_dirty()
    LibraryStore.ensure_selected_library_valid()
    return true, entry.name
  end

  function LibraryStore.add_sources(library_id, metadata_paths)
    local entry = LibraryStore.get_by_id(library_id)
    if not entry then
      return false, t("error.library_not_found")
    end

    local normalized = LibraryStore.get_member_paths(library_id)
    local seen = {}
    for _, metadata_path in ipairs(normalized) do
      seen[normalize_search_text(metadata_path)] = true
    end

    local added_count = 0
    for _, raw_path in ipairs(metadata_paths or {}) do
      local metadata_path = tostring(raw_path or "")
      if metadata_path ~= "" then
        local key = normalize_search_text(metadata_path)
        if not seen[key] then
          seen[key] = true
          normalized[#normalized + 1] = metadata_path
          added_count = added_count + 1
        end
      end
    end

    if added_count == 0 then
      return false, t("error.selected_srts_already_in_library")
    end

    app.user_libraries.source_memberships[library_id] = normalized
    app.user_libraries.selected_library_id = library_id
    LibraryStore.mark_dirty()
    return true, added_count
  end

  function LibraryStore.remove_sources(library_id, metadata_paths)
    local entry = LibraryStore.get_by_id(library_id)
    if not entry then
      return false, t("error.library_not_found")
    end

    local remove_lookup = {}
    for _, metadata_path in ipairs(metadata_paths or {}) do
      metadata_path = tostring(metadata_path or "")
      if metadata_path ~= "" then
        remove_lookup[normalize_search_text(metadata_path)] = true
      end
    end

    if next(remove_lookup) == nil then
      return false, t("status.no_srt_selected")
    end

    local current = LibraryStore.get_member_paths(library_id)
    local filtered = {}
    local removed_count = 0
    for _, metadata_path in ipairs(current) do
      if remove_lookup[normalize_search_text(metadata_path)] then
        removed_count = removed_count + 1
      else
        filtered[#filtered + 1] = metadata_path
      end
    end

    if removed_count == 0 then
      return false, t("error.selected_srts_not_in_library")
    end

    app.user_libraries.source_memberships[library_id] = filtered
    if app.user_libraries.selected_member_metadata_path
      and remove_lookup[normalize_search_text(app.user_libraries.selected_member_metadata_path)] then
      app.user_libraries.selected_member_metadata_path = nil
    end
    LibraryStore.mark_dirty()
    return true, removed_count
  end

  function LibraryStore.remove_source_from_all(metadata_path)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      return false
    end

    local key = normalize_search_text(metadata_path)
    local changed = false
    for library_id, entries in pairs(app.user_libraries.source_memberships or {}) do
      local filtered = {}
      local removed = false
      for _, existing_path in ipairs(entries or {}) do
        if normalize_search_text(existing_path) == key then
          removed = true
        else
          filtered[#filtered + 1] = existing_path
        end
      end
      if removed then
        app.user_libraries.source_memberships[library_id] = filtered
        changed = true
      end
    end

    if app.user_libraries.selected_member_metadata_path
      and normalize_search_text(app.user_libraries.selected_member_metadata_path) == key then
      app.user_libraries.selected_member_metadata_path = nil
    end

    if changed then
      LibraryStore.mark_dirty()
    end
    return changed
  end

  function LibraryStore.load_json()
    local libraries_path = get_default_libraries_path()
    if libraries_path == "" then
      return false, t("error.libraries_path_unresolved")
    end

    app.user_libraries.path = libraries_path

    local content, err = read_text_file_utf8(libraries_path)
    if not content then
      if err and err:find("Failed to open file", 1, true) then
        app.user_libraries.loaded = true
        app.user_libraries.entries = {}
        app.user_libraries.source_memberships = {}
        return true, t("status.libraries_file_missing")
      end
      return false, err or t("error.failed_read_libraries")
    end

    if content == "" then
      app.user_libraries.loaded = true
      app.user_libraries.entries = {}
      app.user_libraries.source_memberships = {}
      return true, t("status.libraries_file_empty")
    end

    local ok, decoded = pcall(json_decode, content)
    if not ok or type(decoded) ~= "table" then
      return false, t("error.failed_parse_libraries_json")
    end

    app.user_libraries.entries = LibraryStore.normalize_entries(decoded.libraries)
    local valid_library_ids = {}
    for _, entry in ipairs(app.user_libraries.entries) do
      valid_library_ids[entry.id] = true
    end
    app.user_libraries.source_memberships =
      LibraryStore.normalize_memberships(decoded.library_sources, valid_library_ids)
    app.user_libraries.loaded = true
    LibraryStore.ensure_selected_library_valid()
    return true, t("status.libraries_loaded")
  end

  function LibraryStore.save_json()
    local libraries_path = app.user_libraries.path or get_default_libraries_path()
    if not libraries_path or libraries_path == "" then
      return false, t("error.libraries_path_unresolved")
    end

    local app_dir = get_default_app_storage_dir()
    if app_dir == "" then
      return false, t("error.libraries_dir_unresolved")
    end

    local ok_dir, dir_err = ensure_directory_exists(app_dir)
    if not ok_dir then
      return false, dir_err or t("error.failed_create_libraries_dir")
    end

    app.user_libraries.path = libraries_path
    local encoded = json_encode(LibraryStore.build_payload())
    local ok, err = write_text_file_utf8(libraries_path, encoded)
    if not ok then
      return false, err or t("error.failed_save_libraries")
    end

    app.user_libraries.loaded = true
    return true, libraries_path
  end

  function LibraryStore.flush_if_needed(force)
    if not app.user_libraries.dirty then
      return
    end

    local now = now_sec()
    local dirty_at = app.user_libraries.dirty_at or now
    if force or (now - dirty_at >= app.user_libraries.save_delay_sec) then
      local ok, err = LibraryStore.save_json()
      if ok then
        app.user_libraries.dirty = false
        app.user_libraries.dirty_at = nil
      elseif err and err ~= "" then
        app.ui.status = err
      end
    end
  end

  function LibraryStore.initialize_state()
    if app.user_libraries.initialized then
      return
    end

    local ok, message = LibraryStore.load_json()
    app.user_libraries.initialized = true
    if not ok then
      app.ui.status = message or t("status.failed_load_libraries")
      return
    end
  end
end
