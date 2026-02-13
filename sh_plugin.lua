
local PLUGIN = PLUGIN

PLUGIN.name = "Locksystem"
PLUGIN.description = "Adds Digilock and Deadlock systems for controlling access to doors."
PLUGIN.author = "Haven"
PLUGIN.version = "1.1.0"

-- hint to scripts about this plugin's logical ID (folder name may differ in some setups)
PLUGIN.uniqueID = PLUGIN.uniqueID or "doorlocks"

ix.config.Add("requireBlankKeycard", true, "When enabled, players must have a blank keycard in their inventory to install keycard locks and print new keycards. The blank keycard will be consumed when printing.", nil, {
    category = "Locksystem"
})

ix.config.Add("allowAnyoneToLock", false, "When enabled, anyone can lock doors even if they don't have access to unlock them.", nil, {
    category = "Locksystem"
})

ix.config.Add("requireUnlockedDoorForPrinting", false, "When enabled, doors must be unlocked before keycards can be printed.", nil, {
    category = "Locksystem"
})

ix.config.Add("maxKeycardsPerLock", 10, "Maximum number of keycards that can be created for a single door. Group cards are not included in this limit.", nil, {
    category = "Locksystem",
    data = {min = 1, max = 100}
})

ix.util.Include("sv_plugin.lua")
ix.util.Include("cl_plugin.lua")