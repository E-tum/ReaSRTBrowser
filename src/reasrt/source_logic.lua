return function(env)
  local app = env.app
  local ctx = env.ctx
  local reaper = env.reaper
  local t = env.t
  local trim = env.trim
  local normalize_search_text = env.normalize_search_text
  local contains_icase_blob = env.contains_icase_blob
  local get_selected_source_count = env.get_selected_source_count
  local set_single_source_selection = env.set_single_source_selection
  local is_source_selected = env.is_source_selected
  local toggle_source_selection = env.toggle_source_selection
  local clear_source_selection = env.clear_source_selection
  local refresh_source_library_cache = env.refresh_source_library_cache
  local invalidate_source_library_cache = env.invalidate_source_library_cache
  local get_library_folder_lookup = env.get_library_folder_lookup
  local get_library_folder_display_path = env.get_library_folder_display_path
  local move_source_order_entries_before_target = env.move_source_order_entries_before_target
  local move_source_order_entries_after_target = env.move_source_order_entries_after_target
  local compare_text_case_insensitive = env.compare_text_case_insensitive
  local get_source_order_lookup = env.get_source_order_lookup
  local load_source_entry = env.load_source_entry
  local prompt_open_audio = env.prompt_open_audio
  local flush_metadata_now = env.flush_metadata_now
  local LibraryStore = env.LibraryStore
  local remove_source_folder_assignment = env.remove_source_folder_assignment
  local remove_source_from_order = env.remove_source_from_order
  local file_exists = env.file_exists
  local delete_file = env.delete_file
  local stop_preview = env.stop_preview
  local clear_loaded_items = env.clear_loaded_items
  local set_last_opened_srt_path = env.set_last_opened_srt_path
  local prune_source_selection = env.prune_source_selection
  local get_filename = env.get_filename
  local save_metadata_json = env.save_metadata_json
  local load_srt_from_path = env.load_srt_from_path
  local now_sec = env.now_sec
  local mark_settings_dirty = env.mark_settings_dirty or function()
  end
  local SourcePane = env.SourcePane
  local LibraryPane = env.LibraryPane

  function SourcePane.get_selected_metadata_paths_list()
    local selected_paths = {}
    for metadata_path, selected in pairs(app.library.selected_metadata_paths or {}) do
      if selected and metadata_path then
        selected_paths[#selected_paths + 1] = metadata_path
      end
    end
    table.sort(selected_paths)
    return selected_paths
  end

  function SourcePane.move_metadata_paths_to_folder(metadata_paths, folder_id)
    metadata_paths = metadata_paths or {}
    local moved_count = 0
    local first_error = nil

    for _, metadata_path in ipairs(metadata_paths) do
      local changed, result = env.assign_source_to_folder(metadata_path, folder_id)
      if changed then
        moved_count = moved_count + 1
      elseif result and result ~= folder_id then
        first_error = first_error or result
      end
    end

    if moved_count > 0 then
      invalidate_source_library_cache()
      refresh_source_library_cache()
    end

    return moved_count, first_error
  end

  function SourcePane.move_selected_sources_to_folder(folder_id)
    local selected_paths = SourcePane.get_selected_metadata_paths_list()
    if #selected_paths == 0 then
      app.ui.status = t("status.no_srt_selected_in_library")
      return false
    end

    local moved_count, first_error = SourcePane.move_metadata_paths_to_folder(selected_paths, folder_id)
    if moved_count == 0 then
      app.ui.status = first_error or t("status.selected_srts_already_in_folder")
      return false
    end

    local folder_label = "(root)"
    if folder_id then
      local folders_by_id = get_library_folder_lookup(app.settings.library_folders)
      folder_label = get_library_folder_display_path(folder_id, folders_by_id)
      if folder_label == "" then
        folder_label = "(root)"
      end
    end

    app.ui.status = t("status.moved_srt_entries_to", moved_count, folder_label)
    return true
  end

  function SourcePane.move_library_source_to_folder(metadata_path, folder_id)
    local moved_count, first_error = SourcePane.move_metadata_paths_to_folder({ metadata_path }, folder_id)
    if moved_count == 0 then
      app.ui.status = first_error or t("status.srt_already_in_folder")
      return false
    end

    local folder_label = "(root)"
    if folder_id then
      local folders_by_id = get_library_folder_lookup(app.settings.library_folders)
      folder_label = get_library_folder_display_path(folder_id, folders_by_id)
      if folder_label == "" then
        folder_label = "(root)"
      end
    end

    app.ui.status = t("status.moved_srt_to_folder", folder_label)
    return true
  end

  function SourcePane.move_dragged_library_sources_to_folder(metadata_path, folder_id)
    metadata_path = tostring(metadata_path or "")
    if metadata_path == "" then
      app.ui.status = t("status.no_srt_selected_in_library")
      return false
    end

    if get_selected_source_count() > 1 and is_source_selected(metadata_path) then
      return SourcePane.move_selected_sources_to_folder(folder_id)
    end

    return SourcePane.move_library_source_to_folder(metadata_path, folder_id)
  end

  function SourcePane.reorder_dragged_library_sources_before_target(dragged_metadata_path, target_entry)
    dragged_metadata_path = tostring(dragged_metadata_path or "")
    if dragged_metadata_path == "" or not target_entry or not target_entry.metadata_path then
      return false
    end

    local target_metadata_path = tostring(target_entry.metadata_path or "")
    if target_metadata_path == "" then
      return false
    end

    local moved_paths = nil
    if get_selected_source_count() > 1 and is_source_selected(dragged_metadata_path) then
      moved_paths = SourcePane.get_selected_metadata_paths_list()
    else
      moved_paths = { dragged_metadata_path }
    end

    local filtered_paths = {}
    local seen = {}
    local moving_lookup = {}
    for _, metadata_path in ipairs(moved_paths) do
      metadata_path = tostring(metadata_path or "")
      if metadata_path ~= "" and not seen[metadata_path] then
        seen[metadata_path] = true
        moving_lookup[metadata_path] = true
        if metadata_path ~= target_metadata_path then
          filtered_paths[#filtered_paths + 1] = metadata_path
        end
      end
    end
    if moving_lookup[target_metadata_path] then
      return false
    end
    if #filtered_paths == 0 then
      return false
    end

    local moved_count = select(1, SourcePane.move_metadata_paths_to_folder(filtered_paths, target_entry.folder_id))
    local order_changed = move_source_order_entries_before_target(filtered_paths, target_metadata_path)
    if order_changed or (moved_count and moved_count > 0) then
      invalidate_source_library_cache()
      refresh_source_library_cache()
      app.ui.status = t("status.reordered_srt_entries", #filtered_paths)
      return true
    end

    return false
  end

  function SourcePane.reorder_dragged_library_sources_after_target(dragged_metadata_path, target_metadata_path, target_folder_id)
    dragged_metadata_path = tostring(dragged_metadata_path or "")
    target_metadata_path = tostring(target_metadata_path or "")
    if dragged_metadata_path == "" or target_metadata_path == "" then
      return false
    end

    local moved_paths = nil
    if get_selected_source_count() > 1 and is_source_selected(dragged_metadata_path) then
      moved_paths = SourcePane.get_selected_metadata_paths_list()
    else
      moved_paths = { dragged_metadata_path }
    end

    local filtered_paths = {}
    local seen = {}
    local moving_lookup = {}
    for _, metadata_path in ipairs(moved_paths) do
      metadata_path = tostring(metadata_path or "")
      if metadata_path ~= "" and not seen[metadata_path] then
        seen[metadata_path] = true
        moving_lookup[metadata_path] = true
        if metadata_path ~= target_metadata_path then
          filtered_paths[#filtered_paths + 1] = metadata_path
        end
      end
    end
    if moving_lookup[target_metadata_path] then
      return false
    end
    if #filtered_paths == 0 then
      return false
    end

    local moved_count = select(1, SourcePane.move_metadata_paths_to_folder(filtered_paths, target_folder_id))
    local order_changed = move_source_order_entries_after_target(filtered_paths, target_metadata_path)
    if order_changed or (moved_count and moved_count > 0) then
      invalidate_source_library_cache()
      refresh_source_library_cache()
      app.ui.status = t("status.reordered_srt_entries", #filtered_paths)
      return true
    end

    return false
  end

  function SourcePane.expand_all_library_folders(is_open)
    app.library.folder_open_state = {}
    for _, folder in ipairs(app.settings.library_folders or {}) do
      app.library.folder_open_state[folder.id] = is_open == true
    end
    mark_settings_dirty()
    app.ui.status = is_open and t("status.expanded_all_folders") or t("status.collapsed_all_folders")
  end

  function SourcePane.build_library_tree(filtered_sources)
    local root = {
      id = nil,
      name = "",
      parent_id = nil,
      folder_order = {},
      folders = {},
      sources = {},
    }
    local folder_lookup = {
      ["__root__"] = root,
    }

    for _, folder in ipairs(app.settings.library_folders or {}) do
      folder_lookup[folder.id] = {
        id = folder.id,
        name = folder.name,
        parent_id = folder.parent_id,
        folder_order = {},
        folders = {},
        sources = {},
      }
    end

    for _, node in pairs(folder_lookup) do
      if node ~= root then
        local parent_key = node.parent_id or "__root__"
        local parent_node = folder_lookup[parent_key] or root
        parent_node.folders[node.id] = node
        parent_node.folder_order[#parent_node.folder_order + 1] = node.id
      end
    end

    for _, entry in ipairs(filtered_sources or {}) do
      local parent_key = entry.folder_id or "__root__"
      local parent_node = folder_lookup[parent_key] or root
      parent_node.sources[#parent_node.sources + 1] = entry
    end

    local keep_empty_folders = trim(app.library.source_filter or "") == ""
    local source_order_lookup = get_source_order_lookup()

    local function finalize_node(node)
      table.sort(node.folder_order, function(a, b)
        local node_a = folder_lookup[a]
        local node_b = folder_lookup[b]
        return compare_text_case_insensitive(node_a and node_a.name or a, node_b and node_b.name or b)
      end)

      table.sort(node.sources, function(a, b)
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

      local visible_folder_order = {}
      for _, child_id in ipairs(node.folder_order) do
        local child = folder_lookup[child_id]
        if child then
          local keep_child = finalize_node(child)
          if keep_child or keep_empty_folders then
            visible_folder_order[#visible_folder_order + 1] = child_id
          end
        end
      end
      node.folder_order = visible_folder_order

      return #node.sources > 0 or #node.folder_order > 0
    end

    finalize_node(root)
    return root, folder_lookup
  end

  function SourcePane.prompt_open_audio_for_source_entry(entry)
    if not entry or not entry.metadata_path then
      app.ui.status = t("status.no_srt_selected_in_library")
      return false
    end

    set_single_source_selection(entry.metadata_path)

    local source_is_current = app.source.metadata_path ~= nil
      and entry.metadata_path == app.source.metadata_path

    if not source_is_current then
      local ok, message = load_source_entry(entry)
      if not ok then
        app.ui.status = message or t("status.failed_open_srt_before_bind_audio")
        return false
      end
    end

    prompt_open_audio()
    return true
  end

  function SourcePane.get_filtered_library_sources()
    local result = {}
    local needle = normalize_search_text(trim(app.library.source_filter or ""))

    for _, entry in ipairs(app.library.sources or {}) do
      if contains_icase_blob(entry.search_blob or "", needle) then
        result[#result + 1] = entry
      end
    end

    return result
  end

  function SourcePane.get_filtered_source_pos_by_metadata_path(metadata_path)
    if not metadata_path then
      return nil
    end

    local filtered_sources = SourcePane.get_filtered_library_sources()
    for pos, entry in ipairs(filtered_sources) do
      if entry.metadata_path == metadata_path then
        return pos
      end
    end

    return nil
  end

  function SourcePane.select_source_range_between(anchor_metadata_path, target_metadata_path, keep_existing)
    local filtered_sources = SourcePane.get_filtered_library_sources()
    local anchor_pos = SourcePane.get_filtered_source_pos_by_metadata_path(anchor_metadata_path)
    local target_pos = SourcePane.get_filtered_source_pos_by_metadata_path(target_metadata_path)

    if not target_pos then
      return
    end

    if not anchor_pos then
      set_single_source_selection(target_metadata_path)
      return
    end

    if not keep_existing then
      app.library.selected_metadata_paths = {}
    end

    local start_pos = math.min(anchor_pos, target_pos)
    local end_pos = math.max(anchor_pos, target_pos)

    for pos = start_pos, end_pos do
      local entry = filtered_sources[pos]
      if entry and entry.metadata_path then
        app.library.selected_metadata_paths[entry.metadata_path] = true
      end
    end

    app.library.last_selected_metadata_path = target_metadata_path
    app.library.selection_anchor_metadata_path = anchor_metadata_path
  end

  function SourcePane.select_all_filtered_sources()
    local filtered_sources = SourcePane.get_filtered_library_sources()
    app.library.selected_metadata_paths = {}

    for _, entry in ipairs(filtered_sources) do
      if entry and entry.metadata_path then
        app.library.selected_metadata_paths[entry.metadata_path] = true
      end
    end

    local first_entry = filtered_sources[1]
    local last_entry = filtered_sources[#filtered_sources]
    app.library.selection_anchor_metadata_path = first_entry and first_entry.metadata_path or nil
    app.library.last_selected_metadata_path = last_entry and last_entry.metadata_path or nil
  end

  function SourcePane.handle_source_selection_interaction(entry)
    if not entry or not entry.metadata_path then
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
      local anchor = app.library.selection_anchor_metadata_path or app.library.last_selected_metadata_path or entry.metadata_path
      SourcePane.select_source_range_between(anchor, entry.metadata_path, false)
      app.ui.status = t("status.selected_srt_entries", get_selected_source_count())
      return
    end

    if ctrl_down then
      toggle_source_selection(entry.metadata_path)
      local count = get_selected_source_count()
      app.ui.status = t("status.selected_srt_entries", count)
      return
    end

    set_single_source_selection(entry.metadata_path)
    load_source_entry(entry)
  end

  function SourcePane.clear_selected_sources_from_library()
    local selected_paths = {}
    for metadata_path, selected in pairs(app.library.selected_metadata_paths or {}) do
      if selected and metadata_path then
        selected_paths[#selected_paths + 1] = metadata_path
      end
    end

    if #selected_paths == 0 then
      app.ui.status = t("status.no_srt_selected_in_library")
      return false
    end

    if not flush_metadata_now() then
      app.ui.status = t("status.failed_save_metadata_before_clear_srt")
      return false
    end

    local current_metadata_path = app.source.metadata_path
    local current_removed = false
    local removed_count = 0

    table.sort(selected_paths)

    for _, metadata_path in ipairs(selected_paths) do
      if current_metadata_path and metadata_path == current_metadata_path then
        current_removed = true
      end

      LibraryStore.remove_source_from_all(metadata_path)
      remove_source_folder_assignment(metadata_path)
      remove_source_from_order(metadata_path)

      if file_exists(metadata_path) then
        local ok, err = delete_file(metadata_path)
        if not ok then
          app.ui.status = err or t("status.failed_clear_srt_metadata", tostring(metadata_path))
          return false
        end
        removed_count = removed_count + 1
      end
    end

    if current_removed then
      stop_preview()
      clear_loaded_items()
      set_last_opened_srt_path(nil)
    end

    clear_source_selection()
    invalidate_source_library_cache()
    refresh_source_library_cache()
    prune_source_selection()
    if app.ui.content_mode == "library" and app.ui.active_library_id then
      LibraryPane.reload_active_view({
        reset_filters = false,
      })
    end

    app.ui.status = t("status.cleared_srt_entries", removed_count)
    return true
  end

  function SourcePane.get_current_audio_path_summary()
    if app.source.audio_loaded and app.source.audio_path then
      return tostring(get_filename(app.source.audio_path) or app.source.audio_path)
    end
    if app.source.audio_missing and app.source.audio_missing_path then
      return t("label.audio_missing_file", tostring(get_filename(app.source.audio_missing_path) or app.source.audio_missing_path))
    end
    return t("label.none")
  end

  function SourcePane.get_source_entry_audio_status(entry)
    if not entry then
      return t("label.audio_status_none")
    end
    if entry.audio_missing and entry.audio_name ~= "" then
      return t("label.audio_status_missing", tostring(entry.audio_name))
    end
    if entry.audio_path ~= "" and not entry.audio_missing then
      return t("label.audio_status_linked")
    end
    return t("label.audio_status_none")
  end

  function SourcePane.save_metadata_now_and_clear_dirty()
    local ok, err = save_metadata_json()
    if ok then
      app.data.metadata_dirty = false
      app.data.metadata_dirty_at = nil
      app.data.last_save_at = now_sec()
      return true
    end
    app.ui.status = err or app.ui.status
    return false
  end
end
