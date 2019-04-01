-- ActivePlayer.lua mod

Menus["resurrect player"] = {
    text = color.Gold .. "Do you want\n" .. color.LightGreen ..
    "revive\n" .. color.Gold .. "this player ?\n" ..
        color.White .. "...",
    buttons = {                        
        { caption = "yes",
            destinations = {menuHelper.destinations.setDefault(nil,
            { 
                menuHelper.effects.runGlobalFunction("logicHandler", "ResurrectPlayer", 
                    {menuHelper.variables.currentPlayerDataVariable("targetPid")})
                })
            }
        },            
        { caption = "no", destinations = nil }
    }
}