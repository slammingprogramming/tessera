-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Vanilla Minecraft crafting recipes (Java 1.20/1.21 names) for `autocraft`. Recipes of mods go in /etc/tsr/recipes.d (see `autocraft learn`).
-- Tags are lists of exact item names or Lua patterns (a pattern contains ^, $ or %).
local tags = {
  planks = { "_planks$" },
  cobble = { "minecraft:cobblestone", "minecraft:cobbled_deepslate", "minecraft:blackstone" },
  coals = { "minecraft:coal", "minecraft:charcoal" },
  sand = { "minecraft:sand", "minecraft:red_sand" },
  logs = { "_log$", "_stem$", "minecraft:bamboo_block" },
}

local recipes = {}
local function add(r) recipes[#recipes + 1] = r end

-- wood-specific recipes
local woods = { "oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry" }
local function wood(w)
  local planks = "minecraft:" .. w .. "_planks"
  add({ out = planks, count = 4, shapeless = { "minecraft:" .. w .. "_log" } })
  add({ out = "minecraft:" .. w .. "_slab", count = 6, shape = { "PPP" }, key = { P = planks } })
  add({ out = "minecraft:" .. w .. "_stairs", count = 4, shape = { "P  ", "PP ", "PPP" }, key = { P = planks } })
  add({ out = "minecraft:" .. w .. "_fence", count = 3, shape = { "PSP", "PSP" }, key = { P = planks, S = "minecraft:stick" } })
  add({ out = "minecraft:" .. w .. "_door", count = 3, shape = { "PP", "PP", "PP" }, key = { P = planks } })
  add({ out = "minecraft:" .. w .. "_trapdoor", count = 2, shape = { "PPP", "PPP" }, key = { P = planks } })
  add({ out = "minecraft:" .. w .. "_button", count = 1, shapeless = { planks } })
  add({ out = "minecraft:" .. w .. "_pressure_plate", count = 1, shape = { "PP" }, key = { P = planks } })
  add({ out = "minecraft:" .. w .. "_boat", count = 1, shape = { "P P", "PPP" }, key = { P = planks } })
end
for _, w in ipairs(woods) do wood(w) end
add({ out = "minecraft:crimson_planks", count = 4, shapeless = { "minecraft:crimson_stem" } })
add({ out = "minecraft:warped_planks", count = 4, shapeless = { "minecraft:warped_stem" } })
add({ out = "minecraft:bamboo_planks", count = 2, shapeless = { "minecraft:bamboo_block" } })

-- basics
add({ out = "minecraft:stick", count = 4, shape = { "P", "P" }, key = { P = "#planks" } })
add({ out = "minecraft:crafting_table", count = 1, shape = { "PP", "PP" }, key = { P = "#planks" } })
add({ out = "minecraft:chest", count = 1, shape = { "PPP", "P P", "PPP" }, key = { P = "#planks" } })
add({ out = "minecraft:barrel", count = 1, shape = { "PSP", "P P", "PSP" }, key = { P = "#planks", S = "minecraft:oak_slab" } })
add({ out = "minecraft:furnace", count = 1, shape = { "CCC", "C C", "CCC" }, key = { C = "#cobble" } })
add({ out = "minecraft:blast_furnace", count = 1, shape = { "III", "IFI", "SSS" }, key = { I = "minecraft:iron_ingot", F = "minecraft:furnace", S = "minecraft:smooth_stone" } })
add({ out = "minecraft:torch", count = 4, shape = { "C", "S" }, key = { C = "#coals", S = "minecraft:stick" } })
add({ out = "minecraft:ladder", count = 3, shape = { "S S", "SSS", "S S" }, key = { S = "minecraft:stick" } })
add({ out = "minecraft:bowl", count = 4, shape = { "P P", " P " }, key = { P = "#planks" } })
add({ out = "minecraft:bucket", count = 1, shape = { "I I", " I " }, key = { I = "minecraft:iron_ingot" } })
add({ out = "minecraft:shears", count = 1, shape = { " I", "I " }, key = { I = "minecraft:iron_ingot" } })
add({ out = "minecraft:flint_and_steel", count = 1, shapeless = { "minecraft:iron_ingot", "minecraft:flint" } })
add({ out = "minecraft:bread", count = 1, shape = { "WWW" }, key = { W = "minecraft:wheat" } })
add({ out = "minecraft:paper", count = 3, shape = { "SSS" }, key = { S = "minecraft:sugar_cane" } })
add({ out = "minecraft:book", count = 1, shapeless = { "minecraft:paper", "minecraft:paper", "minecraft:paper", "minecraft:leather" } })
add({ out = "minecraft:bookshelf", count = 1, shape = { "PPP", "BBB", "PPP" }, key = { P = "#planks", B = "minecraft:book" } })
add({ out = "minecraft:sugar", count = 1, shapeless = { "minecraft:sugar_cane" } })
add({ out = "minecraft:bone_meal", count = 3, shapeless = { "minecraft:bone" } })
add({ out = "minecraft:glass_pane", count = 16, shape = { "GGG", "GGG" }, key = { G = "minecraft:glass" } })
add({ out = "minecraft:tnt", count = 1, shape = { "GSG", "SGS", "GSG" }, key = { G = "minecraft:gunpowder", S = "#sand" } })
add({ out = "minecraft:lantern", count = 1, shape = { "NNN", "NTN", "NNN" }, key = { N = "minecraft:iron_nugget", T = "minecraft:torch" } })
add({ out = "minecraft:compass", count = 1, shape = { " I ", "IRI", " I " }, key = { I = "minecraft:iron_ingot", R = "minecraft:redstone" } })
add({ out = "minecraft:shield", count = 1, shape = { "PIP", "PPP", " P " }, key = { P = "#planks", I = "minecraft:iron_ingot" } })
add({ out = "minecraft:bow", count = 1, shape = { " ST", "S T", " ST" }, key = { S = "minecraft:stick", T = "minecraft:string" } })
add({ out = "minecraft:arrow", count = 4, shape = { "F", "S", "K" }, key = { F = "minecraft:flint", S = "minecraft:stick", K = "minecraft:feather" } })

-- stone
add({ out = "minecraft:stone_bricks", count = 4, shape = { "SS", "SS" }, key = { S = "minecraft:stone" } })
add({ out = "minecraft:cobblestone_slab", count = 6, shape = { "CCC" }, key = { C = "minecraft:cobblestone" } })
add({ out = "minecraft:cobblestone_stairs", count = 4, shape = { "C  ", "CC ", "CCC" }, key = { C = "minecraft:cobblestone" } })
add({ out = "minecraft:cobblestone_wall", count = 6, shape = { "CCC", "CCC" }, key = { C = "minecraft:cobblestone" } })
add({ out = "minecraft:stone_slab", count = 6, shape = { "SSS" }, key = { S = "minecraft:stone" } })
add({ out = "minecraft:stone_button", count = 1, shapeless = { "minecraft:stone" } })
add({ out = "minecraft:stone_pressure_plate", count = 1, shape = { "SS" }, key = { S = "minecraft:stone" } })

-- tools and armour: material -> ingredient
local materials = {
  wooden = "#planks", stone = "#cobble", iron = "minecraft:iron_ingot", golden = "minecraft:gold_ingot", diamond = "minecraft:diamond",
}
for name, m in pairs(materials) do
  local key = { M = m, S = "minecraft:stick" }
  add({ out = "minecraft:" .. name .. "_pickaxe", count = 1, shape = { "MMM", " S ", " S " }, key = key })
  add({ out = "minecraft:" .. name .. "_axe", count = 1, shape = { "MM", "MS", " S" }, key = key })
  add({ out = "minecraft:" .. name .. "_shovel", count = 1, shape = { "M", "S", "S" }, key = key })
  add({ out = "minecraft:" .. name .. "_hoe", count = 1, shape = { "MM", " S", " S" }, key = key })
  add({ out = "minecraft:" .. name .. "_sword", count = 1, shape = { "M", "M", "S" }, key = key })
end
local armour = { leather = "minecraft:leather", iron = "minecraft:iron_ingot", golden = "minecraft:gold_ingot", diamond = "minecraft:diamond" }
for name, m in pairs(armour) do
  local key = { M = m }
  add({ out = "minecraft:" .. name .. "_helmet", count = 1, shape = { "MMM", "M M" }, key = key })
  add({ out = "minecraft:" .. name .. "_chestplate", count = 1, shape = { "M M", "MMM", "MMM" }, key = key })
  add({ out = "minecraft:" .. name .. "_leggings", count = 1, shape = { "MMM", "M M", "M M" }, key = key })
  add({ out = "minecraft:" .. name .. "_boots", count = 1, shape = { "M M", "M M" }, key = key })
end

-- storage blocks and back
local blocks = {
  { "iron_ingot", "iron_block" }, { "gold_ingot", "gold_block" }, { "diamond", "diamond_block" }, { "emerald", "emerald_block" },
  { "redstone", "redstone_block" }, { "lapis_lazuli", "lapis_block" }, { "coal", "coal_block" }, { "copper_ingot", "copper_block" },
  { "netherite_ingot", "netherite_block" },
}
for _, b in ipairs(blocks) do
  add({ out = "minecraft:" .. b[2], count = 1, shape = { "III", "III", "III" }, key = { I = "minecraft:" .. b[1] } })
  add({ out = "minecraft:" .. b[1], count = 9, shapeless = { "minecraft:" .. b[2] } })
end
add({ out = "minecraft:iron_nugget", count = 9, shapeless = { "minecraft:iron_ingot" } })
add({ out = "minecraft:iron_ingot", count = 1, shape = { "NNN", "NNN", "NNN" }, key = { N = "minecraft:iron_nugget" } })
add({ out = "minecraft:gold_nugget", count = 9, shapeless = { "minecraft:gold_ingot" } })
add({ out = "minecraft:gold_ingot", count = 1, shape = { "NNN", "NNN", "NNN" }, key = { N = "minecraft:gold_nugget" } })

-- redstone and transport
add({ out = "minecraft:redstone_torch", count = 1, shape = { "R", "S" }, key = { R = "minecraft:redstone", S = "minecraft:stick" } })
add({ out = "minecraft:lever", count = 1, shape = { "S", "C" }, key = { S = "minecraft:stick", C = "minecraft:cobblestone" } })
add({ out = "minecraft:repeater", count = 1, shape = { "TRT", "SSS" }, key = { T = "minecraft:redstone_torch", R = "minecraft:redstone", S = "minecraft:stone" } })
add({ out = "minecraft:comparator", count = 1, shape = { " T ", "TQT", "SSS" }, key = { T = "minecraft:redstone_torch", Q = "minecraft:quartz", S = "minecraft:stone" } })
add({ out = "minecraft:observer", count = 1, shape = { "CCC", "RRQ", "CCC" }, key = { C = "#cobble", R = "minecraft:redstone", Q = "minecraft:quartz" } })
add({ out = "minecraft:dispenser", count = 1, shape = { "CCC", "CBC", "CRC" }, key = { C = "#cobble", B = "minecraft:bow", R = "minecraft:redstone" } })
add({ out = "minecraft:dropper", count = 1, shape = { "CCC", "C C", "CRC" }, key = { C = "#cobble", R = "minecraft:redstone" } })
add({ out = "minecraft:hopper", count = 1, shape = { "I I", "ICI", " I " }, key = { I = "minecraft:iron_ingot", C = "minecraft:chest" } })
add({ out = "minecraft:piston", count = 1, shape = { "PPP", "CIC", "CRC" }, key = { P = "#planks", C = "#cobble", I = "minecraft:iron_ingot", R = "minecraft:redstone" } })
add({ out = "minecraft:sticky_piston", count = 1, shape = { "S", "P" }, key = { S = "minecraft:slime_ball", P = "minecraft:piston" } })
add({ out = "minecraft:slime_block", count = 1, shape = { "SSS", "SSS", "SSS" }, key = { S = "minecraft:slime_ball" } })
add({ out = "minecraft:rail", count = 16, shape = { "I I", "ISI", "I I" }, key = { I = "minecraft:iron_ingot", S = "minecraft:stick" } })
add({ out = "minecraft:powered_rail", count = 6, shape = { "G G", "GSG", "GRG" }, key = { G = "minecraft:gold_ingot", S = "minecraft:stick", R = "minecraft:redstone" } })
add({ out = "minecraft:detector_rail", count = 6, shape = { "I I", "IPI", "IRI" }, key = { I = "minecraft:iron_ingot", P = "minecraft:stone_pressure_plate", R = "minecraft:redstone" } })
add({ out = "minecraft:activator_rail", count = 6, shape = { "ISI", "IRI", "ISI" }, key = { I = "minecraft:iron_ingot", S = "minecraft:stick", R = "minecraft:redstone_torch" } })
add({ out = "minecraft:minecart", count = 1, shape = { "I I", "III" }, key = { I = "minecraft:iron_ingot" } })
add({ out = "minecraft:daylight_detector", count = 1, shape = { "GGG", "QQQ", "PPP" }, key = { G = "minecraft:glass", Q = "minecraft:quartz", P = "minecraft:oak_slab" } })

return { tags = tags, recipes = recipes }
