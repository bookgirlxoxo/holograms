return function(HM, API)
    local renderer = HM.renderer or {}
    local normalize_text_align = renderer.normalize_text_align
    local build_sprite_texture = renderer.build_sprite_texture
    local validate_text = renderer.validate_text

    if type(normalize_text_align) ~= "function"
        or type(build_sprite_texture) ~= "function"
        or type(validate_text) ~= "function" then
        error("[holograms] renderer module not initialized")
    end

    local storage = HM.storage
    local cfg = HM.cfg
    local normalize_name = HM.normalize_name
    local key_for_name = HM.key_for_name

    local function save_holograms()
        local persist_rows = {}
        for key, entry in pairs(HM.holograms) do
            if type(entry) == "table" and entry.transient ~= true then
                persist_rows[key] = {
                    name = entry.name,
                    pos = entry.pos,
                    text_raw = entry.text_raw,
                    scale = entry.scale,
                    revision = entry.revision,
                    align = normalize_text_align(entry.align),
                }
            end
        end
        storage:set_string(HM.storage_key, minetest.serialize(persist_rows))
    end

    local function load_holograms()
        local raw = storage:get_string(HM.storage_key)
        if raw == "" then
            HM.holograms = {}
            return
        end

        local decoded = minetest.deserialize(raw)
        if type(decoded) ~= "table" then
            HM.holograms = {}
            return
        end

        local out = {}
        for key, entry in pairs(decoded) do
            if type(entry) == "table" and type(entry.pos) == "table" then
                local name = normalize_name(entry.name or key)
                local x = tonumber(entry.pos.x)
                local y = tonumber(entry.pos.y)
                local z = tonumber(entry.pos.z)
                local text_raw = tostring(entry.text_raw or "")
                if name and x and y and z and text_raw ~= "" then
                    local scale = tonumber(entry.scale) or 1.0
                    if scale <= 0 then
                        scale = 1.0
                    end
                    scale = math.min(scale, HM.MAX_HOLOGRAM_SCALE)
                    local normalized_key = key_for_name(name)
                    out[normalized_key] = {
                        name = name,
                        pos = {x = x, y = y, z = z},
                        text_raw = text_raw,
                        scale = scale,
                        revision = math.max(1, math.floor(tonumber(entry.revision) or 1)),
                        align = normalize_text_align(entry.align),
                        transient = false,
                    }
                end
            end
        end

        HM.holograms = out
    end

    local function object_is_valid(obj)
        if not obj then
            return false
        end
        local ok, luaent = pcall(function()
            return obj:get_luaentity()
        end)
        return ok and type(luaent) == "table"
    end

    local function register_entity_ref(key, obj)
        if object_is_valid(HM.entities[key]) and HM.entities[key] ~= obj then
            local old = HM.entities[key]
            pcall(function()
                old:remove()
            end)
        end
        HM.entities[key] = obj
    end

    local function apply_entry_to_object(obj, key, entry)
        if not object_is_valid(obj) then
            return false
        end

        local texture, tex_w, tex_h = build_sprite_texture(entry.text_raw, entry.align)
        local scale_mul = tonumber(entry.scale) or 1.0
        if scale_mul <= 0 then
            scale_mul = 1.0
        end
        scale_mul = math.min(scale_mul, HM.MAX_HOLOGRAM_SCALE)
        local scale_y = cfg.entity_visual_scale * scale_mul * HM.TEXT_VERT_SCALING
        scale_y = math.max(0.05, math.min(HM.MAX_VISUAL_SIZE, scale_y))
        local scale_x = (scale_y * (tex_w / math.max(1, tex_h))) * HM.TEXT_HORIZ_SCALING
        scale_x = math.max(0.1, math.min(HM.MAX_VISUAL_SIZE, scale_x))

        local pos = vector.new(entry.pos)
        pos.y = pos.y + HM.HOLOGRAM_OFFSET_Y

        obj:set_properties({
            visual = HM.HOLOGRAM_VISUAL,
            textures = {texture},
            visual_size = {x = scale_x, y = scale_y},
            glow = cfg.entity_glow,
        })
        obj:set_nametag_attributes({
            text = "",
            bgcolor = "#00000000",
        })
        obj:set_pos(pos)

        local luaent = obj:get_luaentity()
        if luaent then
            luaent.holo_key = key
            luaent.revision = entry.revision
        end

        register_entity_ref(key, obj)
        return true
    end

    local function spawn_or_update_entity(key)
        local entry = HM.holograms[key]
        if not entry then
            return false
        end

        local existing = HM.entities[key]
        if object_is_valid(existing) then
            return apply_entry_to_object(existing, key, entry)
        end

        local spawn_pos = vector.new(entry.pos)
        spawn_pos.y = spawn_pos.y + HM.HOLOGRAM_OFFSET_Y
        local staticdata = minetest.serialize({
            key = key,
            revision = entry.revision,
        })

        local obj = minetest.add_entity(spawn_pos, HM.entity_name, staticdata)
        if not obj then
            return false
        end

        return apply_entry_to_object(obj, key, entry)
    end

    local function delete_entity(key)
        local obj = HM.entities[key]
        if object_is_valid(obj) then
            pcall(function()
                obj:remove()
            end)
        end
        HM.entities[key] = nil
    end

    minetest.register_entity(HM.entity_name, {
        initial_properties = {
            physical = false,
            collide_with_objects = false,
            collisionbox = {0, 0, 0, 0, 0, 0},
            selectionbox = {0, 0, 0, 0, 0, 0},
            pointable = false,
            visual = HM.HOLOGRAM_VISUAL,
            textures = {"blank.png"},
            visual_size = {x = 0.1, y = 0.1},
            glow = cfg.entity_glow,
            static_save = true,
        },

        holo_key = nil,
        revision = nil,

        on_activate = function(self, staticdata, _dtime_s)
            local parsed = minetest.deserialize(staticdata or "")
            if type(parsed) == "table" then
                self.holo_key = parsed.key
                self.revision = tonumber(parsed.revision)
            end

            local key = self.holo_key
            if not key then
                self.object:remove()
                return
            end

            local entry = HM.holograms[key]
            if not entry then
                self.object:remove()
                return
            end

            if tonumber(self.revision) ~= tonumber(entry.revision) then
                self.object:remove()
                return
            end

            apply_entry_to_object(self.object, key, entry)
        end,

        get_staticdata = function(self)
            return minetest.serialize({
                key = self.holo_key,
                revision = self.revision,
            })
        end,

        on_deactivate = function(self)
            if self.holo_key and HM.entities[self.holo_key] == self.object then
                HM.entities[self.holo_key] = nil
            end
        end,
    })

    local function sanitize_pos(raw_pos)
        local pos = type(raw_pos) == "table" and raw_pos or nil
        if not pos then
            return nil, "Position is required."
        end
        local x = tonumber(pos.x)
        local y = tonumber(pos.y)
        local z = tonumber(pos.z)
        if not x or not y or not z then
            return nil, "Position must include numeric x/y/z."
        end
        return {x = x, y = y, z = z}, nil
    end

    local function normalize_scale(raw, fallback)
        local scale = tonumber(raw)
        if not scale then
            scale = tonumber(fallback) or 1.0
        end
        if scale <= 0 then
            scale = 1.0
        end
        return math.max(0.1, math.min(HM.MAX_HOLOGRAM_SCALE, scale))
    end

    local function upsert_hologram_entry(raw_name, raw_pos, raw_text, opts)
        opts = type(opts) == "table" and opts or {}
        local persist = opts.persist ~= false

        local name = normalize_name(raw_name)
        if not name then
            return nil, "Invalid hologram name. Use letters, numbers, _ or -."
        end

        local pos, pos_err = sanitize_pos(raw_pos)
        if not pos then
            return nil, pos_err or "Invalid position."
        end

        local stored, text_err = validate_text(raw_text, opts)
        if not stored then
            return nil, text_err or "Invalid text."
        end

        local key = key_for_name(name)
        local previous = HM.holograms[key]
        local revision = 1
        if type(previous) == "table" then
            revision = math.max(1, math.floor(tonumber(previous.revision) or 1) + 1)
            delete_entity(key)
        end

        HM.holograms[key] = {
            name = name,
            pos = pos,
            text_raw = stored,
            scale = normalize_scale(opts.scale, previous and previous.scale or 1.0),
            revision = revision,
            align = normalize_text_align(opts.align or (previous and previous.align) or "left"),
            transient = not persist,
        }

        if persist then
            save_holograms()
        end
        spawn_or_update_entity(key)
        return HM.holograms[key], nil
    end

    local function remove_hologram_entry(raw_name, opts)
        opts = type(opts) == "table" and opts or {}
        local persist = opts.persist ~= false
        local allow_missing = opts.allow_missing == true

        local name = normalize_name(raw_name)
        if not name then
            return false, "Invalid hologram name."
        end

        local key = key_for_name(name)
        local entry = HM.holograms[key]
        if not entry then
            if allow_missing then
                return true, nil
            end
            return false, "Hologram not found: " .. name
        end

        HM.holograms[key] = nil
        if persist then
            save_holograms()
        end
        delete_entity(key)
        return true, nil, entry
    end

    local function set_hologram_scale(raw_name, scale, opts)
        opts = type(opts) == "table" and opts or {}
        local persist = opts.persist ~= false

        local name = normalize_name(raw_name)
        if not name then
            return false, "Invalid hologram name."
        end

        local key = key_for_name(name)
        local entry = HM.holograms[key]
        if not entry then
            return false, "Hologram not found: " .. name
        end

        entry.scale = normalize_scale(scale, entry.scale)
        entry.revision = math.max(1, math.floor(tonumber(entry.revision) or 1) + 1)
        HM.holograms[key] = entry

        if persist then
            save_holograms()
        end
        delete_entity(key)
        spawn_or_update_entity(key)
        return true, nil, entry
    end

    local function provider_name_component(raw)
        local s = tostring(raw or ""):lower():gsub("[^%w_%-]", "_")
        s = s:gsub("_+", "_")
        s = HM.trim(s)
        if s == "" then
            s = "provider"
        end
        return s
    end

    local function provider_default_holo_name(provider_id, player_name)
        return "dyn_" .. provider_name_component(provider_id) .. "_" .. provider_name_component(player_name)
    end

    local function run_provider_for_player(provider_id, provider, player)
        if not player or not player.is_player or not player:is_player() then
            return
        end
        if type(provider) ~= "table" or type(provider.for_player) ~= "function" then
            return
        end

        local pname = player:get_player_name()
        HM.provider_state[provider_id] = HM.provider_state[provider_id] or {}
        HM.provider_result_hash[provider_id] = HM.provider_result_hash[provider_id] or {}
        local state = HM.provider_state[provider_id]
        local hash_state = HM.provider_result_hash[provider_id]
        local previous_name = state[pname]

        local ok, result = pcall(provider.for_player, player)
        if not ok then
            minetest.log("error", "[holograms] provider '" .. tostring(provider_id) .. "' failed for " .. pname .. ": " .. tostring(result))
            if previous_name then
                remove_hologram_entry(previous_name, {persist = false, allow_missing = true})
                state[pname] = nil
                hash_state[pname] = nil
            end
            return
        end

        if type(result) ~= "table" or result.enabled == false then
            if previous_name then
                remove_hologram_entry(previous_name, {persist = false, allow_missing = true})
                state[pname] = nil
                hash_state[pname] = nil
            end
            return
        end

        local desired_name = normalize_name(result.name or result.key or "")
        if not desired_name then
            desired_name = provider_default_holo_name(provider_id, pname)
        end

        local pos = type(result.pos) == "table" and result.pos or {}
        local function fmt_sig_num(v)
            return string.format("%.3f", tonumber(v) or 0)
        end

        local result_sig = table.concat({
            desired_name,
            fmt_sig_num(pos.x),
            fmt_sig_num(pos.y),
            fmt_sig_num(pos.z),
            tostring(result.text or ""),
            string.format("%.3f", tonumber(result.scale) or 1),
            normalize_text_align(result.align),
            result.allow_newlines == true and "1" or "0",
        }, "\1")

        if previous_name == desired_name and hash_state[pname] == result_sig then
            return
        end

        local entry, upsert_err = upsert_hologram_entry(desired_name, result.pos, result.text, {
            persist = false,
            scale = result.scale,
            align = result.align,
            allow_newlines = result.allow_newlines == true,
        })
        if not entry then
            minetest.log("warning", "[holograms] provider '" .. tostring(provider_id) .. "' skipped update for " .. pname .. ": " .. tostring(upsert_err))
            if previous_name then
                remove_hologram_entry(previous_name, {persist = false, allow_missing = true})
                state[pname] = nil
                hash_state[pname] = nil
            end
            return
        end

        if previous_name and previous_name ~= desired_name then
            remove_hologram_entry(previous_name, {persist = false, allow_missing = true})
        end
        state[pname] = desired_name
        hash_state[pname] = result_sig
    end

    local function run_provider_tick(provider_id, provider, only_player)
        if not only_player then
            for _, player in ipairs(minetest.get_connected_players()) do
                run_provider_for_player(provider_id, provider, player)
            end
            return
        end

        local player = only_player
        if type(only_player) == "string" then
            player = minetest.get_player_by_name(only_player)
        end
        if player and player.is_player and player:is_player() then
            run_provider_for_player(provider_id, provider, player)
        end
    end

    local function unregister_provider(provider_id)
        local id = tostring(provider_id or "")
        if id == "" then
            return false, "Provider id is required."
        end

        local state = HM.provider_state[id]
        if type(state) == "table" then
            for _, holo_name in pairs(state) do
                remove_hologram_entry(holo_name, {persist = false, allow_missing = true})
            end
        end
        HM.provider_state[id] = nil
        HM.providers[id] = nil
        HM.provider_result_hash[id] = nil
        return true
    end

    local function register_provider(provider_id, def)
        local id = tostring(provider_id or "")
        if id == "" then
            return false, "Provider id is required."
        end
        if type(def) ~= "table" or type(def.for_player) ~= "function" then
            return false, "Provider definition must include for_player(player)."
        end

        unregister_provider(id)
        HM.providers[id] = {
            interval = math.max(0.1, tonumber(def.interval) or 1.0),
            elapsed = 0,
            for_player = def.for_player,
        }
        HM.provider_state[id] = {}
        HM.provider_result_hash[id] = {}
        run_provider_tick(id, HM.providers[id], nil)
        return true
    end

    minetest.register_globalstep(function(dtime)
        for provider_id, provider in pairs(HM.providers) do
            provider.elapsed = (tonumber(provider.elapsed) or 0) + (tonumber(dtime) or 0)
            if provider.elapsed >= (tonumber(provider.interval) or 1.0) then
                provider.elapsed = 0
                run_provider_tick(provider_id, provider, nil)
            end
        end
    end)

    minetest.register_on_leaveplayer(function(player)
        if not player or not player.is_player or not player:is_player() then
            return
        end
        local pname = player:get_player_name()
        for provider_id, state in pairs(HM.provider_state) do
            if type(state) == "table" and state[pname] then
                remove_hologram_entry(state[pname], {persist = false, allow_missing = true})
                state[pname] = nil
                if type(HM.provider_result_hash[provider_id]) == "table" then
                    HM.provider_result_hash[provider_id][pname] = nil
                end
            end
        end
    end)

    HM.ops = {
        upsert_hologram_entry = upsert_hologram_entry,
        remove_hologram_entry = remove_hologram_entry,
        set_hologram_scale = set_hologram_scale,
        register_provider = register_provider,
        unregister_provider = unregister_provider,
        run_provider_tick = run_provider_tick,
    }

    API.upsert = function(name, pos, text, opts)
        local entry, err = upsert_hologram_entry(name, pos, text, opts)
        if not entry then
            return false, err
        end
        return true, entry
    end

    API.remove = function(name, opts)
        return remove_hologram_entry(name, opts)
    end

    API.set_scale = function(name, scale, opts)
        return set_hologram_scale(name, scale, opts)
    end

    API.register_provider = function(provider_id, def)
        return register_provider(provider_id, def)
    end

    API.unregister_provider = function(provider_id)
        return unregister_provider(provider_id)
    end

    API.refresh_provider = function(provider_id, player_or_name)
        local id = tostring(provider_id or "")
        local provider = HM.providers[id]
        if type(provider) ~= "table" then
            return false, "Unknown provider id."
        end
        run_provider_tick(id, provider, player_or_name)
        return true
    end

    API.get = function(name)
        local norm = normalize_name(name)
        if not norm then
            return nil
        end
        return HM.holograms[key_for_name(norm)]
    end

    API.list = function(opts)
        local include_transient = type(opts) == "table" and opts.include_transient == true
        local out = {}
        for _, row in pairs(HM.holograms) do
            if include_transient or (type(row) == "table" and row.transient ~= true) then
                out[#out + 1] = row
            end
        end
        return out
    end

    load_holograms()

    minetest.after(0, function()
        local keys = {}
        for key in pairs(HM.holograms) do
            keys[#keys + 1] = key
        end
        local idx = 1
        local batch = 40
        local function spawn_batch()
            local last = math.min(#keys, idx + batch - 1)
            for i = idx, last do
                spawn_or_update_entity(keys[i])
            end
            idx = last + 1
            if idx <= #keys then
                minetest.after(0, spawn_batch)
            end
        end
        if #keys > 0 then
            spawn_batch()
        end
    end)
end
