# holograms

`holograms` is a server-side sprite hologram API for Luanti.

Text rendering uses `signs_lib` fonts and supports color tokens when `color_lib` is present.

## Features

- holograms saved in world sqlite: `<worldpath>/holograms.sqlite3`
- dynamic holograms via provider callbacks
- alignment support: `left`, `center`, `right`

## Admin-only Commands

- `/hologram add <name> <x,y,z|~,~,~|~,~2,~4> <text>`
- `/hologram move <name> [x,y,z|~,~,~|~,~2,~4]`
- `/hologram edit <name> <text>`
- `/hologram list`
- `/hologram delete <name>`
- `/hologram size <name> <scale>`


## Global API

All functions are on the global table `holograms`.

- `holograms.upsert(name, pos, text[, opts]) -> ok, entry|err`
- `holograms.remove(name[, opts]) -> ok, err, entry`
- `holograms.set_scale(name, scale[, opts]) -> ok, err, entry`
- `holograms.register_provider(provider_id, def) -> ok, err`
- `holograms.unregister_provider(provider_id) -> ok, err`
- `holograms.refresh_provider(provider_id[, player_or_name]) -> ok, err`
- `holograms.get(name) -> entry|nil`
- `holograms.list([opts]) -> {entry, ...}`

### Entry Shape

An entry contains:
- `name`
- `pos = {x, y, z}`
- `text_raw`
- `scale`
- `align`
- `revision`
- `transient`

## Upsert Options

Supported `opts` fields:
- `persist` (default `true`)
- `scale`
- `align` (`left|center|right`)
- `allow_newlines` (`false` by default unless enabled in config)

## Provider API

Register a provider with:
- `def.for_player(player) -> result_table`
- `def.interval` (seconds, minimum `0.1`)

Provider `result_table` fields:
- `enabled = false` to hide/remove
- `name` or `key` (optional; auto-generated if omitted)
- `pos = {x, y, z}`
- `text`
- `scale` (optional)
- `align` (optional)
- `allow_newlines` (optional)


## Integration Example

```lua
local HOLO = rawget(_G, "holograms")
if not HOLO then
    return
end

-- Static/durable hologram
local ok, res = HOLO.upsert("spawn_info", {x = 0, y = 10, z = 0}, "Welcome!", {
    persist = true,
    scale = 1.2,
    align = "center",
})

-- Dynamic per-player hologram
HOLO.register_provider("example_status", {
    interval = 1.0,
    for_player = function(player)
        local p = player:get_pos()
        return {
            name = "status_" .. player:get_player_name(),
            pos = {x = p.x, y = p.y + 3, z = p.z},
            text = "Tracking: " .. player:get_player_name(),
            scale = 1.0,
            align = "center",
            allow_newlines = false,
        }
    end,
})
```
