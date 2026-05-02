local Core = require("reasrt.core")

local M = {}

local function load_language_bundle(script_dir, language)
  local path = Core.join_path(script_dir, "resources", "lang", tostring(language or "") .. ".lua")
  local chunk, err = loadfile(path)
  if not chunk then
    return nil, err
  end

  local ok, bundle = pcall(chunk)
  if not ok then
    return nil, bundle
  end

  if type(bundle) ~= "table" then
    return nil, "Language bundle must return a table."
  end

  return bundle
end

function M.create(options)
  options = options or {}

  local script_dir = options.script_dir or "./"
  local fallback_language = tostring(options.fallback_language or "en")
  local current_language = tostring(options.default_language or fallback_language)
  local cache = {}

  local function get_bundle(language)
    local key = tostring(language or "")
    if cache[key] ~= nil then
      return cache[key]
    end

    local bundle = load_language_bundle(script_dir, key)
    cache[key] = bundle or false
    return cache[key]
  end

  local function lookup(language, key)
    local bundle = get_bundle(language)
    if type(bundle) ~= "table" then
      return nil
    end
    return bundle[key]
  end

  local translator = {}

  function translator:set_language(language)
    local value = tostring(language or "")
    if value == "" then
      value = fallback_language
    end
    current_language = value
    return true
  end

  function translator:get_language()
    return current_language
  end

  function translator:t(key, ...)
    local template = lookup(current_language, key)
      or lookup(fallback_language, key)
      or tostring(key or "")

    if select("#", ...) > 0 then
      local ok, formatted = pcall(string.format, template, ...)
      if ok then
        return formatted
      end
    end

    return template
  end

  return translator
end

return M
