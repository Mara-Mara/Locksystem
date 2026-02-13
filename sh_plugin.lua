
local PLUGIN = PLUGIN

PLUGIN.name = "Locksystem"
PLUGIN.description = "Adds Digilock and Deadlock systems for controlling access to doors."
PLUGIN.author = "Haven"
PLUGIN.version = "1.2"

-- hint to scripts about this plugin's logical ID (folder name may differ in some setups)
PLUGIN.uniqueID = PLUGIN.uniqueID or "doorlocks"

ix.util.Include("sv_plugin.lua")
ix.util.Include("cl_plugin.lua")
