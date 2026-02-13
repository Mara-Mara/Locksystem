ITEM.name = "Digilock"
ITEM.description = "A digital locking system that secures an entire doorway electronically."
ITEM.model = "models/card_reader/card_reader.mdl"
ITEM.width = 1
ITEM.height = 1
ITEM.category = "Security"

if (CLIENT) then
    function ITEM:PopulateTooltip(tooltip)
        local info = tooltip:AddRowAfter("description", "info")
        info:SetText("Applies an invisible lock to a door and all its children.")
        info:SetFont("ixSmallFont")
        info:SizeToContents()
    end
end

ITEM.functions.Place = {
    name = "Place",
    icon = "icon16/lock_go.png",

    OnRun = function(item)
        local client = item.player
        if (not IsValid(client)) then return false end

        local character = client:GetCharacter()
        if (not character) then return false end

        local data = {}
        data.start = client:GetShootPos()
        data.endpos = data.start + client:GetAimVector() * 96
        data.filter = client

        local trace = util.TraceLine(data)
        local door = trace.Entity


        if (not IsValid(door) or not door:IsDoor()) then
            client:Notify("You must look at a door to place this lock.")
            return false
        end

        -- item files are not loaded inside the plugin's PLUGIN scope,
        -- so we must fetch the plugin instance explicitly.
        -- Try multiple possible plugin names/IDs
        local plugin = ix.plugin.Get("doorlocks") or ix.plugin.Get("locksystem") or ix.plugin.list["doorlocks"] or ix.plugin.list["locksystem"]
        if (not plugin) then
            -- Try to find by folder name
            for _, v in pairs(ix.plugin.list or {}) do
                if (v.uniqueID == "doorlocks" or v.name == "Door Locks") then
                    plugin = v
                    break
                end
            end
        end
        
        if (not plugin or not plugin.BeginPlacement) then
            client:Notify("Door locks system is not ready. Plugin may not be loaded.")
            return false
        end

        plugin:BeginPlacement(client, door, plugin.lockTypes.DIGILOCK, item.id)
        
        -- Mark that placement has started for this item
        item:SetData("placementActive", true)

        -- do not immediately remove the item; it is consumed when placement succeeds
        return false
    end
}

ITEM.functions.FinalizePlacement = {
    name = "Finalize Placement",
    icon = "icon16/lock_go.png",
    
    OnCanRun = function(item)
        -- Only show if placement has been started (tracked via item data)
        return item:GetData("placementActive", false) == true
    end,
    
    OnRun = function(item)
        local client = item.player
        if (not IsValid(client)) then return false end
        
        if (CLIENT) then
            -- Send network message from client
            net.Start("ixDoorLocks_FinalizePlacement")
            net.SendToServer()
        elseif (SERVER) then
            -- Handle directly on server
            local clientID = client:SteamID64() or tostring(client:EntIndex())
            local plugin = ix.plugin.Get("doorlocks") or ix.plugin.Get("locksystem")
            if (plugin and plugin.placementSessions) then
                local session = plugin.placementSessions[clientID]
                if (session and #session.doorIDs > 0 and session.lockType == plugin.lockTypes.DIGILOCK and session.itemID == item.id) then
                    -- Trigger the handler directly
                    local firstDoorID = session.doorIDs[1]
                    local firstDoor = plugin:GetDoorFromID(firstDoorID)
                    if (IsValid(firstDoor)) then
                        net.Start("ixDoorLocks_OpenPlacement")
                            net.WriteEntity(firstDoor)
                            net.WriteString(session.lockType)
                            net.WriteUInt(session.itemID or 0, 32)
                            if (session.lockType == plugin.lockTypes.DEADLOCK and session.traceData) then
                                net.WriteBool(true)
                                net.WriteVector(session.traceData.hitPos or Vector(0, 0, 0))
                                net.WriteVector(session.traceData.hitNormal or Vector(0, 0, 0))
                            else
                                net.WriteBool(false)
                            end
                            net.WriteUInt(#session.doorIDs > 1 and #session.doorIDs or 0, 8)
                            if (#session.doorIDs > 1) then
                                for _, doorID in ipairs(session.doorIDs) do
                                    net.WriteUInt(doorID, 32)
                                end
                            end
                        net.Send(client)
                    else
                        client:Notify("Could not find first door in selection.")
                        plugin.placementSessions[clientID] = nil
                        item:SetData("placementActive", false)
                    end
                else
                    client:Notify("No active placement session with selected doors.")
                    item:SetData("placementActive", false)
                end
            end
        end
        
        return false
    end
}

ITEM.functions.CancelPlacement = {
    name = "Cancel Placement",
    icon = "icon16/cancel.png",
    
    OnCanRun = function(item)
        -- Only show if placement has been started (tracked via item data)
        return item:GetData("placementActive", false) == true
    end,
    
    OnRun = function(item)
        local client = item.player
        if (not IsValid(client)) then return false end
        
        if (CLIENT) then
            -- Send network message from client
            net.Start("ixDoorLocks_CancelPlacement")
            net.SendToServer()
        elseif (SERVER) then
            -- Handle directly on server
            local clientID = client:SteamID64() or tostring(client:EntIndex())
            local plugin = ix.plugin.Get("doorlocks") or ix.plugin.Get("locksystem")
            if (plugin and plugin.placementSessions) then
                if (plugin.placementSessions[clientID]) then
                    plugin.placementSessions[clientID] = nil
                    client:Notify("Placement session cancelled.")
                else
                    client:Notify("No active placement session.")
                end
            end
            -- Always clear the placement flag
            item:SetData("placementActive", false)
        end
        
        return false
    end
}

ITEM.functions.UndoLastSelection = {
    name = "Undo Last Selection",
    icon = "icon16/arrow_undo.png",
    
    OnCanRun = function(item)
        -- Only show if placement has been started (tracked via item data)
        return item:GetData("placementActive", false) == true
    end,
    
    OnRun = function(item)
        local client = item.player
        if (not IsValid(client)) then return false end
        
        if (CLIENT) then
            -- Send network message from client
            net.Start("ixDoorLocks_UndoLastSelection")
            net.SendToServer()
        elseif (SERVER) then
            -- Handle directly on server
            local clientID = client:SteamID64() or tostring(client:EntIndex())
            local plugin = ix.plugin.Get("doorlocks") or ix.plugin.Get("locksystem")
            if (plugin and plugin.placementSessions) then
                local session = plugin.placementSessions[clientID]
                if (not session) then
                    client:Notify("No active placement session.")
                elseif (#session.doorIDs == 0) then
                    client:Notify("No doors in selection to undo.")
                else
                    local removedDoorID = table.remove(session.doorIDs)
                    if (#session.doorIDs == 0) then
                        plugin.placementSessions[clientID] = nil
                        client:Notify("Last door removed. Placement session cancelled.")
                        item:SetData("placementActive", false)
                    else
                        client:Notify(string.format("Last door removed. %d door(s) remaining in selection.", #session.doorIDs))
                    end
                end
            end
        end
        
        return false
    end
}



