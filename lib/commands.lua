return function(HM)
    local ops = HM.ops or {}
    local renderer = HM.renderer or {}
    local COMMAND_NAME = HM.COMMAND_NAME

    local upsert_hologram_entry = ops.upsert_hologram_entry
    local remove_hologram_entry = ops.remove_hologram_entry
    local set_hologram_scale = ops.set_hologram_scale
    local visible_text = renderer.visible_text

    if type(upsert_hologram_entry) ~= "function"
        or type(remove_hologram_entry) ~= "function"
        or type(set_hologram_scale) ~= "function"
        or type(visible_text) ~= "function" then
        error("[holograms] core module not initialized")
    end

    local trim = HM.trim
    local normalize_name = HM.normalize_name
    local unquote_text = HM.unquote_text
    local cfg = HM.cfg

    local function admin_only(name)
        if minetest.check_player_privs(name, {server = true}) then
            return true
        end
        return false, "Hologram CLI is admin only."
    end

    local function parse_axis_token(token, base_value)
        local t = trim(token)
        if t == "" then
            return nil, "Invalid coordinate."
        end

        if t == "~" then
            if base_value == nil then
                return nil, "Relative coordinates require an in-game player sender."
            end
            return base_value, nil
        end

        local rel = t:match("^~([+-]?%d*%.?%d+)$")
        if rel then
            local offset = tonumber(rel)
            if not offset then
                return nil, "Invalid relative coordinate '" .. t .. "'."
            end
            if base_value == nil then
                return nil, "Relative coordinates require an in-game player sender."
            end
            return base_value + offset, nil
        end

        local abs = tonumber(t)
        if not abs then
            return nil, "Invalid coordinate '" .. t .. "'."
        end
        return abs, nil
    end

    local function get_facing_base_pos(player)
        if not player or not player:is_player() then
            return nil
        end
        local ppos = player:get_pos()
        if type(ppos) ~= "table" then
            return nil
        end

        local props = player:get_properties() or {}
        local eye_h = tonumber(props.eye_height) or 1.47
        local eye = {x = ppos.x, y = ppos.y + eye_h, z = ppos.z}
        local dir = player:get_look_dir() or {x = 0, y = 0, z = 1}
        local reach = tonumber(minetest.settings:get("default_reach")) or 6
        local target = vector.add(eye, vector.multiply(dir, reach))

        local ray = minetest.raycast(eye, target, false, false)
        for pointed in ray do
            if pointed and pointed.type == "node" and pointed.above then
                local hit = vector.new(pointed.above)
                return {x = hit.x + 0.5, y = hit.y + 0.5, z = hit.z + 0.5}
            elseif pointed and pointed.type == "object" and pointed.ref then
                local op = pointed.ref:get_pos()
                if type(op) == "table" then
                    return vector.new(op)
                end
            end
        end

        return {
            x = ppos.x + (dir.x * 2),
            y = ppos.y + 1,
            z = ppos.z + (dir.z * 2),
        }
    end

    local function parse_pos_token(raw, player)
        local spec = trim(raw):gsub("%s+", "")
        if spec:lower() == "here" then
            local base = get_facing_base_pos(player)
            if not base then
                return nil, "The 'here' position token requires an in-game player sender."
            end
            return base, nil
        end
        if spec:sub(1, 1) == "(" and spec:sub(-1) == ")" then
            spec = spec:sub(2, -2)
        end

        local xraw, yraw, zraw = spec:match("^([^,]+),([^,]+),([^,]+)$")
        if not xraw or not yraw or not zraw then
            return nil, "Invalid position format. Use here, x,y,z or ~,~,~."
        end

        local base = get_facing_base_pos(player)

        local x, ex = parse_axis_token(xraw, base and base.x or nil)
        if not x then
            return nil, ex
        end
        local y, ey = parse_axis_token(yraw, base and base.y or nil)
        if not y then
            return nil, ey
        end
        local z, ez = parse_axis_token(zraw, base and base.z or nil)
        if not z then
            return nil, ez
        end

        return {x = x, y = y, z = z}, nil
    end

    local function cmd_add(caller_name, args)
        local holo_name, pos_token, text = tostring(args or ""):match("^%s*(%S+)%s+(%S+)%s+(.+)%s*$")
        if not holo_name then
            return false, "Usage: /" .. COMMAND_NAME .. " add <name> <here|x,y,z|~,~,~|~,~2,~4> <text>"
        end

        holo_name = normalize_name(holo_name)
        if not holo_name then
            return false, "Invalid hologram name. Use letters, numbers, _ or -."
        end
        if HM.holograms[HM.key_for_name(holo_name)] then
            return false, "Hologram name already exists: " .. holo_name
        end

        local caller = minetest.get_player_by_name(caller_name)
        local pos, pos_err = parse_pos_token(pos_token, caller)
        if not pos then
            return false, pos_err or "Invalid position."
        end

        local entry, upsert_err = upsert_hologram_entry(holo_name, pos, unquote_text(text), {persist = true})
        if not entry then
            return false, upsert_err or "Failed to save hologram."
        end

        return true, string.format("Hologram '%s' saved at (%.2f, %.2f, %.2f).", holo_name, pos.x, pos.y, pos.z)
    end

    local function cmd_list()
        local names = {}
        for key, entry in pairs(HM.holograms) do
            if type(entry) == "table" and entry.transient ~= true then
                names[#names + 1] = {key = key, entry = entry}
            end
        end
        table.sort(names, function(a, b)
            return a.entry.name:lower() < b.entry.name:lower()
        end)

        if #names == 0 then
            return true, "No holograms found."
        end

        local lines = {}
        local max_lines = math.min(#names, cfg.list_limit)
        for i = 1, max_lines do
            local entry = names[i].entry
            local pos = entry.pos
            lines[#lines + 1] = string.format(
                "%d. %s @ (%.2f, %.2f, %.2f) x%.2f -> %s",
                i,
                entry.name,
                tonumber(pos.x) or 0,
                tonumber(pos.y) or 0,
                tonumber(pos.z) or 0,
                tonumber(entry.scale) or 1.0,
                visible_text(entry)
            )
        end
        if #names > max_lines then
            lines[#lines + 1] = "... and " .. tostring(#names - max_lines) .. " more."
        end

        return true, table.concat(lines, "\n")
    end

    local function cmd_delete(args)
        local name = normalize_name(args)
        if not name then
            return false, "Usage: /" .. COMMAND_NAME .. " delete <name>"
        end

        local ok, err, entry = remove_hologram_entry(name, {persist = true})
        if not ok then
            return false, err
        end
        return true, "Deleted hologram '" .. entry.name .. "'."
    end

    local function cmd_size(args)
        local name_raw, scale_raw = tostring(args or ""):match("^%s*(%S+)%s+(%S+)%s*$")
        if not name_raw or not scale_raw then
            return false, "Usage: /" .. COMMAND_NAME .. " size <name> <scale>"
        end

        local name = normalize_name(name_raw)
        if not name then
            return false, "Invalid hologram name."
        end

        local scale = tonumber(scale_raw)
        if not scale then
            return false, "Scale must be a number."
        end

        local ok, err, entry = set_hologram_scale(name, scale, {persist = true})
        if not ok then
            return false, err
        end

        return true, string.format("Hologram '%s' scale set to %.2f.", entry.name, tonumber(entry.scale) or scale)
    end

    local function cmd_move(caller_name, args)
        local name_raw, pos_raw = tostring(args or ""):match("^%s*(%S+)%s*(.-)%s*$")
        if not name_raw or name_raw == "" then
            return false, "Usage: /" .. COMMAND_NAME .. " move <name> [here|x,y,z|~,~,~|~,~2,~4]"
        end

        local name = normalize_name(name_raw)
        if not name then
            return false, "Invalid hologram name."
        end

        local key = HM.key_for_name(name)
        local entry = HM.holograms[key]
        if type(entry) ~= "table" then
            return false, "Hologram not found: " .. name
        end

        local caller = minetest.get_player_by_name(caller_name)
        local pos = nil
        if trim(pos_raw or "") == "" then
            if not caller or not caller:is_player() then
                return false, "Empty coordinates require an in-game player sender."
            end
            local p = caller:get_pos() or {}
            pos = {
                x = tonumber(p.x) or 0,
                y = tonumber(p.y) or 0,
                z = tonumber(p.z) or 0,
            }
        else
            local pos_err = nil
            pos, pos_err = parse_pos_token(pos_raw, caller)
            if not pos then
                return false, pos_err or "Invalid position."
            end
        end

        local moved, err = upsert_hologram_entry(name, pos, entry.text_raw, {
            persist = true,
            scale = entry.scale,
            align = entry.align,
            allow_newlines = true,
        })
        if not moved then
            return false, err or "Failed to move hologram."
        end

        return true, string.format("Moved hologram '%s' to (%.2f, %.2f, %.2f).", moved.name, pos.x, pos.y, pos.z)
    end

    local function cmd_edit(args)
        local name_raw, text = tostring(args or ""):match("^%s*(%S+)%s+(.+)%s*$")
        if not name_raw or not text then
            return false, "Usage: /" .. COMMAND_NAME .. " edit <name> <text>"
        end

        local name = normalize_name(name_raw)
        if not name then
            return false, "Invalid hologram name."
        end

        local key = HM.key_for_name(name)
        local entry = HM.holograms[key]
        if type(entry) ~= "table" then
            return false, "Hologram not found: " .. name
        end

        local updated, err = upsert_hologram_entry(name, entry.pos, unquote_text(text), {
            persist = true,
            scale = entry.scale,
            align = entry.align,
            allow_newlines = true,
        })
        if not updated then
            return false, err or "Failed to edit hologram."
        end

        return true, "Edited hologram '" .. updated.name .. "'."
    end

    local function hologram_help()
        return table.concat({
            "Usage:",
            "/" .. COMMAND_NAME .. " add <name> <here|x,y,z|~,~,~|~,~2,~4> <text>",
            "/" .. COMMAND_NAME .. " move <name> [here|x,y,z|~,~,~|~,~2,~4]",
            "/" .. COMMAND_NAME .. " edit <name> <text>",
            "/" .. COMMAND_NAME .. " list",
            "/" .. COMMAND_NAME .. " delete <name>",
            "/" .. COMMAND_NAME .. " size <name> <scale>",
        }, "\n")
    end

    local function hologram_command(name, param)
        local ok, err = admin_only(name)
        if not ok then
            return false, err
        end

        local subcmd, rest = tostring(param or ""):match("^%s*(%S+)%s*(.-)%s*$")
        subcmd = tostring(subcmd or ""):lower()

        if subcmd == "" or subcmd == "help" then
            return true, hologram_help()
        elseif subcmd == "add" then
            return cmd_add(name, rest)
        elseif subcmd == "move" then
            return cmd_move(name, rest)
        elseif subcmd == "edit" then
            return cmd_edit(rest)
        elseif subcmd == "list" then
            return cmd_list()
        elseif subcmd == "delete" then
            return cmd_delete(rest)
        elseif subcmd == "size" then
            return cmd_size(rest)
        end

        return false, "unknown subcommand. Use /" .. COMMAND_NAME .. " help."
    end

    minetest.register_chatcommand(COMMAND_NAME, {
        params = "add <name> <here|x,y,z|~,~,~|~,~2,~4> <text> | move <name> [here|x,y,z|~,~,~|~,~2,~4] | edit <name> <text> | list | delete <name> | size <name> <scale>",
        description = "admin hologram management",
        func = hologram_command,
    })
end
