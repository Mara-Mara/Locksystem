local PLUGIN = PLUGIN

-- Client-side UI for placement and lock interaction.

local function OpenPlacementMenu(door, lockType, itemID, traceHitPos, traceHitNormal, doorIDs)
    if (not IsValid(door)) then return end

    doorIDs = doorIDs or {} -- Multi-door support
    
    local frame = vgui.Create("DFrame")
    local title = "Install " .. ((lockType == "deadlock") and "Deadlock" or "Digilock")
    if (#doorIDs > 1) then
        title = title .. " (" .. #doorIDs .. " doors)"
    end
    frame:SetTitle(title)
    frame:SetSize(300, 220 + (#doorIDs > 1 and 20 or 0))
    frame:Center()
    frame:MakePopup()
    
    -- Store trace data and doorIDs for sending back to server
    frame.traceHitPos = traceHitPos
    frame.traceHitNormal = traceHitNormal
    frame.doorIDs = doorIDs

    local modeLabel = vgui.Create("DLabel", frame)
    modeLabel:SetText("Mode:")
    modeLabel:Dock(TOP)
    modeLabel:DockMargin(8, 8, 8, 4)

    local modeCombo = vgui.Create("DComboBox", frame)
    modeCombo:Dock(TOP)
    modeCombo:DockMargin(8, 0, 8, 4)
    modeCombo:SetValue("Code")
    modeCombo:AddChoice("Code")
    modeCombo:AddChoice("Keycard")
    modeCombo:AddChoice("Biometric")

    local userCodeEntry = vgui.Create("DTextEntry", frame)
    userCodeEntry:Dock(TOP)
    userCodeEntry:DockMargin(8, 4, 8, 4)
    userCodeEntry:SetPlaceholderText("User Code (required)")
    userCodeEntry:SetVisible(true)

    local masterCodeEntry = vgui.Create("DTextEntry", frame)
    masterCodeEntry:Dock(TOP)
    masterCodeEntry:DockMargin(8, 4, 8, 4)
    masterCodeEntry:SetPlaceholderText("Manager Code (optional)")
    masterCodeEntry:SetVisible(true)

    -- Update code entry visibility based on mode selection
    function modeCombo:OnSelect(index, value, data)
        local isCode = string.lower(value) == "code"
        userCodeEntry:SetVisible(isCode)
        masterCodeEntry:SetVisible(isCode)
        if (not isCode) then
            userCodeEntry:SetText("")
            masterCodeEntry:SetText("")
        end
    end

    local confirm = vgui.Create("DButton", frame)
    confirm:Dock(BOTTOM)
    confirm:DockMargin(8, 4, 8, 8)
    confirm:SetText("Install Lock")

    function confirm:DoClick()
        local modeText = modeCombo:GetSelected() or modeCombo:GetValue() or "Code"
        local userCode = userCodeEntry:GetText() or ""
        local masterCode = masterCodeEntry:GetText() or ""

        net.Start("ixDoorLocks_ConfirmPlacement")
            net.WriteEntity(door)
            net.WriteString(string.lower(lockType or ""))
            net.WriteString(string.lower(modeText))
            net.WriteUInt(itemID or 0, 32)
            net.WriteString(userCode)
            net.WriteString(masterCode)
            -- Send trace data for deadlocks
            if (lockType == "deadlock" and frame.traceHitPos and frame.traceHitNormal) then
                net.WriteBool(true)
                net.WriteVector(frame.traceHitPos)
                net.WriteVector(frame.traceHitNormal)
            else
                net.WriteBool(false)
            end
            -- Send multi-door selection
            net.WriteBool(#frame.doorIDs > 0)
            if (#frame.doorIDs > 0) then
                net.WriteUInt(#frame.doorIDs, 8)
                for _, doorID in ipairs(frame.doorIDs) do
                    net.WriteUInt(doorID, 32)
                end
            end
        net.SendToServer()

        frame:Close()
    end
end

net.Receive("ixDoorLocks_OpenPlacement", function()
    local door = net.ReadEntity()
    local lockType = net.ReadString()
    local itemID = net.ReadUInt(32)
    local hasTraceData = net.ReadBool()
    local traceHitPos = hasTraceData and net.ReadVector() or nil
    local traceHitNormal = hasTraceData and net.ReadVector() or nil
    
    -- Read multi-door selection (if present)
    local doorCount = net.ReadUInt(8)
    local doorIDs = {}
    if (doorCount > 0) then
        for i = 1, doorCount do
            table.insert(doorIDs, net.ReadUInt(32))
        end
    end

    OpenPlacementMenu(door, lockType, itemID, traceHitPos, traceHitNormal, doorIDs)
end)

-- Main action menu -----------------------------------------------------------

-- Track open menus to prevent duplicates
local activeLockMenu = nil
local activeBiometricMenu = nil
local activeKeycardMenu = nil

local function OpenLockMenu(door, lockID, isDeadlock, lockType, mode, isLocked, isManager, isBio, isBioManager, hasManager, hasMaster, hasKeycard, isKeycardMaster, isKeycardManager, isAdmin, isAdminDeactivated)
    if (not IsValid(door)) then return end

    -- Close existing menu if open
    if (IsValid(activeLockMenu)) then
        activeLockMenu:Close()
        activeLockMenu = nil
    end

    -- Admins always see the config menu
    -- Regular users only see it if they have config options available
    if (not isAdmin) then
        -- Check if there are any config options available for non-admins
        local hasConfigOptions = false
        if (mode == "code" and hasManager) then
            hasConfigOptions = true
        elseif (mode == "biometric" and (isBioManager or hasMaster)) then
            hasConfigOptions = true
        elseif (mode == "keycard" and (isKeycardManager or hasKeycard)) then
            hasConfigOptions = true
        elseif (hasMaster) then
            hasConfigOptions = true
        end

        -- If no config options, show message and return (only for non-admins)
        if (not hasConfigOptions) then
            LocalPlayer():Notify("No config menu to display!")
            return
        end
    end

    local frame = vgui.Create("DFrame")
    frame:SetTitle("Door Lock")
    
    -- Calculate approximate height needed based on buttons
    local buttonCount = 1 -- toggle
    -- Remove button: for keycard locks (master tier keycard), for other locks (hasMaster)
    if (mode ~= "keycard" and hasMaster) then
        buttonCount = buttonCount + 1 -- remove (for non-keycard locks)
    elseif (mode == "keycard" and isKeycardMaster) then
        buttonCount = buttonCount + 1 -- remove (for keycard locks)
    end
    -- Group code buttons (masters only)
    -- For keycard locks, require master tier keycard; for other locks, require master access
    if (mode == "keycard" and isKeycardMaster) or (mode ~= "keycard" and hasMaster) then
        buttonCount = buttonCount + 3 -- set group code, clear group code, view group locks
    end
    if (mode == "code" and hasManager) then
        buttonCount = buttonCount + 3 -- change user code, change manager code, clear users
    elseif (mode == "biometric") then
        if (isBioManager or hasMaster) then
            buttonCount = buttonCount + 4 -- regular pairing, manager pairing, view users, clear users
        end
    elseif (mode == "keycard") then
        if (isKeycardManager) then
            buttonCount = buttonCount + 2 -- print keycard, view keycards
        end
        if (isKeycardMaster) then
            buttonCount = buttonCount + 1 -- remove lock (master tier keycard)
        end
        if (isAdmin) then
            buttonCount = buttonCount + 3 -- print story card, print master card, admin remove lock
        end
    end
    if (isAdmin and mode ~= "keycard") then
        buttonCount = buttonCount + 1 -- admin mode-specific button (not for keycard)
        buttonCount = buttonCount + 1 -- admin remove (not for keycard, handled above)
    end
    
    local height = 110 + (buttonCount * 25) + 20 -- extra padding
    frame:SetSize(300, math.max(height, 200)) -- wider for longer button text, minimum 200 height
    frame:Center()
    frame:MakePopup()

    -- Store reference and clean up on close
    activeLockMenu = frame
    function frame:OnClose()
        if (activeLockMenu == self) then
            activeLockMenu = nil
        end
    end

    local info = vgui.Create("DLabel", frame)
    info:Dock(TOP)
    info:DockMargin(8, 8, 8, 4)
    info:SetText(string.format("Type: %s   Mode: %s", lockType, mode))
    info:SizeToContents()

    -- If admin is deactivated, only show "Admin: Reactivate Own User" button
    if (isAdminDeactivated) then
        -- Admin: Reactivate Own User
        local adminReactivate = vgui.Create("DButton", frame)
        adminReactivate:Dock(TOP)
        adminReactivate:DockMargin(8, 4, 8, 8)
        adminReactivate:SetText("Admin: Reactivate Own User")

        function adminReactivate:DoClick()
            net.Start("ixDoorLocks_DoAction")
                net.WriteString("admin_reactivate_own_user")
                net.WriteString(lockID)
            net.SendToServer()

            frame:Close()
        end

        return -- Don't create any other buttons
    end

    -- For keycard locks, users need a keycard to see the toggle button
    -- For biometric locks, users need to be authorized to see the toggle button
    local showToggle = true
    if (mode == "keycard") then
        if (not hasKeycard) then
            showToggle = false -- Users without keycards don't see toggle
        end
    elseif (mode == "biometric") then
        -- For biometric locks, only show toggle if user is authorized (not just admin)
        if (not isBio and not hasMaster) then
            showToggle = false -- Users not authorized don't see toggle
        end
    end

    if (showToggle) then
        local toggle = vgui.Create("DButton", frame)
        toggle:Dock(TOP)
        toggle:DockMargin(8, 4, 8, 0)
        toggle:SetText(isLocked and "Unlock" or "Lock")

        function toggle:DoClick()
        if (mode == "code" and isLocked and not hasMaster and not isManager) then
            -- prompt for code to unlock (user code or master code)
            local codeFrame = vgui.Create("DFrame")
            codeFrame:SetTitle("Enter Code")
            codeFrame:SetSize(280, 120)
            codeFrame:Center()
            codeFrame:MakePopup()

            local entry = vgui.Create("DTextEntry", codeFrame)
            entry:Dock(TOP)
            entry:DockMargin(8, 8, 8, 4)
            entry:SetPlaceholderText("Code")

            local ok = vgui.Create("DButton", codeFrame)
            ok:Dock(BOTTOM)
            ok:DockMargin(8, 4, 8, 8)
            ok:SetText("Submit")

            function ok:DoClick()
                local code = entry:GetText() or ""

                net.Start("ixDoorLocks_SubmitCode")
                    net.WriteString(lockID)
                    net.WriteString("unlock")
                    net.WriteString(code)
                net.SendToServer()

                codeFrame:Close()
                frame:Close()
            end

            return
        end

        net.Start("ixDoorLocks_DoAction")
            net.WriteString("toggle")
            net.WriteString(lockID)
        net.SendToServer()

        frame:Close()
        end
    end

    -- Code mode specific buttons (only visible to manager code users)
    if (mode == "code" and hasManager) then
        local changeUserCode = vgui.Create("DButton", frame)
        changeUserCode:Dock(TOP)
        changeUserCode:DockMargin(8, 4, 8, 0)
        changeUserCode:SetText("Change User Code")

        function changeUserCode:DoClick()
            local codeFrame = vgui.Create("DFrame")
            codeFrame:SetTitle("Change User Code")
            codeFrame:SetSize(280, 180)
            codeFrame:Center()
            codeFrame:MakePopup()

            local entry1 = vgui.Create("DTextEntry", codeFrame)
            entry1:Dock(TOP)
            entry1:DockMargin(8, 8, 8, 4)
            entry1:SetPlaceholderText("New User Code")

            local entry2 = vgui.Create("DTextEntry", codeFrame)
            entry2:Dock(TOP)
            entry2:DockMargin(8, 4, 8, 4)
            entry2:SetPlaceholderText("Retype User Code")

            local ok = vgui.Create("DButton", codeFrame)
            ok:Dock(BOTTOM)
            ok:DockMargin(8, 4, 8, 8)
            ok:SetText("Set Code")

            function ok:DoClick()
                local code1 = entry1:GetText() or ""
                local code2 = entry2:GetText() or ""

                if (code1 ~= code2) then
                    LocalPlayer():Notify("Codes do not match. Please retype the code.")
                    return
                end

                if (code1 == "") then
                    LocalPlayer():Notify("Code cannot be empty.")
                    return
                end

                net.Start("ixDoorLocks_SubmitCode")
                    net.WriteString(lockID)
                    net.WriteString("change_user")
                    net.WriteString(code1)
                net.SendToServer()

                codeFrame:Close()
                frame:Close()
            end
        end

        local changeManagerCode = vgui.Create("DButton", frame)
        changeManagerCode:Dock(TOP)
        changeManagerCode:DockMargin(8, 4, 8, 0)
        changeManagerCode:SetText("Change Manager Code")

        function changeManagerCode:DoClick()
            local codeFrame = vgui.Create("DFrame")
            codeFrame:SetTitle("Change Manager Code")
            codeFrame:SetSize(280, 180)
            codeFrame:Center()
            codeFrame:MakePopup()

            local entry1 = vgui.Create("DTextEntry", codeFrame)
            entry1:Dock(TOP)
            entry1:DockMargin(8, 8, 8, 4)
            entry1:SetPlaceholderText("New Manager Code")

            local entry2 = vgui.Create("DTextEntry", codeFrame)
            entry2:Dock(TOP)
            entry2:DockMargin(8, 4, 8, 4)
            entry2:SetPlaceholderText("Retype Manager Code")

            local ok = vgui.Create("DButton", codeFrame)
            ok:Dock(BOTTOM)
            ok:DockMargin(8, 4, 8, 8)
            ok:SetText("Set Code")

            function ok:DoClick()
                local code1 = entry1:GetText() or ""
                local code2 = entry2:GetText() or ""

                if (code1 ~= code2) then
                    LocalPlayer():Notify("Codes do not match. Please retype the code.")
                    return
                end

                if (code1 == "") then
                    LocalPlayer():Notify("Code cannot be empty.")
                    return
                end

                net.Start("ixDoorLocks_SubmitCode")
                    net.WriteString(lockID)
                    net.WriteString("change_manager")
                    net.WriteString(code1)
                net.SendToServer()

                codeFrame:Close()
                frame:Close()
            end
        end

        local clearUsers = vgui.Create("DButton", frame)
        clearUsers:Dock(TOP)
        clearUsers:DockMargin(8, 4, 8, 0)
        clearUsers:SetText("Clear User List")

        function clearUsers:DoClick()
            Derma_Query("Are you sure you wish to clear the user list?", "Confirm Clear Users",
                "Yes", function()
                    net.Start("ixDoorLocks_SubmitCode")
                        net.WriteString(lockID)
                        net.WriteString("clear_users")
                        net.WriteString("")
                    net.SendToServer()

                    frame:Close()
                end,
                "No", function() end
            )
        end
    end

    -- Mode action button for non-code modes
    if (mode ~= "code") then
        if (mode == "biometric") then
            -- Regular pairing button (for managers or masters)
            if (isBioManager or hasMaster) then
                local regularPairing = vgui.Create("DButton", frame)
                regularPairing:Dock(TOP)
                regularPairing:DockMargin(8, 4, 8, 0)
                regularPairing:SetText("Start Regular Pairing")

                function regularPairing:DoClick()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("mode_action")
                        net.WriteString(lockID)
                    net.SendToServer()

                    frame:Close()
                end
            end

            -- Manager-only buttons (for managers or masters)
            if (isBioManager or hasMaster) then
                local managerPairing = vgui.Create("DButton", frame)
                managerPairing:Dock(TOP)
                managerPairing:DockMargin(8, 4, 8, 0)
                managerPairing:SetText("Start Manager Pairing")

                function managerPairing:DoClick()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("biometric_manager_pairing")
                        net.WriteString(lockID)
                    net.SendToServer()

                    frame:Close()
                end

                local viewUsers = vgui.Create("DButton", frame)
                viewUsers:Dock(TOP)
                viewUsers:DockMargin(8, 4, 8, 0)
                viewUsers:SetText("View User List")

                function viewUsers:DoClick()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("biometric_view_users")
                        net.WriteString(lockID)
                    net.SendToServer()

                    frame:Close()
                end

                local clearUsers = vgui.Create("DButton", frame)
                clearUsers:Dock(TOP)
                clearUsers:DockMargin(8, 4, 8, 0)
                clearUsers:SetText("Clear User List")

                function clearUsers:DoClick()
                    Derma_Query("Are you sure you wish to clear the biometric user list?", "Confirm Clear Users",
                        "Yes", function()
                            net.Start("ixDoorLocks_DoAction")
                                net.WriteString("biometric_clear_users")
                                net.WriteString(lockID)
                            net.SendToServer()

                            frame:Close()
                        end,
                        "No", function() end
                    )
                end
            end
        elseif (mode == "keycard") then
            -- For keycard locks, non-admins only see buttons if they have manager/master keycard
            -- Print Keycard button (for master/manager keycard holders)
            if (isKeycardManager) then
                local modeButton = vgui.Create("DButton", frame)
                modeButton:Dock(TOP)
                modeButton:DockMargin(8, 4, 8, 0)
                modeButton:SetText("Print Keycard")

                function modeButton:DoClick()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("mode_action")
                        net.WriteString(lockID)
                    net.SendToServer()

                    frame:Close()
                end
            end

            -- View Keycards button (for master/manager keycard holders)
            if (isKeycardManager) then
                local viewKeycards = vgui.Create("DButton", frame)
                viewKeycards:Dock(TOP)
                viewKeycards:DockMargin(8, 4, 8, 0)
                viewKeycards:SetText("View Keycards")

                function viewKeycards:DoClick()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("keycard_view")
                        net.WriteString(lockID)
                    net.SendToServer()

                    frame:Close()
                end
            end
        end
    end

    -- Remove Lock button
    -- For keycard locks: master tier keycard holders can remove
    -- For other locks: masters (installers/admins) can remove
    local canRemoveLock = false
    if (mode == "keycard") then
        canRemoveLock = isKeycardMaster
    else
        canRemoveLock = hasMaster
    end

    if (canRemoveLock) then
        local remove = vgui.Create("DButton", frame)
        remove:Dock(TOP)
        remove:DockMargin(8, 4, 8, 0)
        remove:SetText("Remove Lock")

        function remove:DoClick()
            Derma_Query("Are you sure you wish to remove this lock?", "Confirm Removal",
                "Yes", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("remove")
                        net.WriteString(lockID)
                    net.SendToServer()

                    frame:Close()
                end,
                "No", function() end
            )
        end
    end

    -- Group code management buttons (masters only)
    -- For keycard locks, require master tier keycard; for other locks, require master access
    local canManageGroup = false
    if (mode == "keycard") then
        canManageGroup = isKeycardMaster
    else
        canManageGroup = hasMaster
    end
    
    if (canManageGroup) then
        local setGroupCode = vgui.Create("DButton", frame)
        setGroupCode:Dock(TOP)
        setGroupCode:DockMargin(8, 4, 8, 0)
        setGroupCode:SetText("Set Group Code")

        function setGroupCode:DoClick()
            Derma_StringRequest("Set Group Code", 
                "Enter a group code to link this lock with others of the same mode.\nLeave empty to clear.\n(Alphanumeric, max 32 chars)",
                "",
                function(text)
                    net.Start("ixDoorLocks_SetGroupCode")
                        net.WriteString(lockID)
                        net.WriteString(text or "")
                    net.SendToServer()

                    frame:Close()
                end,
                function() end
            )
        end

        local clearGroupCode = vgui.Create("DButton", frame)
        clearGroupCode:Dock(TOP)
        clearGroupCode:DockMargin(8, 4, 8, 0)
        clearGroupCode:SetText("Clear Group Code")

        function clearGroupCode:DoClick()
            net.Start("ixDoorLocks_ClearGroupCode")
                net.WriteString(lockID)
            net.SendToServer()

            frame:Close()
        end

        local viewGroupLocks = vgui.Create("DButton", frame)
        viewGroupLocks:Dock(TOP)
        viewGroupLocks:DockMargin(8, 4, 8, 0)
        viewGroupLocks:SetText("View Group Locks")

        function viewGroupLocks:DoClick()
            net.Start("ixDoorLocks_ViewGroupLocks")
                net.WriteString(lockID)
            net.SendToServer()

            frame:Close()
        end
    end

    -- Admin buttons (mode-specific)
    if (isAdmin) then
        if (mode == "code") then
            local adminMaster = vgui.Create("DButton", frame)
            adminMaster:Dock(TOP)
            adminMaster:DockMargin(8, 4, 8, 0)
            adminMaster:SetText("Admin: Master on Self")

            function adminMaster:DoClick()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("admin_master_self")
                    net.WriteString(lockID)
                net.SendToServer()

                frame:Close()
            end
        elseif (mode == "keycard") then
            -- Admin buttons for keycard locks: Print Story Card, Print Master Card, Remove Lock
            local storyCardButton = vgui.Create("DButton", frame)
            storyCardButton:Dock(TOP)
            storyCardButton:DockMargin(8, 4, 8, 0)
            storyCardButton:SetText("Admin: Print Story Card")

            function storyCardButton:DoClick()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("keycard_story_menu")
                    net.WriteString(lockID)
                net.SendToServer()

                frame:Close()
            end

            local adminPrintMaster = vgui.Create("DButton", frame)
            adminPrintMaster:Dock(TOP)
            adminPrintMaster:DockMargin(8, 4, 8, 0)
            adminPrintMaster:SetText("Admin: Print Master Card")

            function adminPrintMaster:DoClick()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("admin_print_master")
                    net.WriteString(lockID)
                net.SendToServer()

                frame:Close()
            end
        elseif (mode == "biometric") then
            local adminMaster = vgui.Create("DButton", frame)
            adminMaster:Dock(TOP)
            adminMaster:DockMargin(8, 4, 8, 0)
            adminMaster:SetText("Admin: Master on Self")

            function adminMaster:DoClick()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("admin_master_self")
                    net.WriteString(lockID)
                net.SendToServer()

                frame:Close()
            end
        end

        local adminRemove = vgui.Create("DButton", frame)
        adminRemove:Dock(TOP)
        adminRemove:DockMargin(8, 4, 8, 8)
        adminRemove:SetText("Admin: Remove Lock")

        function adminRemove:DoClick()
            Derma_Query("Are you sure you wish to remove this lock with admin commands?", "Confirm Admin Removal",
                "Yes", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("admin_remove")
                        net.WriteString(lockID)
                    net.SendToServer()

                    frame:Close()
                end,
                "No", function() end
            )
        end
    end
end

net.Receive("ixDoorLocks_OpenMenu", function()
    local door = net.ReadEntity()
    local lockID = net.ReadString()
    local isDeadlock = net.ReadBool()
    local lockType = net.ReadString()
    local mode = net.ReadString()
    local isLocked = net.ReadBool()
    local isManager = net.ReadBool()
    local isBio = net.ReadBool()
    local isBioManager = net.ReadBool()
    local hasManager = net.ReadBool()
    local hasMaster = net.ReadBool()
    local hasKeycard = net.ReadBool()
    local isKeycardMaster = net.ReadBool()
    local isKeycardManager = net.ReadBool()
    local isAdmin = net.ReadBool()
    local isAdminDeactivated = net.ReadBool()

    OpenLockMenu(door, lockID, isDeadlock, lockType, mode, isLocked, isManager, isBio, isBioManager, hasManager, hasMaster, hasKeycard, isKeycardMaster, isKeycardManager, isAdmin, isAdminDeactivated)
end)

-- Play sound from server
net.Receive("ixDoorLocks_PlaySound", function()
    local soundPath = net.ReadString()
    if (soundPath) then
        surface.PlaySound(soundPath)
    end
end)

-- Biometric user list viewer
net.Receive("ixDoorLocks_BiometricUserList", function()
    local lockID = net.ReadString()
    local door = net.ReadEntity() -- Door entity for Back button
    local canRemoveMasters = net.ReadBool() -- All masters can remove other masters
    local currentUserID = net.ReadUInt(32) -- Current user's ID to prevent self-removal
    local isAdmin = net.ReadBool() -- Admin status
    local users = net.ReadTable()

    -- Close existing menu if open
    if (IsValid(activeBiometricMenu)) then
        activeBiometricMenu:Close()
        activeBiometricMenu = nil
    end

    local frame = vgui.Create("DFrame")
    frame:SetTitle("Biometric User List")
    frame:SetSize(500, 450) -- Increased width to fit all buttons
    frame:Center()
    frame:MakePopup()
    
    -- Store reference and clean up on close
    activeBiometricMenu = frame
    function frame:OnClose()
        if (activeBiometricMenu == self) then
            activeBiometricMenu = nil
        end
    end

    local scroll = vgui.Create("DScrollPanel", frame)
    scroll:Dock(FILL)
    scroll:DockMargin(8, 8, 8, 8)

    if (#users == 0) then
        local noUsers = vgui.Create("DLabel", scroll)
        noUsers:Dock(TOP)
        noUsers:DockMargin(8, 8, 8, 8)
        noUsers:SetText("No biometric users registered.")
        noUsers:SizeToContents()
    end

    for _, user in ipairs(users) do
        local panel = vgui.Create("DPanel", scroll)
        panel:Dock(TOP)
        panel:SetHeight(35)
        panel:DockMargin(0, 0, 0, 4)

        local isSelf = (user.id == currentUserID)
        
        -- Name label with color coding
        local label = vgui.Create("DLabel", panel)
        label:Dock(LEFT)
        local tierText = ""
        local tierColor = Color(255, 255, 255) -- Default white
        
        if (user.isMaster) then
            tierText = " (Master)"
            tierColor = Color(255, 215, 0) -- Gold for master
        elseif (user.isManager) then
            tierText = " (Manager)"
            tierColor = Color(100, 149, 237) -- Cornflower blue for manager
        elseif (user.isInactive) then
            tierText = " (Inactive)"
            tierColor = Color(128, 128, 128) -- Gray for inactive
        else
            tierText = " (User)"
            tierColor = Color(200, 200, 200) -- Light gray for user
        end
        
        label:SetText(user.name .. tierText)
        label:SetTextColor(tierColor)
        label:SizeToContents()
        label:DockMargin(8, 0, 0, 0)

        -- Remove button (rightmost)
        -- Show remove button if: can remove masters (installer), or if target is not a manager/master, or if admin
        local canRemove = canRemoveMasters or (not user.isManager and not user.isMaster) or isAdmin
        if (canRemove) then
            local remove = vgui.Create("DButton", panel)
            remove:Dock(RIGHT)
            remove:SetWide(60)
            remove:SetText("Remove")
            -- Allow managers to remove themselves, but not masters
            remove:SetEnabled(not isSelf or (isSelf and user.isManager and not user.isMaster))

            function remove:DoClick()
                Derma_Query("Are you sure you wish to delete this user?", "Confirm User Removal",
                    "Yes", function()
                        net.Start("ixDoorLocks_DoAction")
                            net.WriteString("biometric_remove_user")
                            net.WriteString(lockID)
                            net.WriteUInt(user.id, 32)
                        net.SendToServer()
                        -- Don't close menu - keep it open
                    end,
                    "No", function() end
                )
            end
        end

        -- Activate/Deactivate button (always visible, but enabled based on permissions)
        -- Admins can always use it, others need proper permissions
        local toggleActive = vgui.Create("DButton", panel)
        toggleActive:Dock(RIGHT)
        toggleActive:SetWide(80)
        toggleActive:SetText(user.isInactive and "Activate" or "Deactivate")
        -- Enable if: admin, or not self, or has proper permissions (handled server-side)
        toggleActive:SetEnabled(not isSelf or isAdmin)

        function toggleActive:DoClick()
            net.Start("ixDoorLocks_DoAction")
                net.WriteString("biometric_toggle_active")
                net.WriteString(lockID)
                net.WriteUInt(user.id, 32)
            net.SendToServer()
            -- Don't close menu - keep it open
        end

        -- Demote button (only for masters, only if target is manager or master)
        if (canRemoveMasters and (user.isManager or user.isMaster)) then
            local demote = vgui.Create("DButton", panel)
            demote:Dock(RIGHT)
            demote:SetWide(70)
            demote:SetText("Demote")
            demote:SetEnabled(not isSelf and not user.isMaster) -- Can't demote masters (installers)

            function demote:DoClick()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("biometric_demote_user")
                    net.WriteString(lockID)
                    net.WriteUInt(user.id, 32)
                net.SendToServer()
                -- Don't close menu - keep it open
            end
        end

        -- Promote button (only for non-masters and non-managers)
        if (canRemoveMasters and not user.isManager and not user.isMaster) then
            local promote = vgui.Create("DButton", panel)
            promote:Dock(RIGHT)
            promote:SetWide(70)
            promote:SetText("Promote")
            promote:SetEnabled(not isSelf)

            function promote:DoClick()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("biometric_promote_user")
                    net.WriteString(lockID)
                    net.WriteUInt(user.id, 32)
                net.SendToServer()
                -- Don't close menu - keep it open
            end
        end

    end

    -- Back button to return to main menu
    local back = vgui.Create("DButton", frame)
    back:Dock(BOTTOM)
    back:DockMargin(8, 4, 8, 4)
    back:SetText("Back")

    function back:DoClick()
        frame:Close()
        -- Request main menu again by sending the door entity
        if (IsValid(door)) then
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end
    end

    local close = vgui.Create("DButton", frame)
    close:Dock(BOTTOM)
    close:DockMargin(8, 4, 8, 8)
    close:SetText("Close")

    function close:DoClick()
        frame:Close()
    end
end)

-- Keycard print menu
net.Receive("ixDoorLocks_KeycardPrintMenu", function()
    local lockID = net.ReadString()
    local canPrintInstaller = net.ReadBool()

    local frame = vgui.Create("DFrame")
    frame:SetTitle("Print Keycard")
    frame:SetSize(300, 220)
    frame:Center()
    frame:MakePopup()

    local accessLabel = vgui.Create("DLabel", frame)
    accessLabel:SetText("Access Level:")
    accessLabel:Dock(TOP)
    accessLabel:DockMargin(8, 8, 8, 4)

    local accessCombo = vgui.Create("DComboBox", frame)
    accessCombo:Dock(TOP)
    accessCombo:DockMargin(8, 0, 8, 4)
    accessCombo:SetValue("User")
    accessCombo:AddChoice("User")
    accessCombo:AddChoice("Manager")
    if (canPrintInstaller) then
        accessCombo:AddChoice("Master")
    end

    local nameLabel = vgui.Create("DLabel", frame)
    nameLabel:SetText("Card Name:")
    nameLabel:Dock(TOP)
    nameLabel:DockMargin(8, 4, 8, 4)

    local nameEntry = vgui.Create("DTextEntry", frame)
    nameEntry:Dock(TOP)
    nameEntry:DockMargin(8, 0, 8, 4)
    nameEntry:SetPlaceholderText("Enter card name (optional)")

    local confirm = vgui.Create("DButton", frame)
    confirm:Dock(BOTTOM)
    confirm:DockMargin(8, 4, 8, 8)
    confirm:SetText("Print Keycard")

    function confirm:DoClick()
        local cardType = string.lower(accessCombo:GetSelected() or accessCombo:GetValue() or "user")
        local cardName = nameEntry:GetText() or ""

        net.Start("ixDoorLocks_KeycardPrintConfirm")
            net.WriteString(lockID)
            net.WriteString(cardType)
            net.WriteString(cardName)
        net.SendToServer()

        frame:Close()
    end
end)

-- Keycard view menu
net.Receive("ixDoorLocks_KeycardView", function()
    local lockID = net.ReadString()
    local door = net.ReadEntity() -- Door entity for Back button
    local isMaster = net.ReadBool() -- Changed from isInstaller to isMaster
    local userKeyUID = net.ReadString() -- User's keyUID to prevent self-disable
    local cards = net.ReadTable()

    -- Close existing menu if open
    if (IsValid(activeKeycardMenu)) then
        activeKeycardMenu:Close()
        activeKeycardMenu = nil
    end

    local frame = vgui.Create("DFrame")
    frame:SetTitle("Keycard List")
    frame:SetSize(400, 450)
    frame:Center()
    frame:MakePopup()
    
    -- Store reference and clean up on close
    activeKeycardMenu = frame
    function frame:OnClose()
        if (activeKeycardMenu == self) then
            activeKeycardMenu = nil
        end
    end

    local scroll = vgui.Create("DScrollPanel", frame)
    scroll:Dock(FILL)
    scroll:DockMargin(8, 8, 8, 8)

    for _, card in ipairs(cards) do
        local panel = vgui.Create("DPanel", scroll)
        panel:Dock(TOP)
        panel:SetHeight(40)
        panel:DockMargin(0, 0, 0, 4)

        local cardName = card.cardName and card.cardName ~= "" and card.cardName or ""
        local displayName = string.format("Serial %d", card.serialNumber)
        if (cardName ~= "") then
            displayName = displayName .. " - " .. cardName
        end
        
        -- Handle old "installer" type as "master" for display
        local cardType = card.cardType == "installer" and "master" or card.cardType
        local typeName = string.upper(string.sub(cardType, 1, 1)) .. string.sub(cardType, 2)
        
        -- Color coding for tiers
        local tierColor = Color(255, 255, 255) -- Default white
        if (cardType == "master") then
            tierColor = Color(255, 215, 0) -- Gold for master
        elseif (cardType == "manager") then
            tierColor = Color(100, 149, 237) -- Cornflower blue for manager
        else
            tierColor = Color(200, 200, 200) -- Light gray for user
        end
        
        displayName = displayName .. " (" .. typeName .. ")"

        local label = vgui.Create("DLabel", panel)
        label:Dock(LEFT)
        label:SetText(displayName)
        label:SetTextColor(tierColor)
        label:SizeToContents()
        label:DockMargin(8, 0, 0, 0)

        local statusLabel = vgui.Create("DLabel", panel)
        statusLabel:Dock(LEFT)
        statusLabel:SetText(card.active and " [Active]" or " [Inactive]")
        statusLabel:SetTextColor(card.active and Color(0, 255, 0) or Color(255, 0, 0))
        statusLabel:SizeToContents()
        statusLabel:DockMargin(8, 0, 0, 0)
        
        -- Show [GROUP] marker for keycards from other locks in the group
        if (card.isFromGroup) then
            local groupLabel = vgui.Create("DLabel", panel)
            groupLabel:Dock(LEFT)
            groupLabel:SetText(" [GROUP]")
            groupLabel:SetTextColor(Color(255, 20, 147)) -- Hot pink
            groupLabel:SizeToContents()
            groupLabel:DockMargin(8, 0, 0, 0)
        end

        -- Deactivate/Reactivate button
        local actionBtn = vgui.Create("DButton", panel)
        actionBtn:Dock(RIGHT)
        actionBtn:SetWide(80)
        actionBtn:SetText(card.active and "Deactivate" or "Reactivate")
        
        -- Handle old "installer" type as "master"
        local cardType = card.cardType == "installer" and "master" or card.cardType
        
        -- Prevent disabling your own card
        local isSelfCard = (card.keyUID == userKeyUID)
        
        -- Only master card holders can reactivate
        if (not card.active) then
            actionBtn:SetEnabled(isMaster) -- Only master card holders can reactivate
        else
            -- Masters can deactivate other masters and managers, but not themselves
            if (isSelfCard) then
                actionBtn:SetEnabled(false) -- Cannot deactivate your own card
            elseif (cardType == "master" or cardType == "manager") then
                actionBtn:SetEnabled(isMaster) -- Only masters can deactivate master/manager cards
            else
                actionBtn:SetEnabled(isMaster) -- Only masters can deactivate user cards
            end
        end

        function actionBtn:DoClick()
            local action = card.active and "deactivate" or "reactivate"
            net.Start("ixDoorLocks_KeycardManage")
                net.WriteString(lockID)
                net.WriteString(card.keyUID)
                net.WriteString(action)
            net.SendToServer()
            -- Don't close menu - keep it open
        end
    end

    -- Back button to return to main menu
    local back = vgui.Create("DButton", frame)
    back:Dock(BOTTOM)
    back:DockMargin(8, 4, 8, 4)
    back:SetText("Back")

    function back:DoClick()
        frame:Close()
        -- Request main menu again by sending the door entity
        if (IsValid(door)) then
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end
    end

    local close = vgui.Create("DButton", frame)
    close:Dock(BOTTOM)
    close:DockMargin(8, 4, 8, 8)
    close:SetText("Close")

    function close:DoClick()
        frame:Close()
    end
end)

-- Story card print menu
net.Receive("ixDoorLocks_KeycardStoryMenu", function()
    local lockID = net.ReadString()

    local frame = vgui.Create("DFrame")
    frame:SetTitle("Print Story Card")
    frame:SetSize(300, 280)
    frame:Center()
    frame:MakePopup()

    local typeLabel = vgui.Create("DLabel", frame)
    typeLabel:SetText("Story Card Type:")
    typeLabel:Dock(TOP)
    typeLabel:DockMargin(8, 8, 8, 4)

    local typeCombo = vgui.Create("DComboBox", frame)
    typeCombo:Dock(TOP)
    typeCombo:DockMargin(8, 0, 8, 4)
    typeCombo:SetValue("Air Key")
    typeCombo:AddChoice("Air Key")
    typeCombo:AddChoice("Earth Key")
    typeCombo:AddChoice("Fire Key")
    typeCombo:AddChoice("Water Key")
    typeCombo:AddChoice("Gold Key")

    local confirm = vgui.Create("DButton", frame)
    confirm:Dock(BOTTOM)
    confirm:DockMargin(8, 4, 8, 8)
    confirm:SetText("Print Story Card")

    function confirm:DoClick()
        local selected = typeCombo:GetSelected() or typeCombo:GetValue() or "Air Key"
        local storyCardType = string.lower(string.match(selected, "^(%w+)")) -- Extract first word and lowercase

        net.Start("ixDoorLocks_KeycardStoryConfirm")
            net.WriteString(lockID)
            net.WriteString(storyCardType)
        net.SendToServer()

        frame:Close()
    end
end)

-- R key handler for doors with locks (reload key to open lock menu - double tap only)
-- Track last R key press/release time for double-tap detection
local lastReloadPress = 0
local lastReloadRelease = 0
local lastReloadAction = 0 -- Track last action time to prevent spam
local RELOAD_DOUBLE_TAP_TIME = 0.3 -- 300ms window for double-tap
local RELOAD_DEBOUNCE_TIME = 0.1 -- 100ms debounce to prevent spam

-- Track press time to detect quick taps vs holds
hook.Add("KeyPress", "ixDoorLocks_ReloadKeyPress", function(client, key)
    if (key ~= IN_RELOAD) then return end
    if (not IsValid(client) or client ~= LocalPlayer()) then return end
    
    lastReloadPress = CurTime()
end)

-- Handle releases to detect double-tap for config menu
hook.Add("KeyRelease", "ixDoorLocks_ReloadKeyRelease", function(client, key)
    if (key ~= IN_RELOAD) then return end
    if (not IsValid(client) or client ~= LocalPlayer()) then return end

    local currentTime = CurTime()
    
    -- Debounce to prevent spam
    if (currentTime - lastReloadAction < RELOAD_DEBOUNCE_TIME) then
        return
    end

    local trace = client:GetEyeTrace()
    if (not trace or not trace.Hit) then return end

    local door = trace.Entity
    if (not IsValid(door) or not door:IsDoor()) then return end

    local timeSinceLastRelease = currentTime - lastReloadRelease
    
    -- Check if this is a double-tap (within 300ms)
    if (timeSinceLastRelease < RELOAD_DOUBLE_TAP_TIME and timeSinceLastRelease > 0) then
        -- Double-tap: open config menu
        net.Start("ixDoorLocks_RequestMenu")
            net.WriteEntity(door)
        net.SendToServer()
        lastReloadRelease = 0 -- Reset to prevent triple-tap
        lastReloadAction = currentTime
    else
        -- Single tap - do nothing (quick toggle removed for now)
        lastReloadRelease = currentTime
    end
end)




