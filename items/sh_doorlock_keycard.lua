ITEM.name = "Keycard"
ITEM.description = "A keycard meant for use with a specific digitized locking system."
ITEM.model = "models/eternalis/items/cards/access_card.mdl"
ITEM.skin = 5 -- Default blank skin
ITEM.width = 1
ITEM.height = 1
ITEM.category = "Security"

-- Get model and skin based on card type and story card data
function ITEM:GetModel()
    local cardType = self:GetData("cardType", nil)
    local storyCardType = self:GetData("storyCardType", nil)
    
    -- Story cards use elem_key model with specific skins
    if (storyCardType) then
        return "models/eternalis/items/keys/elem_key.mdl"
    end
    
    -- Blank cards use access_card model
    if (not cardType) then
        return "models/eternalis/items/cards/access_card.mdl"
    end
    
    -- Set model based on card type
    if (cardType == "master" or cardType == "installer") then
        return "models/card_admin/card_admin.mdl"
    elseif (cardType == "manager") then
        return "models/card_protektor/card_protektor.mdl"
    elseif (cardType == "user") then
        return "models/card_work/card_work.mdl"
    end
    
    return self.model
end

function ITEM:GetSkin()
    local storyCardType = self:GetData("storyCardType", nil)
    local cardType = self:GetData("cardType", nil)
    
    -- Story cards use specific skins (0-4)
    if (storyCardType == "air") then
        return 0
    elseif (storyCardType == "earth") then
        return 1
    elseif (storyCardType == "fire") then
        return 2
    elseif (storyCardType == "water") then
        return 3
    elseif (storyCardType == "gold") then
        return 4
    end
    
    -- Blank cards don't use skins
    if (not cardType) then
        return 0
    end
    
    -- Regular cards don't use skins
    return 0
end

function ITEM:GetName()
    local lockID = self:GetData("lockID", nil)
    local serialNumber = self:GetData("serialNumber", nil)
    local cardName = self:GetData("cardName", nil)

    if (not lockID) then
        return "Keycard"
    end

    if (serialNumber) then
        if (cardName and cardName ~= "") then
            return string.format("Keycard - Serial %d - %s", serialNumber, cardName)
        else
            return string.format("Keycard - Serial %d", serialNumber)
        end
    end

    return self.name
end

function ITEM:GetDescription()
    local lockID = self:GetData("lockID", nil)
    local serialNumber = self:GetData("serialNumber", nil)
    local cardType = self:GetData("cardType", nil)
    local cardName = self:GetData("cardName", nil)
    local storyCardType = self:GetData("storyCardType", nil)
    local storyDescription = self:GetData("storyDescription", nil)

    if (not lockID) then
        return "A keycard meant for use with a specific digitized locking system."
    end

    -- Story cards use their custom description
    if (storyDescription) then
        return storyDescription
    end

    local desc = self.description
    
    if (serialNumber) then
        desc = desc .. "\n\nSerial Number: " .. tostring(serialNumber)
    end
    
    if (cardType) then
        local typeName = string.upper(string.sub(cardType, 1, 1)) .. string.sub(cardType, 2)
        desc = desc .. "\nType: " .. typeName
    end
    
    if (cardName) then
        desc = desc .. "\nCard Name: " .. cardName
    end

    -- Generate a readable lock identifier from lockID
    if (lockID) then
        local parts = string.Explode(":", lockID)
        if (#parts >= 2) then
            local mapName = parts[1]
            local doorID = parts[2]
            desc = desc .. "\n\nLock ID: " .. mapName .. "-" .. doorID
        else
            desc = desc .. "\n\nLock ID: " .. string.sub(lockID, 1, 20) .. "..."
        end
    end

    return desc
end

if (CLIENT) then
    function ITEM:OnInstanced()
        -- Set model and skin when item is created/loaded
        local model = self:GetModel()
        local skin = self:GetSkin()
        if (model) then
            self.model = model
        end
        if (skin) then
            self.skin = skin
        end
    end

    function ITEM:OnDataChanged(key, oldValue, newValue)
        -- Update model/skin when data changes
        if (key == "cardType" or key == "storyCardType") then
            local model = self:GetModel()
            local skin = self:GetSkin()
            if (model) then
                self.model = model
            end
            if (skin) then
                self.skin = skin
            end
        end
    end

    function ITEM:PopulateTooltip(tooltip)
        local lockID = self:GetData("lockID", nil)
        local serialNumber = self:GetData("serialNumber", nil)
        local cardType = self:GetData("cardType", nil)
        local cardName = self:GetData("cardName", nil)

        if (lockID) then
            if (serialNumber) then
                local info = tooltip:AddRowAfter("description", "serial")
                info:SetText("Serial: " .. tostring(serialNumber))
                info:SetFont("ixSmallFont")
                info:SizeToContents()
            end
            
            if (cardType) then
                local typeName = string.upper(string.sub(cardType, 1, 1)) .. string.sub(cardType, 2)
                local info = tooltip:AddRowAfter(serialNumber and "serial" or "description", "type")
                info:SetText("Type: " .. typeName)
                info:SetFont("ixSmallFont")
                info:SizeToContents()
            end
            
            -- Generate readable lock identifier
            local parts = string.Explode(":", lockID)
            local lockDisplay = ""
            if (#parts >= 2) then
                lockDisplay = parts[1] .. "-" .. parts[2]
            else
                lockDisplay = string.sub(lockID, 1, 20) .. "..."
            end
            
            local info = tooltip:AddRowAfter(cardType and "type" or (serialNumber and "serial" or "description"), "lock")
            info:SetText("Lock: " .. lockDisplay)
            info:SetFont("ixSmallFont")
            info:SizeToContents()
        end
    end
end


