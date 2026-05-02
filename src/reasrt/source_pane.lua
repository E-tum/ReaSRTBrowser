return function(env)
  local app = env.app
  local ctx = env.ctx
  local reaper = env.reaper
  local t = env.t
  local get_font_small = env.get_font_small or function()
    return env.font_small
  end
  local get_font_small_size = env.get_font_small_size or function()
    return env.font_small_size
  end
  local now_sec = env.now_sec
  local trim = env.trim
  local is_srt_file_path = env.is_srt_file_path
  local compare_text_case_insensitive = env.compare_text_case_insensitive
  local get_library_folder_display_path = env.get_library_folder_display_path
  local get_library_folder_lookup = env.get_library_folder_lookup
  local mark_settings_dirty = env.mark_settings_dirty or function()
  end
  local prompt_create_library_folder = env.prompt_create_library_folder
  local prompt_rename_library_folder = env.prompt_rename_library_folder
  local move_library_folder = env.move_library_folder
  local is_descendant_folder_id = env.is_descendant_folder_id
  local delete_library_folder = env.delete_library_folder
  local get_selected_source_count = env.get_selected_source_count
  local set_single_source_selection = env.set_single_source_selection
  local is_source_selected = env.is_source_selected
  local load_source_entry = env.load_source_entry
  local add_srt_paths_to_library = env.add_srt_paths_to_library
  local refresh_source_library_cache = env.refresh_source_library_cache
  local prompt_add_srt = env.prompt_add_srt
  local SourcePane = env.SourcePane
  local LibraryPane = env.LibraryPane
  local LibraryStore = env.LibraryStore

  local function get_action_label(use_selected)
    if use_selected then
      return t("label.selected_srts")
    end
    return t("label.srt")
  end

  function SourcePane.get_folder_label(state, folder_id)
    local path = folder_id and get_library_folder_display_path(folder_id, state.folders_by_id, state.folder_path_cache) or ""
    return path ~= "" and path or t("label.root")
  end

  function SourcePane.draw_folder_choice_menu(state, menu_label, on_pick, options)
    options = options or {}
    if not (reaper.ImGui_BeginMenu and reaper.ImGui_EndMenu and reaper.ImGui_MenuItem) then
      return
    end

    if not reaper.ImGui_BeginMenu(ctx, menu_label) then
      return
    end

    if options.include_root and reaper.ImGui_MenuItem(ctx, t("menu.library_root")) then
      on_pick(nil)
    end

    local excluded = options.excluded_ids or {}
    local folders = {}
    for _, folder in ipairs(app.settings.library_folders or {}) do
      if not excluded[folder.id] then
        folders[#folders + 1] = folder
      end
    end

    table.sort(folders, function(a, b)
      local path_a = get_library_folder_display_path(a.id, state.folders_by_id, state.folder_path_cache)
      local path_b = get_library_folder_display_path(b.id, state.folders_by_id, state.folder_path_cache)
      if path_a ~= path_b then
        return compare_text_case_insensitive(path_a, path_b)
      end
      return tostring(a.id) < tostring(b.id)
    end)

    for _, folder in ipairs(folders) do
      local label = get_library_folder_display_path(folder.id, state.folders_by_id, state.folder_path_cache)
      if reaper.ImGui_MenuItem(ctx, label) then
        on_pick(folder.id)
      end
    end

    reaper.ImGui_EndMenu(ctx)
  end

  function SourcePane.draw_folder_context_menu(state, node)
    if not (reaper.ImGui_BeginPopupContextItem and reaper.ImGui_EndPopup) then
      return
    end

    if reaper.ImGui_BeginPopupContextItem(ctx, "folder_context##" .. tostring(node.id)) then
      if reaper.ImGui_MenuItem(ctx, t("menu.new_subfolder")) then
        prompt_create_library_folder(node.id)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.rename_folder")) then
        prompt_rename_library_folder(node.id)
      end
      if node.parent_id and reaper.ImGui_MenuItem(ctx, t("menu.move_folder_to_root")) then
        local ok, message = move_library_folder(node.id, nil)
        app.ui.status = ok and t("status.moved_folder_to", SourcePane.get_folder_label(state, nil))
          or (message or t("status.failed_move_folder"))
      end

      local excluded_ids = {
        [node.id] = true,
      }
      for _, folder in ipairs(app.settings.library_folders or {}) do
        if is_descendant_folder_id(folder.id, node.id) then
          excluded_ids[folder.id] = true
        end
      end

      SourcePane.draw_folder_choice_menu(state, t("menu.move_folder_to"), function(target_folder_id)
        local ok, message = move_library_folder(node.id, target_folder_id)
        app.ui.status = ok and t("status.moved_folder_to", SourcePane.get_folder_label(state, target_folder_id))
          or (message or t("status.failed_move_folder"))
      end, {
        include_root = node.parent_id ~= nil,
        excluded_ids = excluded_ids,
      })

      if reaper.ImGui_Separator then
        reaper.ImGui_Separator(ctx)
      end

      if reaper.ImGui_MenuItem(ctx, t("menu.delete_folder")) then
        local ok, parent_id_or_message = delete_library_folder(node.id)
        app.ui.status = ok and t("status.deleted_folder_contents_moved", SourcePane.get_folder_label(state, parent_id_or_message))
          or (parent_id_or_message or t("status.failed_delete_folder"))
      end

      if reaper.ImGui_Separator then
        reaper.ImGui_Separator(ctx)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.expand_all")) then
        SourcePane.expand_all_library_folders(true)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.collapse_all")) then
        SourcePane.expand_all_library_folders(false)
      end

      reaper.ImGui_EndPopup(ctx)
    end
  end

  function SourcePane.draw_source_context_menu(state, entry)
    if not (reaper.ImGui_BeginPopupContextItem and reaper.ImGui_EndPopup) then
      return
    end

    if reaper.ImGui_BeginPopupContextItem(ctx, "source_context##" .. tostring(entry.metadata_path)) then
      local selected_count = get_selected_source_count()
      local use_selected = selected_count > 1 and is_source_selected(entry.metadata_path)
      local action_label = get_action_label(use_selected)
      local target_paths = use_selected and SourcePane.get_selected_metadata_paths_list() or { entry.metadata_path }

      if not is_source_selected(entry.metadata_path) then
        set_single_source_selection(entry.metadata_path)
        use_selected = false
        action_label = get_action_label(false)
        target_paths = { entry.metadata_path }
      end

      if reaper.ImGui_MenuItem(ctx, t("menu.open")) then
        load_source_entry(entry)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.open_audio")) then
        SourcePane.prompt_open_audio_for_source_entry(entry)
      end

      LibraryPane.draw_library_choice_menu(t("menu.add_to_library", action_label), function(target_library_id)
        local ok, added_or_err = LibraryStore.add_sources(target_library_id, target_paths)
        if ok then
          app.ui.status = t("status.added_to_library", action_label, LibraryPane.get_library_display_name(target_library_id))
        else
          app.ui.status = added_or_err or t("status.failed_add_srts_to_library")
        end
      end)

      if reaper.ImGui_Separator then
        reaper.ImGui_Separator(ctx)
      end

      if reaper.ImGui_MenuItem(ctx, t("menu.move_to_root", action_label)) then
        local moved_count = select(1, SourcePane.move_metadata_paths_to_folder(target_paths, nil))
        if moved_count and moved_count > 0 then
          app.ui.status = t("status.moved_to_destination", action_label, SourcePane.get_folder_label(state, nil))
        end
      end
      SourcePane.draw_folder_choice_menu(state, t("menu.move_to_folder", action_label), function(target_folder_id)
        local moved_count = select(1, SourcePane.move_metadata_paths_to_folder(target_paths, target_folder_id))
        if moved_count and moved_count > 0 then
          app.ui.status = t("status.moved_to_destination", action_label, SourcePane.get_folder_label(state, target_folder_id))
        end
      end, {
        include_root = false,
      })

      if reaper.ImGui_Separator then
        reaper.ImGui_Separator(ctx)
      end

      if reaper.ImGui_MenuItem(ctx, use_selected and t("menu.remove_selected_from_library") or t("menu.remove_from_library")) then
        if not use_selected then
          set_single_source_selection(entry.metadata_path)
        end
        SourcePane.clear_selected_sources_from_library()
      end

      reaper.ImGui_EndPopup(ctx)
    end
  end

  function SourcePane.draw_source_row_reorder_target(state, entry)
    if not (
      reaper.ImGui_BeginDragDropTarget
      and reaper.ImGui_AcceptDragDropPayload
      and reaper.ImGui_EndDragDropTarget
      and reaper.ImGui_GetItemRectMin
      and reaper.ImGui_GetItemRectMax
      and reaper.ImGui_GetMousePos
    ) then
      return false
    end

    local rect_min_x, rect_min_y = reaper.ImGui_GetItemRectMin(ctx)
    local rect_max_x, rect_max_y = reaper.ImGui_GetItemRectMax(ctx)
    local rect_mid_y = rect_min_y + ((rect_max_y - rect_min_y) * 0.5)

    local pushed_target_style = false
    if reaper.ImGui_PushStyleColor and reaper.ImGui_Col_DragDropTarget then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_DragDropTarget(), 0x00000000)
      pushed_target_style = true
    end

    local active = reaper.ImGui_BeginDragDropTarget(ctx)
    if not active then
      if pushed_target_style and reaper.ImGui_PopStyleColor then
        reaper.ImGui_PopStyleColor(ctx)
      end
      return false
    end

    local drag_drop_flags = 0
    if reaper.ImGui_DragDropFlags_AcceptNoDrawDefaultRect then
      drag_drop_flags = drag_drop_flags | reaper.ImGui_DragDropFlags_AcceptNoDrawDefaultRect()
    end

    local reorder_accepted, reorder_payload = reaper.ImGui_AcceptDragDropPayload(ctx, "SRT_LIBRARY_SOURCE", drag_drop_flags)
    if not reorder_payload or reorder_payload == "" then
      reaper.ImGui_EndDragDropTarget(ctx)
      if pushed_target_style and reaper.ImGui_PopStyleColor then
        reaper.ImGui_PopStyleColor(ctx)
      end
      return false
    end

    local _, mouse_y = reaper.ImGui_GetMousePos(ctx)
    local insert_after = mouse_y >= rect_mid_y

    if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine then
      local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
      local line_y = insert_after and (rect_max_y - 1) or rect_min_y
      reaper.ImGui_DrawList_AddLine(draw_list, rect_min_x + 2, line_y, rect_max_x - 2, line_y, 0xCC66CCFF, 2.0)
    end

    if reorder_accepted then
      state.internal_drop_handled = true
      if insert_after then
        SourcePane.reorder_dragged_library_sources_after_target(
          reorder_payload,
          entry.metadata_path,
          entry.folder_id
        )
      else
        SourcePane.reorder_dragged_library_sources_before_target(reorder_payload, entry)
      end
    end

    reaper.ImGui_EndDragDropTarget(ctx)
    if pushed_target_style and reaper.ImGui_PopStyleColor then
      reaper.ImGui_PopStyleColor(ctx)
    end
    return true
  end

  function SourcePane.draw_source_row(state, entry)
    local label = tostring(entry.source_name or t("label.unknown"))
    local selected = is_source_selected(entry.metadata_path)
    local dim_entry = entry.audio_path == "" or entry.audio_missing

    if dim_entry and reaper.ImGui_PushStyleColor and reaper.ImGui_Col_Text then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x99C8C8C8)
    end

    local selectable_flags = 0
    if reaper.ImGui_SelectableFlags_AllowDoubleClick then
      selectable_flags = selectable_flags | reaper.ImGui_SelectableFlags_AllowDoubleClick()
    end
    if reaper.ImGui_Selectable(ctx, label .. "##" .. tostring(entry.metadata_path), selected, selectable_flags) then
      SourcePane.handle_source_selection_interaction(entry)
    end
    if reaper.ImGui_IsItemHovered(ctx)
      and reaper.ImGui_IsMouseDoubleClicked
      and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      SourcePane.prompt_open_audio_for_source_entry(entry)
    end
    SourcePane.draw_source_context_menu(state, entry)

    if reaper.ImGui_BeginDragDropSource
      and reaper.ImGui_SetDragDropPayload
      and reaper.ImGui_EndDragDropSource
      and reaper.ImGui_BeginDragDropSource(ctx) then
      reaper.ImGui_SetDragDropPayload(ctx, "SRT_LIBRARY_SOURCE", tostring(entry.metadata_path))
      reaper.ImGui_Text(ctx, label)
      reaper.ImGui_EndDragDropSource(ctx)
    end

    SourcePane.draw_source_row_reorder_target(state, entry)

    if dim_entry and reaper.ImGui_PopStyleColor then
      reaper.ImGui_PopStyleColor(ctx)
    end

    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      state.any_source_hovered = true
      if app.ui.source_tooltip_hovered_metadata_path ~= entry.metadata_path then
        app.ui.source_tooltip_hovered_metadata_path = entry.metadata_path
        app.ui.source_tooltip_hover_started_at = now_sec()
      else
        local hover_started_at = app.ui.source_tooltip_hover_started_at or now_sec()
        local delay_sec = tonumber(app.ui.source_tooltip_delay_sec) or 0.8
        if now_sec() - hover_started_at >= delay_sec then
          local tooltip_parts = {
            t("label.items_count", entry.item_count or 0),
            SourcePane.get_source_entry_audio_status(entry),
          }
          reaper.ImGui_SetTooltip(ctx, table.concat(tooltip_parts, "\n"))
        end
      end
    end
  end

  function SourcePane.draw_folder_drag_source(node)
    if reaper.ImGui_BeginDragDropSource
      and reaper.ImGui_SetDragDropPayload
      and reaper.ImGui_EndDragDropSource
      and reaper.ImGui_BeginDragDropSource(ctx) then
      reaper.ImGui_SetDragDropPayload(ctx, "SRT_LIBRARY_FOLDER", tostring(node.id))
      reaper.ImGui_Text(ctx, tostring(node.name or t("label.folder")))
      reaper.ImGui_EndDragDropSource(ctx)
    end
  end

  function SourcePane.accept_folder_drop_target(state, folder_id)
    if reaper.ImGui_BeginDragDropTarget
      and reaper.ImGui_AcceptDragDropPayload
      and reaper.ImGui_EndDragDropTarget then
      local active = reaper.ImGui_BeginDragDropTarget(ctx)
      if active then
        local source_accepted, source_payload = reaper.ImGui_AcceptDragDropPayload(ctx, "SRT_LIBRARY_SOURCE")
        if source_accepted and source_payload and source_payload ~= "" then
          state.internal_drop_handled = true
          SourcePane.move_dragged_library_sources_to_folder(source_payload, folder_id)
        end

        local folder_accepted, folder_payload = reaper.ImGui_AcceptDragDropPayload(ctx, "SRT_LIBRARY_FOLDER")
        if folder_accepted and folder_payload and folder_payload ~= "" then
          state.internal_drop_handled = true
          local ok, message = move_library_folder(folder_payload, folder_id)
          app.ui.status = ok and t("status.moved_folder_to", SourcePane.get_folder_label(state, folder_id))
            or (message or t("status.failed_move_folder"))
        end
        reaper.ImGui_EndDragDropTarget(ctx)
      end
    end
  end

  function SourcePane.draw_folder_node(state, node)
    local has_children = #node.folder_order > 0 or #node.sources > 0
    local flags = 0
    if reaper.ImGui_TreeNodeFlags_SpanAvailWidth then
      flags = flags | reaper.ImGui_TreeNodeFlags_SpanAvailWidth()
    end
    if reaper.ImGui_TreeNodeFlags_FramePadding then
      flags = flags | reaper.ImGui_TreeNodeFlags_FramePadding()
    end
    if reaper.ImGui_TreeNodeFlags_OpenOnArrow then
      flags = flags | reaper.ImGui_TreeNodeFlags_OpenOnArrow()
    end
    if not has_children then
      if reaper.ImGui_TreeNodeFlags_Leaf then
        flags = flags | reaper.ImGui_TreeNodeFlags_Leaf()
      end
      if reaper.ImGui_TreeNodeFlags_NoTreePushOnOpen then
        flags = flags | reaper.ImGui_TreeNodeFlags_NoTreePushOnOpen()
      end
    end

    if app.library.folder_open_state[node.id] ~= nil and reaper.ImGui_SetNextItemOpen then
      reaper.ImGui_SetNextItemOpen(ctx, app.library.folder_open_state[node.id])
    end

    local is_open = false
    if reaper.ImGui_TreeNodeEx then
      is_open = reaper.ImGui_TreeNodeEx(ctx, "folder##" .. tostring(node.id), tostring(node.name or t("label.folder")), flags)
    else
      reaper.ImGui_Text(ctx, tostring(node.name or t("label.folder")))
      is_open = has_children
    end

    if app.library.folder_open_state[node.id] ~= is_open then
      app.library.folder_open_state[node.id] = is_open
      mark_settings_dirty()
    end
    SourcePane.draw_folder_context_menu(state, node)
    SourcePane.draw_folder_drag_source(node)
    SourcePane.accept_folder_drop_target(state, node.id)

    if is_open and has_children then
      for _, child_id in ipairs(node.folder_order) do
        local child = state.folder_lookup[child_id]
        if child then
          SourcePane.draw_folder_node(state, child)
        end
      end
      for _, entry in ipairs(node.sources) do
        SourcePane.draw_source_row(state, entry)
      end
      if reaper.ImGui_TreePop then
        reaper.ImGui_TreePop(ctx)
      end
    end
  end

  function SourcePane.draw_window_context_menu()
    if not (reaper.ImGui_BeginPopupContextWindow and reaper.ImGui_EndPopup) then
      return
    end

    local popup_flags = 0
    if reaper.ImGui_PopupFlags_MouseButtonRight then
      popup_flags = reaper.ImGui_PopupFlags_MouseButtonRight()
    end
    if reaper.ImGui_PopupFlags_NoOpenOverItems then
      popup_flags = popup_flags | reaper.ImGui_PopupFlags_NoOpenOverItems()
    end
    if reaper.ImGui_BeginPopupContextWindow(ctx, "library_empty_context", popup_flags) then
      if reaper.ImGui_MenuItem(ctx, t("menu.add_srt")) then
        prompt_add_srt()
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.new_folder")) then
        prompt_create_library_folder(nil)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.new_library")) then
        LibraryPane.prompt_create_library()
      end
      LibraryPane.draw_library_choice_menu(t("menu.add_selected_srts_to_library"), function(target_library_id)
        LibraryPane.add_selected_sources_to_library(target_library_id)
      end)
      if get_selected_source_count() > 0 and reaper.ImGui_MenuItem(ctx, t("menu.remove_selected_from_library")) then
        SourcePane.clear_selected_sources_from_library()
      end
      if reaper.ImGui_Separator then
        reaper.ImGui_Separator(ctx)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.expand_all")) then
        SourcePane.expand_all_library_folders(true)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.collapse_all")) then
        SourcePane.expand_all_library_folders(false)
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  function SourcePane.handle_root_drag_drop(state)
    if reaper.ImGui_BeginDragDropTarget
      and reaper.ImGui_AcceptDragDropPayload
      and reaper.ImGui_AcceptDragDropPayloadFiles
      and reaper.ImGui_GetDragDropPayloadFile
      and reaper.ImGui_EndDragDropTarget then
      local target_active = reaper.ImGui_BeginDragDropTarget(ctx)
      if target_active then
        local folder_accepted, folder_payload = reaper.ImGui_AcceptDragDropPayload(ctx, "SRT_LIBRARY_FOLDER")
        if (not state.internal_drop_handled) and folder_accepted and folder_payload and folder_payload ~= "" then
          state.internal_drop_handled = true
          local ok, message = move_library_folder(folder_payload, nil)
          app.ui.status = ok and t("status.moved_folder_to", SourcePane.get_folder_label(state, nil))
            or (message or t("status.failed_move_folder"))
        else
          local accepted, file_count = reaper.ImGui_AcceptDragDropPayloadFiles(ctx)
          if accepted then
            local dropped_paths = {}
            local ignored_count = 0

            for i = 0, (file_count or 0) - 1 do
              local ok, filename = reaper.ImGui_GetDragDropPayloadFile(ctx, i)
              if ok and filename and filename ~= "" then
                if is_srt_file_path(filename) then
                  dropped_paths[#dropped_paths + 1] = filename
                else
                  ignored_count = ignored_count + 1
                end
              end
            end

            if #dropped_paths > 0 then
              add_srt_paths_to_library(dropped_paths)
              if ignored_count > 0 then
                app.ui.status = t("status.ignored_non_srt_files", tostring(app.ui.status or ""), ignored_count)
              end
            else
              app.ui.status = t("status.no_srt_files_in_drop")
            end
          end
        end
        reaper.ImGui_EndDragDropTarget(ctx)
      end
    end
  end

  function SourcePane.draw_list()
    refresh_source_library_cache()

    reaper.ImGui_Text(ctx, t("pane.srt_library"))
    reaper.ImGui_Separator(ctx)

    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local changed, new_filter = reaper.ImGui_InputTextWithHint(
      ctx,
      "##source_filter",
      t("hint.source_filter"),
      tostring(app.library.source_filter or "")
    )
    if changed then
      app.library.source_filter = new_filter
    end

    local filtered_sources = SourcePane.get_filtered_library_sources()
    local state = {
      internal_drop_handled = false,
      any_source_hovered = false,
      folders_by_id = get_library_folder_lookup(app.settings.library_folders),
      folder_path_cache = {},
      filtered_sources = filtered_sources,
    }

    local child_visible = reaper.ImGui_BeginChild(
      ctx,
      "source_library_list",
      0,
      0,
      reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0,
      reaper.ImGui_WindowFlags_None and reaper.ImGui_WindowFlags_None() or 0
    )
    if child_visible then
      local font_small = get_font_small()
      local font_small_size = get_font_small_size()
      if font_small and reaper.ImGui_PushFont then
        reaper.ImGui_PushFont(ctx, font_small, font_small_size)
      end

      local child_hovered = reaper.ImGui_IsWindowHovered and reaper.ImGui_IsWindowHovered(ctx)
      if child_hovered and get_selected_source_count() > 0
        and reaper.ImGui_IsKeyPressed
        and reaper.ImGui_Key_Delete
        and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete(), false) then
        if SourcePane.clear_selected_sources_from_library() then
          refresh_source_library_cache()
          filtered_sources = SourcePane.get_filtered_library_sources()
          state.filtered_sources = filtered_sources
        end
      end

      local ctrl_down = false
      if reaper.ImGui_IsKeyDown and reaper.ImGui_Mod_Ctrl then
        ctrl_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
      end
      if ctrl_down
        and child_hovered
        and reaper.ImGui_IsKeyPressed
        and reaper.ImGui_Key_A
        and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_A(), false) then
        SourcePane.select_all_filtered_sources()
        app.ui.status = t("status.selected_srt_entries", get_selected_source_count())
      end

      local tree_root, folder_lookup = SourcePane.build_library_tree(filtered_sources)
      state.folder_lookup = folder_lookup

      local has_any_visible_entries = (#tree_root.sources > 0) or (#tree_root.folder_order > 0)
      if not has_any_visible_entries then
        if trim(app.library.source_filter or "") ~= "" then
          reaper.ImGui_TextWrapped(ctx, t("empty.no_source_matches"))
        else
          reaper.ImGui_TextWrapped(ctx, t("empty.no_source_available"))
          reaper.ImGui_TextWrapped(ctx, t("empty.drop_srt_here"))
        end
      else
        for _, child_id in ipairs(tree_root.folder_order) do
          local child = folder_lookup[child_id]
          if child then
            SourcePane.draw_folder_node(state, child)
          end
        end
        for _, entry in ipairs(tree_root.sources) do
          SourcePane.draw_source_row(state, entry)
        end
      end

      if not state.any_source_hovered then
        app.ui.source_tooltip_hovered_metadata_path = nil
        app.ui.source_tooltip_hover_started_at = nil
      end

      SourcePane.draw_window_context_menu()

      if font_small and reaper.ImGui_PopFont then
        reaper.ImGui_PopFont(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end

    SourcePane.handle_root_drag_drop(state)
  end
end
