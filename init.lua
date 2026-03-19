local C = rawget(_G, "color_lib")
local signs_lib = rawget(_G, "signs_lib")
if type(signs_lib) ~= "table" then
    error("[holograms] missing required mod: signs_lib")
end

local MODNAME = minetest.get_current_modname()
local MODPATH = minetest.get_modpath(MODNAME)

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deepcopy(v)
    end
    return out
end

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local default_cfg = {
    max_visible_chars = 160,
    list_limit = 200,
    default_color = "#ffffff",
    allow_newlines = false,
    sprite_font_size = 32,
    text_force_unicode_font = false,
    text_char_spacing = 0,
    entity_visual_scale = 1.0,
    entity_glow = 0,
}

local function load_json_table(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local raw = file:read("*a")
    file:close()
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local parsed = minetest.parse_json(raw)
    if type(parsed) == "table" then
        return parsed
    end
    minetest.log("warning", "[holograms] invalid json in " .. tostring(path))
    return nil
end

local function load_config()
    local cfg = deepcopy(default_cfg)
    local loaded = load_json_table(MODPATH .. "/data/config.json")
    if type(loaded) == "table" then
        for k in pairs(default_cfg) do
            if loaded[k] ~= nil then
                cfg[k] = loaded[k]
            end
        end
    end

    cfg.max_visible_chars = math.max(1, math.floor(tonumber(cfg.max_visible_chars) or default_cfg.max_visible_chars))
    cfg.list_limit = math.max(1, math.floor(tonumber(cfg.list_limit) or default_cfg.list_limit))

    cfg.default_color = tostring(cfg.default_color or default_cfg.default_color)
    if not cfg.default_color:match("^#[%x][%x][%x][%x][%x][%x]$") then
        cfg.default_color = default_cfg.default_color
    else
        cfg.default_color = cfg.default_color:lower()
    end

    cfg.allow_newlines = cfg.allow_newlines == true

    cfg.sprite_font_size = math.floor(tonumber(cfg.sprite_font_size) or default_cfg.sprite_font_size)
    if cfg.sprite_font_size ~= 16 and cfg.sprite_font_size ~= 32 then
        cfg.sprite_font_size = default_cfg.sprite_font_size
    end

    cfg.text_force_unicode_font = cfg.text_force_unicode_font == true
    cfg.text_char_spacing = math.floor(tonumber(cfg.text_char_spacing) or default_cfg.text_char_spacing)
    cfg.text_char_spacing = math.max(-2, math.min(16, cfg.text_char_spacing))

    cfg.entity_visual_scale = tonumber(cfg.entity_visual_scale) or default_cfg.entity_visual_scale
    cfg.entity_visual_scale = math.max(0.1, math.min(2.0, cfg.entity_visual_scale))

    cfg.entity_glow = math.floor(tonumber(cfg.entity_glow) or default_cfg.entity_glow)
    cfg.entity_glow = math.max(0, math.min(8, cfg.entity_glow))

    return cfg
end

local function normalize_name(raw)
    local name = trim(raw)
    if name == "" then
        return nil
    end
    if not name:match("^[%w_%-]+$") then
        return nil
    end
    return name
end

local function key_for_name(name)
    return tostring(name or ""):lower()
end

local function unquote_text(raw)
    local text = trim(raw)
    if #text >= 2 then
        local first = text:sub(1, 1)
        local last = text:sub(-1)
        if (first == '"' and last == '"') or (first == "'" and last == "'") then
            return text:sub(2, -2)
        end
    end
    return text
end

local HM = {
    modpath = MODPATH,
    storage = minetest.get_mod_storage(),
    cfg = load_config(),
    storage_key = "holograms_v1",
    entity_name = MODNAME .. ":text",
    holograms = {},
    entities = {},
    texture_cache = {},
    texture_cache_count = 0,
    providers = {},
    provider_state = {},
    provider_result_hash = {},

    color_lib = C,
    signs_lib = signs_lib,

    COMMAND_NAME = "hologram",
    HOLOGRAM_OFFSET_Y = 1.0,
    HOLOGRAM_VISUAL = "sprite",
    MAX_HOLOGRAM_SCALE = 8,
    MAX_VISUAL_SIZE = 10,
    TEXT_CHARS_PER_LINE = 48,
    TEXT_HORIZ_SCALING = 1,
    TEXT_VERT_SCALING = 1,
    TEXT_MONOSPACE = false,

    trim = trim,
    normalize_name = normalize_name,
    key_for_name = key_for_name,
    unquote_text = unquote_text,
}

local API = rawget(_G, "holograms")
if type(API) ~= "table" then
    API = {}
end

minetest.log("action", "[holograms] signs_lib renderer active.")

dofile(MODPATH .. "/lib/renderer.lua")(HM)
dofile(MODPATH .. "/lib/core.lua")(HM, API)
dofile(MODPATH .. "/lib/commands.lua")(HM)

_G.holograms = API
