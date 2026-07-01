-- This is the main file run by CSP
-- From here it loads multiple scripts and runs them each cycle

local debug_script = require("Script_Debug")
local throttle_script = require("Script_Throttle_Override")






function script.update(dt)
    
    ac.perfBegin("Debug script")
    debug_script.update(dt)
    ac.perfEnd("Debug script")
    
    ac.perfBegin("Throttle script")
    throttle_script.update(dt)
    ac.perfEnd("Throttle script")  

    
end