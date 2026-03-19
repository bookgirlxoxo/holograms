return function(HM)
    local cfg = HM.cfg
    local C = HM.color_lib
    local signs_lib = HM.signs_lib
    local trim = HM.trim

    local function local_read_hex_token(input, index)
        input = tostring(input or "")
        index = math.max(1, math.floor(tonumber(index) or 1))

        local t8 = input:sub(index, index + 7)
        local h8 = t8:match("^&#([%x][%x][%x][%x][%x][%x])$")
        if h8 then
            return "#" .. h8:lower(), 8
        end

        local t9 = input:sub(index, index + 8)
        local h9 = t9:match("^&#([%x][%x][%x][%x][%x][%x]);$")
        if h9 then
            return "#" .. h9:lower(), 9
        end

        local t10 = input:sub(index, index + 9)
        local h10 = t10:match("^<&#([%x][%x][%x][%x][%x][%x])>$")
        if h10 then
            return "#" .. h10:lower(), 10
        end

        local t11 = input:sub(index, index + 10)
        local h11 = t11:match("^<&#([%x][%x][%x][%x][%x][%x]);>$")
        if h11 then
            return "#" .. h11:lower(), 11
        end

        return nil, 0
    end

    local function read_hex_token(input, index)
        if C and type(C.read_hex_token) == "function" then
            local hex, step = C.read_hex_token(input, index, {case = "lower"})
            if hex then
                return hex, step
            end
        end
        return local_read_hex_token(input, index)
    end

    local function normalize_hex_color(raw)
        if C and type(C.parse_minecraft_hex_color) == "function" then
            local parsed = C.parse_minecraft_hex_color(raw)
            if parsed then
                return parsed
            end
        end
        local plain = tostring(raw or ""):match("^#([%x][%x][%x][%x][%x][%x])$")
        if plain then
            return "#" .. plain:lower()
        end
        return cfg.default_color
    end

    local function normalize_text_align(raw)
        local v = tostring(raw or ""):lower()
        if v == "center" then
            return "center"
        end
        if v == "right" then
            return "right"
        end
        return "left"
    end

    local function glyph_width(ch)
        local widths = (cfg.sprite_font_size == 32) and signs_lib.charwidth32 or signs_lib.charwidth16
        if type(widths) ~= "table" then
            return math.floor(cfg.sprite_font_size * 0.55)
        end
        return widths[ch] or widths["?"] or widths["_"] or math.floor(cfg.sprite_font_size * 0.55)
    end

    local function glyph_tex_name(ch)
        local byte = string.byte(ch)
        if not byte or byte < 32 or byte > 255 then
            byte = 95
        end
        return string.format("signs_lib_font_%dpx_%02x.png", cfg.sprite_font_size, byte)
    end

    local function parse_colored_glyphs(text_raw)
        local raw = tostring(text_raw or "")
        local out = {}
        local current = normalize_hex_color(cfg.default_color)
        local i = 1
        while i <= #raw do
            local hex, step = read_hex_token(raw, i)
            if step > 0 then
                current = normalize_hex_color(hex)
                i = i + step
            else
                local ch = raw:sub(i, i)
                if ch == "\r" then
                    if raw:sub(i + 1, i + 1) == "\n" then
                        i = i + 1
                    end
                    out[#out + 1] = {newline = true}
                    i = i + 1
                elseif ch == "\n" then
                    out[#out + 1] = {newline = true}
                    i = i + 1
                else
                    if ch == "\t" then
                        ch = " "
                    end
                    out[#out + 1] = {ch = ch, color = current, w = glyph_width(ch)}
                    i = i + 1
                end
            end
        end
        if #out == 0 then
            out[1] = {ch = " ", color = normalize_hex_color(cfg.default_color), w = glyph_width(" ")}
        end
        return out
    end

    local function validate_text(raw, opts)
        opts = type(opts) == "table" and opts or {}
        local allow_newlines = opts.allow_newlines == true or cfg.allow_newlines
        local text = tostring(raw or "")
        local color_renderer = (C and type(C.render_minecraft_hex_text) == "function") and C.render_minecraft_hex_text or nil
        if color_renderer then
            local _rendered, stored, err, _visible = color_renderer(text, {
                trim = true,
                allow_newlines = allow_newlines,
                max_visible = cfg.max_visible_chars,
            })
            if not stored then
                return nil, err or "Invalid text."
            end
            return stored, nil
        end

        local clean = trim(text)
        if not allow_newlines then
            clean = clean:gsub("[\r\n\t]", " ")
        end
        if clean == "" then
            return nil, "Text cannot be empty."
        end
        if #clean > cfg.max_visible_chars then
            return nil, "Text too long. Max " .. tostring(cfg.max_visible_chars) .. " visible characters."
        end
        return clean, nil
    end

    local function visible_text(entry)
        local raw = tostring(entry.text_raw or "")
        if C and type(C.strip_minecraft_hex_tokens) == "function" then
            return trim(C.strip_minecraft_hex_tokens(raw))
        end
        return trim(raw:gsub("[\r\n\t]", " "))
    end

    local function build_sprite_texture(text_raw, align)
        local align_mode = normalize_text_align(align)
        local cache_key = align_mode .. "\1" .. tostring(text_raw or "")
        local cached = HM.texture_cache[cache_key]
        if cached then
            return cached.texture, cached.w, cached.h
        end

        local glyphs = parse_colored_glyphs(text_raw)
        local avg = (cfg.sprite_font_size == 32) and (signs_lib.avgwidth32 or 16) or (signs_lib.avgwidth16 or 8)
        local max_w = math.max(64, math.floor(avg * math.max(1, HM.TEXT_CHARS_PER_LINE)))

        local mono_advance = nil
        if HM.TEXT_MONOSPACE then
            local widest = 1
            for i = 1, #glyphs do
                local g = glyphs[i]
                if not g.newline then
                    widest = math.max(widest, g.w or 1)
                end
            end
            mono_advance = math.max(1, widest + (cfg.text_char_spacing or 0))
        end

        local placed = {}
        local x = 0
        local line = 1
        local line_widths = {[1] = 0}
        local width = 0
        for i = 1, #glyphs do
            local g = glyphs[i]
            if g.newline then
                line_widths[line] = math.max(line_widths[line] or 0, x)
                line = line + 1
                x = 0
                line_widths[line] = line_widths[line] or 0
            else
                local cell_w = math.max(1, g.w + (cfg.text_char_spacing or 0))
                local draw_x = x
                if mono_advance then
                    cell_w = mono_advance
                    draw_x = x + math.max(0, math.floor((cell_w - g.w) / 2))
                end
                if (x + cell_w) > max_w then
                    line_widths[line] = math.max(line_widths[line] or 0, x)
                    line = line + 1
                    x = 0
                    line_widths[line] = line_widths[line] or 0
                    draw_x = x
                    if mono_advance then
                        draw_x = x + math.max(0, math.floor((cell_w - g.w) / 2))
                    end
                end
                placed[#placed + 1] = {
                    ch = g.ch,
                    color = g.color,
                    x = x,
                    y = (line - 1) * cfg.sprite_font_size,
                    w = cell_w,
                    draw_x = draw_x,
                    glyph_w = g.w,
                    line = line,
                }
                x = x + cell_w
                line_widths[line] = math.max(line_widths[line] or 0, x)
            end
        end

        if #placed == 0 then
            local sw = glyph_width(" ")
            local cell_w = mono_advance or math.max(1, sw + (cfg.text_char_spacing or 0))
            placed[1] = {
                ch = " ",
                color = normalize_hex_color(cfg.default_color),
                x = 0,
                y = 0,
                w = cell_w,
                draw_x = 0,
                glyph_w = sw,
                line = 1,
            }
            width = cell_w
            line_widths[1] = cell_w
        else
            line_widths[line] = math.max(line_widths[line] or 0, x)
            for _, lw in pairs(line_widths) do
                width = math.max(width, lw or 0)
            end
        end

        local height = math.max(cfg.sprite_font_size, line * cfg.sprite_font_size)
        width = math.max(1, width)
        local out_w = width
        local out_h = height
        local shift = 0
        local parts = {string.format("[combine:%dx%d", out_w, out_h)}

        for _, p in ipairs(placed) do
            if p.ch ~= " " then
                local line_w = line_widths[p.line] or width
                local line_shift = 0
                if align_mode == "center" then
                    line_shift = math.max(0, math.floor((width - line_w) / 2))
                elseif align_mode == "right" then
                    line_shift = math.max(0, width - line_w)
                end
                local fill_w = math.max(1, math.floor(p.glyph_w or p.w or 1))
                local col = normalize_hex_color(p.color):upper()
                local fill_tex = string.format(
                    "signs_lib_color_%dpx_F.png\\^[multiply\\:%s\\^[resize\\:%dx%d",
                    cfg.sprite_font_size,
                    col,
                    fill_w,
                    cfg.sprite_font_size
                )
                local draw_x = (p.draw_x or p.x or 0) + line_shift + shift
                local draw_y = (p.y or 0) + shift
                parts[#parts + 1] = string.format(":%d,%d=%s", draw_x, draw_y, fill_tex)
                parts[#parts + 1] = string.format(":%d,%d=%s", draw_x, draw_y, glyph_tex_name(p.ch))
            end
        end

        parts[#parts + 1] = "^[makealpha:0,0,0"

        local texture = table.concat(parts)
        HM.texture_cache[cache_key] = {texture = texture, w = out_w, h = out_h}
        HM.texture_cache_count = HM.texture_cache_count + 1
        if HM.texture_cache_count > 512 then
            HM.texture_cache = {}
            HM.texture_cache_count = 0
        end

        return texture, out_w, out_h
    end

    HM.renderer = {
        normalize_hex_color = normalize_hex_color,
        normalize_text_align = normalize_text_align,
        validate_text = validate_text,
        visible_text = visible_text,
        build_sprite_texture = build_sprite_texture,
    }
end
