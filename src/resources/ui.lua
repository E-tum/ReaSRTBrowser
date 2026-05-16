return {
  app = {
    name = "ReaSRTBrowser",
    id = "ReaSRTBrowser",
    window_title = "ReaSRTBrowser",
    default_language = "ja",
    fallback_language = "ja",
  },

  fonts = {
    default = {
      path = "C:\\Windows\\Fonts\\meiryo.ttc",
      size = 12,
    },
    small = {
      path = "C:\\Windows\\Fonts\\meiryo.ttc",
      size = 11,
    },
  },

  layout = {
    left_pane_width = 400,
    detail_pane_height = 130,
    max_detail_height = 360,
    min_source_width = 120,
    min_main_width = 420,
    splitter_width = 6,
    min_item_list_height = 180,
    min_detail_height = 100,
  },

  colors = {
    splitter_line = 0x66FFFFFF,
    splitter_line_active = 0x99FFFFFF,
  },

  tabs = {
    sources = "tab.sources",
    libraries = "tab.libraries",
  },

  top_bar_actions = {
    {
      action = "reload_library",
      label = "button.reload_library",
      visible_when = "library",
    },
  },

  main_menu = {
    {
      label = "menu.file",
      items = {
        { action = "add_srt", label = "menu.add_srt" },
        { action = "new_folder", label = "menu.new_folder" },
        { action = "new_library", label = "menu.new_library" },
        { action = "open_audio", label = "menu.open_audio" },
        { action = "reload_library", label = "menu.reload_library", visible_when = "library" },
        { type = "separator" },
        { action = "save_metadata", label = "menu.save_metadata", visible_when = "source" },
        { action = "clear_srt", label = "menu.clear_srt" },
      },
    },
    {
      label = "menu.edit",
      items = {
        { action = "insert_selected_items", label = "menu.insert_selected_items" },
        { action = "preview_selected_items", label = "menu.preview_selected_items" },
        { action = "favorite_selected_item", label = "menu.favorite_selected_item" },
        { action = "edit_selected_tags", label = "menu.edit_selected_tags" },
        { action = "remove_audio_binding", label = "menu.remove_audio_binding" },
        { type = "separator" },
        { action = "add_speaker_tags", label = "menu.add_speaker_tags", visible_when = "source" },
        { type = "separator", visible_when = "source" },
        { action = "apply_offset", label = "menu.apply_offset", visible_when = "source" },
        { action = "reset_offset", label = "menu.reset_offset", visible_when = "source" },
      },
    },
    {
      label = "menu.view",
      items = {
        { action = "toggle_edit_panel", label = "menu.toggle_edit_panel" },
      },
    },
    {
      label = "menu.settings",
      items = {
        { action = "set_preview_volume", label = "menu.preview_volume" },
        { action = "set_font_size", label = "menu.font_size" },
        { action = "set_font_path", label = "menu.font_path" },
        {
          label = "menu.language",
          items = {
            { action = "set_language_en", label = "menu.language_en" },
            { action = "set_language_ja", label = "menu.language_ja" },
          },
        },
        {
          label = "menu.search",
          items = {
            { action = "hide_search_history", label = "menu.hide_search_history", visible_when = "search_history_shown" },
            { action = "show_search_history", label = "menu.show_search_history", visible_when = "search_history_hidden" },
            { action = "clear_search_history", label = "menu.clear_search_history" },
          },
        },
      },
    },
  },

  item_table_columns = {
    source = {
      { key = "item.column.index", width_mode = "fixed", width = 60.0, no_hide = true },
      { key = "item.column.text", width_mode = "stretch", width = 0.5, no_hide = true },
      { key = "item.column.start", width_mode = "fixed", width = 90.0, no_hide = true },
      { key = "item.column.end", width_mode = "fixed", width = 90.0, no_hide = true },
      { key = "item.column.favorite_short", width_mode = "fixed", width = 45.0, no_hide = true },
      { key = "item.column.tags", width_mode = "stretch", width = 0.25, no_hide = false },
    },
    library = {
      { key = "item.column.srt", width_mode = "fixed", width = 160.0, no_hide = true },
      { key = "item.column.index", width_mode = "fixed", width = 60.0, no_hide = true },
      { key = "item.column.text", width_mode = "stretch", width = 0.5, no_hide = true },
      { key = "item.column.start", width_mode = "fixed", width = 90.0, no_hide = true },
      { key = "item.column.end", width_mode = "fixed", width = 90.0, no_hide = true },
      { key = "item.column.favorite_short", width_mode = "fixed", width = 45.0, no_hide = true },
      { key = "item.column.tags", width_mode = "stretch", width = 0.25, no_hide = false },
    },
  },
}
