terumet.FLUX_MELTING_TIME = 1.0
terumet.FLUX_SOURCE = terumet.id('lump_raw')
terumet.SMELTER_FLUX_MAXIMUM = 99
terumet.SMELTER_FUEL_MAXIMUM = 300.0
terumet.SMELTER_FUEL_MULTIPLIER = 10.0

local asmelt = {}
asmelt.full_id = terumet.id('mach_asmelt')

-- state identifier consts
asmelt.STATE = {}
asmelt.STATE.IDLE = 0
asmelt.STATE.FLUX_MELT = 1
asmelt.STATE.ALLOYING = 2

function asmelt.start_timer(pos)
    minetest.get_node_timer(pos):start(1.0)
end

function asmelt.stack_is_valid_fuel(stack)
    return minetest.get_craft_result({method="fuel", width=1, items={stack}}).time ~= 0
end

function asmelt.generate_formspec(smelter)
    local fs = 'size[8,9]'..
    --player inventory
    'list[current_player;main;0,4.75;8,1;]'..
    'list[current_player;main;0,6;8,3;8]'..
    --input inventory
    'list[context;inp;0,1.5;2,2;]'..
    --output inventory
    'list[context;out;6,1.5;2,2;]'..
    --fuel inventory
    'list[context;fuel;4,3.5;1,1;]'..
    --current status text
    'label[0,0;Terumetal Alloy Smelter]'..
    'label[0,0.5;' .. smelter.status_text .. ']'..
    'label[5,3.5;Fuel: ' .. terumet.format_time(smelter.fuel_time) .. ']'..
    --molten readout
    'label[2.4,2.5;Molten flux: ' .. (smelter.flux_tank or '???') .. '/' .. terumet.SMELTER_FLUX_MAXIMUM .. ' lumps' .. ']'
    return fs
end

function asmelt.generate_infotext(smelter)
    return 'Alloy Smelter: ' .. smelter.status_text
end

function asmelt.init(pos)
    local meta = minetest.get_meta(pos)
    local inv = meta:get_inventory()
    inv:set_size('fuel', 1)
    inv:set_size('inp', 4)
    inv:set_size('result', 1)
    inv:set_size('out', 4)

    local init_smelter = {
        flux_tank = 0,
        state = asmelt.STATE.IDLE,
        state_time = 0,
        fuel_time = 0,
        status_text = 'New',
    }

    asmelt.write_state(pos, init_smelter)
end

function asmelt.get_drops(pos, include_self)
    local drops = {}
    default.get_inventory_drops(pos, "fuel", drops)
    default.get_inventory_drops(pos, "inp", drops)
    default.get_inventory_drops(pos, "out", drops)
    local flux_tank = minetest.get_meta(pos):get_int('flux_tank') or 0
    if flux_tank > 0 then
        drops[#drops+1] = terumet.id('lump_raw', math.min(99, flux_tank))
    end
    if include_self then drops[#drops+1] = asmelt.full_id end
    return drops
end

function asmelt.read_state(pos)
    local smelter = {}
    local meta = minetest.get_meta(pos)
    smelter.meta = meta
    smelter.inv = meta:get_inventory()
    smelter.flux_tank = meta:get_int('flux_tank') or 0
    smelter.state = meta:get_int('state') or asmelt.STATE.IDLE
    smelter.fuel_time = meta:get_float('fuel_time') or 0
    smelter.state_time = meta:get_float('state_time') or 0
    smelter.status_text = 'STATUS TEXT NOT SET'
    return smelter
end

function asmelt.write_state(pos, smelter)
    local meta = minetest.get_meta(pos)
    meta:set_string('formspec', asmelt.generate_formspec(smelter))
    meta:set_string('infotext', asmelt.generate_infotext(smelter))
    meta:set_int('flux_tank', smelter.flux_tank)
    meta:set_int('state', smelter.state)
    meta:set_float('state_time', smelter.state_time)
    meta:set_float('fuel_time', smelter.fuel_time)
end

function asmelt.tick(pos, dt)
    -- read status from metadata
    local smelter = asmelt.read_state(pos)

    -- do processing
    if smelter.state == asmelt.STATE.FLUX_MELT then
        smelter.state_time = smelter.state_time - dt
        smelter.status_text = 'Melting flux (' .. terumet.format_time(smelter.state_time) .. ')'
        if smelter.state_time <= 0 then
            smelter.flux_tank = smelter.flux_tank + 1
            smelter.state = asmelt.STATE.IDLE
        end
    elseif smelter.state == asmelt.STATE.ALLOYING then
        local result_stack = smelter.inv:get_stack('result', 1)
        local result_name = result_stack:get_definition().description
        smelter.state_time = smelter.state_time - dt
        smelter.status_text = 'Alloying ' .. result_name .. ' (' .. terumet.format_time(smelter.state_time) .. ')'
        if smelter.state_time <= 0 then
            if smelter.inv:room_for_item('out', result_stack) then
                smelter.inv:set_stack('result', 1, nil)
                smelter.inv:add_item('out', result_stack)
                smelter.state = asmelt.STATE.IDLE
            else
                smelter.status_text = result_name .. ' ready - no space!'
                smelter.state_time = -0.1
            end
        end 
    end

    -- check for new processing states if now idle
    if smelter.state == asmelt.STATE.IDLE then
        -- check for flux to melt
        if smelter.inv:contains_item('inp', terumet.FLUX_SOURCE) then
            if smelter.flux_tank >= terumet.SMELTER_FLUX_MAXIMUM then
                smelter.status_text = 'Melting flux: tank full!'
            else
                smelter.state = asmelt.STATE.FLUX_MELT
                smelter.state_time = terumet.FLUX_MELTING_TIME
                smelter.inv:remove_item('inp', terumet.FLUX_SOURCE)
                smelter.status_text = 'Melting flux...'
            end
        else
            -- check for any matched recipes in input
            local matched_result = nil
            for result, recipe in pairs(terumet.alloy_recipes) do
                --minetest.chat_send_all('checking recipe' .. dump(result) .. ' to list: ' .. dump(source_list))
                local sources_count = 0
                for i = 1,#recipe do
                    --minetest.chat_send_all('looking for srcitem: ' .. source_list[i])
                    if smelter.inv:contains_item('inp', recipe[i]) then
                        sources_count = sources_count + 1
                    end
                end
                if sources_count == #recipe then
                    matched_result = result
                    break
                end
            end
            if matched_result and minetest.registered_items[matched_result] then
                local recipe = terumet.alloy_recipes[matched_result]
                local result_name = minetest.registered_items[matched_result].description
                if smelter.flux_tank < recipe.flux then
                    smelter.status_text = 'Alloying ' .. result_name .. ': ' .. recipe.flux .. ' flux required'
                else
                    smelter.state = asmelt.STATE.ALLOYING
                    for _, consumed_source in ipairs(recipe) do
                        smelter.inv:remove_item('inp', consumed_source)
                    end
                    smelter.state_time = recipe.time
                    smelter.inv:set_stack('result', 1, ItemStack(matched_result, recipe.result_count))
                    smelter.flux_tank = smelter.flux_tank - recipe.flux
                    smelter.status_text = 'Alloying ' .. result_name .. '...'
                end
            else
                smelter.status_text = 'Idle'
            end
        end
    end
    
    -- if not currently idle, set next timer tick
    if smelter.state ~= asmelt.STATE.IDLE then asmelt.start_timer(pos) end

    -- write status back to metadata
    asmelt.write_state(pos, smelter)
end

function asmelt.allow_put(pos, listname, index, stack, player)
    if minetest.is_protected(pos, player:get_player_name()) then
        return 0 -- number of items allowed to move
    end
    if listname == "fuel" then
        if asmelt.stack_is_valid_fuel(stack) then
            return stack:get_count()
        else
            return 0
        end
    elseif listname == "inp" then
        return stack:get_count()
    else
        return 0
    end
end

function asmelt.allow_take(pos, listname, index, stack, player)
    if minetest.is_protected(pos, player:get_player_name()) then
        return 0
    end
    return stack:get_count()
end

function asmelt.allow_move(pos, from_list, from_index, to_list, to_index, count, player)
    --return count
    local stack = minetest.get_meta(pos):get_inventory():get_stack(from_list, from_index)
    return asmelt.allow_put(pos, to_list, to_index, stack, player)
end

asmelt.nodedef = {
    -- node properties
    description = "Terumetal Alloy Smelter",
    tiles = {
        terumet.tex_file('block_raw'), terumet.tex_file('block_raw'),
        terumet.tex_file('asmelt_sides'), terumet.tex_file('asmelt_sides'),
        terumet.tex_file('asmelt_sides'), terumet.tex_file('asmelt_front')
    },
    paramtype2 = 'facedir',
    groups = {cracky=1},
    is_ground_content = false,
    sounds = default.node_sound_metal_defaults(),
    legacy_facedir_simple = true,
    -- inventory slot control
    allow_metadata_inventory_put = asmelt.allow_put,
    allow_metadata_inventory_move = asmelt.allow_move,
    allow_metadata_inventory_take = asmelt.allow_take,
    -- callbacks
    on_construct = asmelt.init,
    on_metadata_inventory_move = asmelt.start_timer,
    on_metadata_inventory_put = asmelt.start_timer,
    on_metadata_inventory_take = asmelt.start_timer,
    on_timer = asmelt.tick,
    on_destruct = function(pos)
        for _,item in ipairs(asmelt.get_drops(pos, false)) do
            minetest.add_item(pos, item)
        end
    end,
    on_blast = function(pos)
        drops = asmelt.get_drops(pos, true)
        minetest.remove_node(pos)
        return drops
    end
}

minetest.register_node(asmelt.full_id, asmelt.nodedef)

minetest.register_craft{ output = asmelt.full_id, recipe = {
    {terumet.id('ingot_raw'), 'default:furnace', terumet.id('ingot_raw')},
    {'bucket:bucket_empty', 'default:copperblock', 'bucket:bucket_empty'},
    {terumet.id('ingot_raw'), 'default:furnace', terumet.id('ingot_raw')}
}}