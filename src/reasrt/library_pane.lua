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
  local SourcePane = env.SourcePane
  local LibraryPane = env.LibraryPane
  local LibraryStore = env.LibraryStore
  local set_single_source_selection = env.set_single_source_selection
  local load_source_entry = env.load_source_entry

  function LibraryPane.draw_library_choice_menu(menu_label, on_pick, options)
    options = options or {}
    if not (reaper.ImGui_BeginMenu and reaper.ImGui_EndMenu and reaper.ImGui_MenuItem) then
      return
    end

    if not reaper.ImGui_BeginMenu(ctx, menu_label) then
      return
    end

    local entries = LibraryStore.normalize_entries(app.user_libraries.entries)
    for _, entry in ipairs(entries) do
      if reaper.ImGui_MenuItem(ctx, tostring(entry.name or t("label.library"))) then
        on_pick(entry.id)
      end
    end

    if #entries == 0 and reaper.ImGui_MenuItem(ctx, t("empty.no_libraries_menu")) then
    end

    reaper.ImGui_EndMenu(ctx)
  end

  function LibraryPane.prompt_create_library()
    if not reaper.GetUserInputs then
      app.ui.status = t("status.library_creation_unavailable")
      return false
    end

    local ok, value = reaper.GetUserInputs(t("prompt.new_library"), 1, t("prompt.library_name"), "")
    if not ok then
      app.ui.status = t("status.new_library_canceled")
      return false
    end

    local created, library_id_or_err = LibraryStore.create(value)
    if not created then
      app.ui.status = library_id_or_err or t("status.failed_create_library")
      return false
    end

    app.ui.status = t("status.created_library", LibraryPane.get_library_display_name(library_id_or_err))
    return true
  end

  function LibraryPane.prompt_rename_library(library_id)
    local library = LibraryStore.get_by_id(library_id)
    if not library then
      app.ui.status = t("status.library_not_found")
      return false
    end

    if not reaper.GetUserInputs then
      app.ui.status = t("status.library_rename_unavailable")
      return false
    end

    local ok, value = reaper.GetUserInputs(t("prompt.rename_library"), 1, t("prompt.library_name"), tostring(library.name or ""))
    if not ok then
      app.ui.status = t("status.rename_library_canceled")
      return false
    end

    local renamed, err = LibraryStore.rename(library_id, value)
    if not renamed then
      app.ui.status = err or t("status.failed_rename_library")
      return false
    end

    app.ui.status = t("status.renamed_library", LibraryPane.get_library_display_name(library_id))
    return true
  end

  function LibraryPane.add_selected_sources_to_library(library_id)
    local metadata_paths = SourcePane.get_selected_metadata_paths_list()
    if #metadata_paths == 0 then
      app.ui.status = t("status.no_srt_selected_source_list")
      return false
    end

    local ok, added_or_err = LibraryStore.add_sources(library_id, metadata_paths)
    if not ok then
      app.ui.status = added_or_err or t("status.failed_add_srts_to_library")
      return false
    end

    app.user_libraries.selected_library_id = library_id
    app.ui.status = t("status.added_srt_entries_to_library", added_or_err, LibraryPane.get_library_display_name(library_id))
    return true
  end

  function LibraryPane.remove_member_from_library(library_id, metadata_path)
    local ok, removed_or_err = LibraryStore.remove_sources(library_id, { metadata_path })
    if not ok then
      app.ui.status = removed_or_err or t("status.failed_remove_srt_from_library")
      return false
    end

    if app.ui.content_mode == "library" and app.ui.active_library_id == library_id then
      LibraryPane.reload_active_view({
        reset_filters = false,
      })
    end

    app.ui.status = t("status.removed_srt_from_library", LibraryPane.get_library_display_name(library_id))
    return true
  end

  function LibraryPane.draw_member_context_menu(library_id, source_entry)
    if not source_entry or not source_entry.metadata_path then
      return
    end
    if not (reaper.ImGui_BeginPopupContextItem and reaper.ImGui_EndPopup) then
      return
    end

    if reaper.ImGui_BeginPopupContextItem(ctx, "library_member_context##" .. tostring(library_id) .. "##" .. tostring(source_entry.metadata_path)) then
      if reaper.ImGui_MenuItem(ctx, t("menu.open_srt")) then
        set_single_source_selection(source_entry.metadata_path)
        load_source_entry(source_entry)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.remove_from_library")) then
        LibraryPane.remove_member_from_library(library_id, source_entry.metadata_path)
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  function LibraryPane.draw_library_context_menu(library_id)
    if not (reaper.ImGui_BeginPopupContextItem and reaper.ImGui_EndPopup) then
      return
    end

    if reaper.ImGui_BeginPopupContextItem(ctx, "library_context##" .. tostring(library_id)) then
      if reaper.ImGui_MenuItem(ctx, t("menu.open_library")) then
        LibraryPane.load_view(library_id)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.rename_library")) then
        LibraryPane.prompt_rename_library(library_id)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.delete_library")) then
        local ok, name_or_err = LibraryStore.delete(library_id)
        app.ui.status = ok and t("status.deleted_library", tostring(name_or_err))
          or (name_or_err or t("status.failed_delete_library"))
      end
      if reaper.ImGui_Separator then
        reaper.ImGui_Separator(ctx)
      end
      if reaper.ImGui_MenuItem(ctx, t("menu.add_selected_srts_here")) then
        LibraryPane.add_selected_sources_to_library(library_id)
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  function LibraryPane.draw_window_context_menu()
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
    if reaper.ImGui_BeginPopupContextWindow(ctx, "libraries_empty_context", popup_flags) then
      if reaper.ImGui_MenuItem(ctx, t("menu.new_library")) then
        LibraryPane.prompt_create_library()
      end
      LibraryPane.draw_library_choice_menu(t("menu.add_selected_srts_to_library"), function(target_library_id)
        LibraryPane.add_selected_sources_to_library(target_library_id)
      end)
      reaper.ImGui_EndPopup(ctx)
    end
  end

  function LibraryPane.draw_list()
    LibraryStore.initialize_state()

    reaper.ImGui_Text(ctx, t("pane.libraries"))
    reaper.ImGui_Separator(ctx)

    local child_visible = reaper.ImGui_BeginChild(
      ctx,
      "user_libraries_list",
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

      local entries = LibraryStore.normalize_entries(app.user_libraries.entries)
      if #entries == 0 then
        reaper.ImGui_TextWrapped(ctx, t("empty.no_libraries_available"))
        reaper.ImGui_TextWrapped(ctx, t("empty.use_context_menu_library"))
      else
        for _, entry in ipairs(entries) do
          local selected = app.user_libraries.selected_library_id == entry.id
          local label = tostring(entry.name or t("label.library")) .. "##library_row_" .. tostring(entry.id)
          if reaper.ImGui_Selectable(ctx, label, selected) then
            app.user_libraries.selected_library_id = entry.id
            if not (app.ui.content_mode == "library" and app.ui.active_library_id == entry.id) then
              LibraryPane.load_view(entry.id)
            end
          end
          LibraryPane.draw_library_context_menu(entry.id)
        end
      end

      LibraryPane.draw_window_context_menu()

      if font_small and reaper.ImGui_PopFont then
        reaper.ImGui_PopFont(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end
  end
end
