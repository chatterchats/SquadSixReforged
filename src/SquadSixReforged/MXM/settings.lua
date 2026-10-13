return {
    id = "SquadSixReforged",
    name = "Squad Six Reforged",
    author = "arctco, continued by Chats",
    version = "1.2.0",
    description = "Six-operator squads. Deployment options.",
    settings = {
        {key = "improve_game_spots", type = "bool", name = "Move the game's spots into cover", default = true,
         desc = "At the start of an encounter, a deployment spot whose cover faces away from the enemies, or that has none, moves to cover facing them within two tiles. Applies from the next encounter."},
        {type = "header", name = "Debugging"},
        {key = "debug_cover_markers", type = "bool", name = "Show cover debug markers", default = false,
         desc = "At the start of an encounter, show every cover spot the mod considered for a minute: green usable, yellow too close to a squadmate or spot, red outside the deployment area or not walkable. Cover facing away from the enemies isn't marked."},
    },
}
