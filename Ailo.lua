-- locals, helperfunctions
local string_gsub, string_format, strfind, tsort, tinsert = string.gsub, string.format, strfind, table.sort, table.insert
local wipe = wipe

-- LibDataBroker
local ldb = LibStub:GetLibrary("LibDataBroker-1.1", true)
local LDBIcon = ldb and LibStub("LibDBIcon-1.0",true)
local LibQTip = LibStub('LibQTip-1.0')
local Ailo = LibStub("AceAddon-3.0"):NewAddon("Ailo", "AceConsole-3.0", "AceEvent-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("Ailo", false)
local DB_VERSION = 3
local currentChar, currentRealm, currentCharRealm, currentMaxLevel

-- Sorting
local sortRealms = {}
local sortRealmsPlayer = {}

local function setColor(info, r, g, b, a)
    Ailo.db.profile[info[#info]] = { r = r, g = g, b = b, a = a }
end

local function getColor(info)
    return Ailo.db.profile[info[#info]].r, Ailo.db.profile[info[#info]].g, Ailo.db.profile[info[#info]].b, Ailo.db.profile[info[#info]].a
end

local defaults = {
    profile = {
        savedraid = { r=1, g=0, b=0, a=1 },
        freeraid  = { r=0, g=1, b=0, a=1 },
        hc = "hc",
        nhc = "nhc",
        show5Man = false,
        showAllChars = false,
        showCharacterRealm = false,
        showDailyHeroic = true,
        showMessages = true,
        showRealmHeaderLines = false,
        showWeeklyRaid = true,
        showWGVictory = false,
        showDailyPVP = false,
        useClassColors = true,
        useCustomClassColors = true,
        instanceAbbr = {},
        minimapIcon = {
            hide = false,
            minimapPos = 220,
            radius = 80,
        },
        
    },
    global = {
        chars = {},
        charClass = {},
        raids = {},
        nextPurge = 0,
        version = 0,
    },
}


function Ailo:OnInitialize()

    currentMaxLevel = MAX_PLAYER_LEVEL_TABLE[#MAX_PLAYER_LEVEL_TABLE]
    currentChar = UnitName("player")
    currentRealm = GetRealmName()
    currentCharRealm = currentChar..' - '..currentRealm

    if currentMaxLevel == UnitLevel("player") then 
        self:RegisterEvent("CHAT_MSG_SYSTEM")
        self:RegisterEvent("UPDATE_INSTANCE_INFO")
        self:RegisterEvent("LFG_COMPLETION_REWARD")
        self:RegisterEvent("LFG_UPDATE_RANDOM_INFO")
        self:RegisterEvent("QUEST_QUERY_COMPLETE")
    end
    
    
    self.db = LibStub("AceDB-3.0"):New("AiloDB", defaults, true)
    LibStub("AceConfig-3.0"):RegisterOptionsTable("Ailo", self.GenerateOptions)

    if not self.db.global.version or DB_VERSION > self.db.global.version then
        self:Output(L["DB_VERSION_UPGRADE_PURGE"])
        Ailo:WipeDB()
        self.db.global.version = DB_VERSION 
    end

    local AiloLDB = ldb:NewDataObject("Ailo", {
        type = "data source",
        text = "Ailo",
        icon = "Interface\\Icons\\Achievement_Dungeon_UlduarRaid_Archway_01.png",
        OnClick = function(clickedframe, button)
            if button == "RightButton" then 
                InterfaceOptionsFrame_OpenToCategory(Ailo.optionsFrame) 
            else 
                if IsShiftKeyDown() then
                    Ailo:ManualPlayerUpdate() 
                else
                    ToggleFriendsFrame(5)
                end
            end
        end,
        OnEnter = function(tt)
            local tooltip = LibQTip:Acquire("AiloTooltip", 1, "LEFT") 
            Ailo.tooltip = tooltip
            Ailo:PrepareTooltip(tooltip) 
            tooltip:SmartAnchorTo(tt)
            tooltip:Show()
        end,
        OnLeave = function(tt)
            LibQTip:Release(Ailo.tooltip)
            Ailo.tooltip = nil
        end,
    })

    LDBIcon:Register("Ailo", AiloLDB, self.db.profile.minimapIcon)
    -- Request saved raidID's for this char
    -- Will trigger UPDATE_INSTANCE_INFO when after the data is recieved
    RequestRaidInfo()
    self:SetupClasscoloredFonts()
    if CUSTOM_CLASS_COLORS then
        CUSTOM_CLASS_COLORS:RegisterCallback("SetupClasscoloredFonts", self)
    end
end

local RAID_CLASS_COLORS_FONTS = {}

function Ailo:SetupClasscoloredFonts()
    local class, color, CHOOSEN_CLASS_COLORS

    if self.db.profile.useCustomClassColors and CUSTOM_CLASS_COLORS then
        CHOOSEN_CLASS_COLORS = CUSTOM_CLASS_COLORS
    else
        CHOOSEN_CLASS_COLORS = RAID_CLASS_COLORS
    end
    for class,color in pairs(CHOOSEN_CLASS_COLORS) do
        if not RAID_CLASS_COLORS_FONTS[class] then 
            RAID_CLASS_COLORS_FONTS[class] = CreateFont("ClassFont"..class)
            RAID_CLASS_COLORS_FONTS[class]:CopyFontObject(GameTooltipText)
        end
        RAID_CLASS_COLORS_FONTS[class]:SetTextColor(color.r, color.g, color.b)
    end
end

function Ailo:GenerateOptions()
    Ailo.options = {
        name = "Ailo",
        type = 'group',
        args = {
            genconfig = {
                name = L["General Settings"],
                type = 'group',
                order = 1,
                get = function(info) return Ailo.db.profile[info[#info]] end,
                set = function(info, value) Ailo.db.profile[info[#info]] = value end,
                args = {
                    savedraid = {
                        name = L["Saved raid color"],
                        desc = L["SAVED_RAID_DESC"],
                        type = 'color',
                        order = 1,
                        get  = getColor,
                        set  = setColor,
                        hasAlpha = true,
                    },
                    freeraid = {
                        name = L["Free raid color"],
                        desc = L["FREE_RAID_DESC"],
                        type = 'color',
                        order = 2,
                        get  = getColor,
                        set  = setColor,
                        hasAlpha = true,
                    },
                    useClassColors = {
                        type = "toggle",
                        order = 3,
                        name = L["Color names by class"],
                    },
                    useCustomClassColors = {
                        type = "toggle",
                        order = 4,
                        name = L["Use !ClassColors"],
                        desc = L["Use !ClassColors addon for class colors used to color the names in the tooltip"],
                        get = function(info) return Ailo.db.profile[info[#info]] end,
                        set = function(info, value) 
                            Ailo.db.profile[info[#info]] = value 
                            Ailo:SetupClasscoloredFonts()
                        end,
                        disabled = function() return not Ailo.db.profile.useClassColors or not CUSTOM_CLASS_COLORS end,
                    },
                    showCharacterRealm = {
                        name = L["Show character realms"],
                        type = "toggle",
                        order = 5,
                    },
                    minimapIcon = {
                        type = "toggle",
                        name = L["Show minimap button"],
                        desc = L["Show the Ailo minimap button"],
                        order = 6,
                        get = function(info) return not Ailo.db.profile.minimapIcon.hide end,
                        set = function(info, value)
                            Ailo.db.profile.minimapIcon.hide = not value
                            if value then LDBIcon:Show("Ailo") else LDBIcon:Hide("Ailo") end
                        end,
                    },
                    hc = {
                        type = "input",
                        order = 7,
                        name = L["Tooltip abbreviation used for heroic raids"],
                        width = "double",
                    },
                    nhc = {
                        type = "input",
                        order = 8,
                        name = L["Tooltip abbreviation used for nonheroic raids"],
                        width = "double",
                    },
                    show5Man = {
                        type = "toggle",
                        order = 9,
                        name = L["Show 5-man instances"],
                    },
                    showDailyHeroic = {
                        type = "toggle",
                        order = 10,
                        name = L["Track 'Daily Heroic'"],
                        desc = L["TRACK_DAILY_HEROIC_DESC"],
                    },
                    showWeeklyRaid  = {
                        type = "toggle",
                        order = 11,
                        name = L["Track 'Weekly Raid'"],
                        desc = L["If the character has done the 'Weekly Raid' you get in Dalaran"],
                    },
                    showWGVictory  = {
                        type = "toggle",
                        order = 12,
                        name = L["Track 'WG Victory'"],
                        desc = L["If the character has done the 'Victory in Wintergrasp' weekly pvp quest"],
                    },
                    showDailyPVP  = {
                        type = "toggle",
                        order = 13,
                        name = L["Track PvP daily"],
                    },
                    showRealmHeaderLines  = {
                        type = "toggle",
                        order = -4,
                        name = L["Show Realm Headers"],
                        desc = L["SHOW_REALMLINES_DESC"],
                    },                    
                    showAllChars  = {
                        type = "toggle",
                        order = -3,
                        name = L["Show all chars"],
                        desc = L["Regardles of any saved instances"],
                    },                    

                    wipeDB = {
                        type = "execute",
                        name = L["Wipe Database"],
                        order = -2,
                        confirm = true,
                        func = function() Ailo:WipeDB() end,
                    },
                    showMessages = {
                        type = "toggle",
                        order = -1,
                        name = L["Chatframe Messages"],
                    },
                },
            },
            instanceAbbr = { 
                type = 'group',
                name = L["Instance Abbreviations"],
                get = function(info) return Ailo.db.profile.instanceAbbr[info[#info]] end,
                set = function(info, value) Ailo.db.profile.instanceAbbr[info[#info]] = value end,
                args = {
                    header = {
                        type = "header",
                        order = 1,
                        name = L["Change the abbreviations used in the tooltip"]
                    },
                },
            },
        },
    }
    local instance, abbr
    for instance, abbr in pairs(Ailo.db.profile.instanceAbbr) do
        Ailo.options.args.instanceAbbr.args[instance] = {
            type = "input",
            name = instance,
        }
    end
    Ailo.options.args.profile = LibStub("AceDBOptions-3.0"):GetOptionsTable(Ailo.db)
    return Ailo.options
end

function Ailo:Output(...)
    if self.db.profile.showMessages then
        Ailo:Print(...)
    end
end 

function Ailo:PrepareTooltip(tooltip)
    local raidorder = {}
    --[[[ Cell are just colored green/red
               ToC       VoA
            10     25   10  25
          hc nhc hc nhc nhc nhc
    Char1 [] [ ] [] [ ] [ ] [ ]
    Char2 [] [ ] [] [ ] [ ] [ ]
    Char3 [] [ ] [] [ ] [ ] [ ]
    ]]--
    local charsdb = self.db.global.chars
    local raidsdb = self.db.global.raids
    
    local nextPurge = self.db.global.nextPurge
    if nextPurge > 0 and time() > nextPurge then
        -- Only search 
        self:PurgeOldRaidIDs()
        self:TrimRaidTable()
        self:CheckDailyHeroicLockouts()
        self.db.global.nextPurge = self:GetNextPurge()
    end

    if next(raidsdb) or self.db.profile.showAllChars or 
       self.db.profile.showDailyHeroic or self.db.profile.showWeeklyRaid or 
       self.db.profile.showWGVictory or self.db.profile.showDailyPVP then
        -- At least one char is saved to some 
        tooltip:AddHeader(L["Raid"]) -- Raid
        tooltip:AddHeader(L["Size"]) -- Size
        tooltip:AddHeader(L["Diff"]) -- Heroic

        local raid, size, difficulties,  difficulty, colcount, numdifficulties, lastcolumn, dailyHeroicColum, weeklyRaidColumn, wgVictoryColumn, dailyPVPColumn
        -- Daily Heroic column
        if self.db.profile.showDailyHeroic then
            dailyHeroicColum = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, dailyHeroicColum, "2")
            tooltip:SetCell(2, dailyHeroicColum, "x")
            tooltip:SetCell(3, dailyHeroicColum, "|TInterface\\Icons\\inv_misc_frostemblem_01:0|t")
        end
        -- Weekly Raid column
        if self.db.profile.showWeeklyRaid then
            weeklyRaidColumn = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, weeklyRaidColumn, "5")
            tooltip:SetCell(2, weeklyRaidColumn, "x")
            tooltip:SetCell(3, weeklyRaidColumn, "|TInterface\\Icons\\inv_misc_frostemblem_01:0|t")
        end
        
        -- PvP Daily column
        if self.db.profile.showDailyPVP then
            dailyPVPColumn = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, dailyPVPColumn, "25")
            tooltip:SetCell(2, dailyPVPColumn, "x")
            tooltip:SetCell(3, dailyPVPColumn, "|TInterface\\PVPFrame\\PVP-ArenaPoints-Icon:0|t")
        end
        -- Wintergrasp Victory column
        if self.db.profile.showWGVictory then
            wgVictoryColumn = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, wgVictoryColumn, "10")
            tooltip:SetCell(2, wgVictoryColumn, "x")
            tooltip:SetCell(3, wgVictoryColumn, "|TInterface\\Icons\\inv_misc_platnumdisks:0|t")
        end
        
        -- Instances with lockouts
        local raidabbr
        for raid, sizes in pairs(raidsdb) do
            colcount = 0 -- Span needed for the 'Raid' cell above the 'Size' cells
            raidabbr = self:GetInstanceAbbr(raid)
            if raidabbr then
                for size, difficulties in pairs(sizes) do
                    numdifficulties = 0 -- Span needed for the 'Size' cell above the 'Difficulty' cells
    
                    if size > 5 or self.db.profile.show5Man then
                        for difficulty, _ in pairs(difficulties) do
                            colcount = colcount +1
                            numdifficulties = numdifficulties +1
            
                            lastcolumn = tooltip:AddColumn("CENTER")
                            tooltip:SetCell(3, lastcolumn, (difficulty > 2 or size==5) and self.db.profile.hc or self.db.profile.nhc)
        
                            raidorder[(string_format("%s.%d.%s", raid, size, difficulty))] = lastcolumn
                        end
                        tooltip:SetCell(2, lastcolumn - numdifficulties+1, size, numdifficulties)
                    end
                end
                if colcount > 0 then
                    tooltip:SetCell(1, lastcolumn - colcount+1, raidabbr, colcount)
                end
            end
        end
        self:BuildSortedKeyTables()
        local iterateRealm, iteratePlayer, nameString, instances, currentInstance, lastline, realmSepPosition, displayedName
        for _,iterateRealm in ipairs(sortRealms) do
            if self.db.profile.showRealmHeaderLines then
                lastline = tooltip:AddLine("")
                tooltip:SetCell(lastline, 1, iterateRealm, nil, "CENTER", tooltip:GetColumnCount())
            end
            for _,iteratePlayer in ipairs(sortRealmsPlayer[iterateRealm]) do
                instances = charsdb[iterateRealm][iteratePlayer]
                if self.db.profile.showAllChars or (instances.lockouts and next(instances.lockouts)) or 
                   instances.dailyheroic or instances.weeklydone or instances.wgvictory or instances.dailypvp then
                    lastline = tooltip:AddLine("")
                    if self.db.profile.showCharacterRealm then
                      nameString = iteratePlayer.." - "..iterateRealm
                    else
                      nameString = iteratePlayer
                    end

                    if self.db.profile.useClassColors then
                        tooltip:SetCell(lastline, 1, nameString, RAID_CLASS_COLORS_FONTS[self.db.global.charClass[iteratePlayer.." - "..iterateRealm]])
                    else
                        tooltip:SetCell(lastline, 1, nameString )
                    end
        
                    for i = tooltip:GetColumnCount(),2,-1 do
                        tooltip:SetCell(lastline, i, "")
                        tooltip:SetCellColor(lastline, i, self.db.profile.freeraid.r, self.db.profile.freeraid.g, self.db.profile.freeraid.b, self.db.profile.freeraid.a)
                    end
                    if dailyHeroicColum and instances.dailyheroic then
                        tooltip:SetCellColor(lastline, dailyHeroicColum, self.db.profile.savedraid.r, self.db.profile.savedraid.g, self.db.profile.savedraid.b, self.db.profile.savedraid.a)
                    end
                    if weeklyRaidColumn and instances.weeklydone then
                        tooltip:SetCellColor(lastline, weeklyRaidColumn, self.db.profile.savedraid.r, self.db.profile.savedraid.g, self.db.profile.savedraid.b, self.db.profile.savedraid.a)
                    
                    end
                    if dailyPVPColumn and instances.dailpvp then
                        tooltip:SetCellColor(lastline, dailyPVPColumn, self.db.profile.savedraid.r, self.db.profile.savedraid.g, self.db.profile.savedraid.b, self.db.profile.savedraid.a)
                    end
                    if wgVictoryColumn and instances.wgvictory then
                        tooltip:SetCellColor(lastline, wgVictoryColumn, self.db.profile.savedraid.r, self.db.profile.savedraid.g, self.db.profile.savedraid.b, self.db.profile.savedraid.a)
                    end
                    if instances.lockouts then
                        for currentInstance, _ in pairs(instances.lockouts) do
                            if raidorder[currentInstance] then
                                tooltip:SetCellColor(lastline, raidorder[currentInstance], self.db.profile.savedraid.r, self.db.profile.savedraid.g, self.db.profile.savedraid.b, self.db.profile.savedraid.a)
                            end
                        end
                    end
                end
            end
        end
    else
        -- No saved raids at all
        tooltip:AddHeader(L["No saved raids found"])
    end
end
function Ailo:BuildSortedKeyTables()
    local c, r
    wipe(sortRealms)
    sortRealms = {}
    wipe(sortRealmsPlayer)
    sortRealmsPlayer = {}
    for r,_ in pairs(self.db.global.chars) do
        tinsert(sortRealms, r)
        sortRealmsPlayer[r] = {}
        for c,_ in pairs(self.db.global.chars[r]) do
            tinsert(sortRealmsPlayer[r],c)
        end
        tsort(sortRealmsPlayer[r])
    end
    tsort(sortRealms)
end

function Ailo:GetInstanceAbbr(instanceName)
    if not self.db.profile.instanceAbbr[instanceName] then
        -- Has no abbreviation yet, try it with a somewhat good guess
        -- Tries to get the first char of every word, does not go well with utf-8 chars
        self.db.profile.instanceAbbr[instanceName] = string_gsub(instanceName, "(%a)[%l%p]*[%s%-]*", "%1")
    end
    
    return ( self.db.profile.instanceAbbr[instanceName] ~= "" and self.db.profile.instanceAbbr[instanceName] or nil )
end

function Ailo:GetNextPurge()
    local charsdb = self.db.global.chars
    local realm, charscurrentPlayer, instances, currentInstance, expireTime
    local nextPurge = 0
    for realm, chars in pairs(charsdb) do 
        for currentPlayer, instances in pairs(chars) do 
            if instances.lockouts then
                for currentInstance, expireTime in pairs(instances.lockouts) do
                    if nextPurge == 0 or nextPurge > expireTime then
                        nextPurge = expireTime
                    end
                end
            end
            if instances.dailyheroic and ( nextPurge == 0 or nextPurge > instances.dailyheroic ) then 
                nextPurge = instances.dailyheroic
            end
        end
    end
    return nextPurge
end

function Ailo:PurgeOldRaidIDs()
    local charsdb = self.db.global.chars
    local realm, currentPlayer, instances, currentInstance, expireTime
    local now = time()
    for realm, chars in pairs(charsdb) do 
        for currentPlayer, instances in pairs(chars) do 
            if instances.lockouts then 
                for currentInstance, expireTime in pairs(instances.lockouts) do
                    if now > expireTime then
                        self.db.global.chars[realm][currentPlayer].lockouts[currentInstance] = nil
                    end
                end
                if not next(charsdb[realm][currentPlayer].lockouts) then 
                    self.db.global.chars[realm][currentPlayer].lockouts = nil
                end
            end
        end
    end
end

function Ailo:ExtendRaidTable(instanceName, size, difficulty)
    -- Save it for the tooltip
    self.db.global.raids[instanceName] = self.db.global.raids[instanceName] or {}
    self.db.global.raids[instanceName][size] =  self.db.global.raids[instanceName][size] or {}
    self.db.global.raids[instanceName][size][difficulty] = true
    
end

function Ailo:TrimRaidTable()
    local charsdb = self.db.global.chars
    local raidsdb = self.db.global.raids
    local currentPlayer, raids, currentInstance
    local raid, sizes, size, difficulties, difficulty, realm, chars, currentPlayer, instances
    local isUsed, raidString = false
    for raid, sizes in pairs(raidsdb) do
        for size, difficulties in pairs(sizes) do
            for difficulty, _ in pairs(difficulties) do
                isUsed = false
                raidString = string_format("%s.%d.%s", raid, size, difficulty)
                for realm, chars in pairs(charsdb) do 
                    for currentPlayer,instances in pairs(chars) do
                        if instances.lockouts and instances.lockouts[raidString] then
                            isUsed = true
                            break
                        end
                    end
                end
                if not isUsed then
                    self:DeleteFromRaidTable(raid, size, difficulty)
                end
            end
        end
    end
end

function Ailo:DeleteFromRaidTable(instanceName, size, difficulty)
    self.db.global.raids[instanceName][size][difficulty] = nil
    if not next(self.db.global.raids[instanceName][size]) then
        self.db.global.raids[instanceName][size] = nil
    end
    if not next(self.db.global.raids[instanceName]) then
        self.db.global.raids[instanceName] = nil
    end
end

function Ailo:ManualPlayerUpdate()
    if currentMaxLevel > UnitLevel("player") then return end
    self:Output(L["Updating data for current player."])
    if not self.db.global.chars[currentRealm] then 
        self.db.global.chars[currentRealm] = {}
    else
        wipe(self.db.global.chars[currentRealm][currentChar])
        self.db.global.chars[currentRealm][currentChar] = nil
    end

    self:TrimRaidTable()
    self:UpdatePlayer()
end

function Ailo:SaveRaidForChar(instance, expireTime, character, realm)
    character = character or currentChar
    realm = realm or currentRealm
    if not self.db.global.chars[realm] then
        self.db.global.chars[realm] = {}
    end
    if not self.db.global.chars[realm][character] then
        self.db.global.chars[realm][character] = {}
    end
    if not self.db.global.chars[realm][character].lockouts then
        self.db.global.chars[realm][character].lockouts = {}
    end

    self.db.global.chars[realm][character].lockouts[instance] = expireTime
    
    if expireTime < self.db.global.nextPurge or self.db.global.nextPurge == 0 then
        self.db.global.nextPurge = expireTime
    end
end

function Ailo:WipeDB()
    if type(self.db.global.chars) == "table" then 
        wipe(self.db.global.chars)
    end
    if type(self.db.global.raids) == "table" then 
        wipe(self.db.global.raids)
    end
    if type(self.db.global.charClass) == "table" then 
        wipe(self.db.global.charClass)
    end
end

function Ailo:UpdatePlayer()
    if currentMaxLevel > UnitLevel("player") then return end
    self.db.global.charClass[currentCharRealm] = select(2,UnitClass('player'))
    local now, index = time()
    local instanceReset, instanceDifficulty, locked, isRaid, maxPlayers
    local instanceNameAbbr, instanceString
    for index=1,GetNumSavedInstances() do
        instanceName, _, instanceReset, instanceDifficulty, locked, _, _, isRaid, maxPlayers, _ = GetSavedInstanceInfo(index)
        if locked then
            instanceString   = string_format("%s.%d.%s", instanceName, maxPlayers, instanceDifficulty)
            self:ExtendRaidTable(instanceName, maxPlayers, instanceDifficulty)
            self:SaveRaidForChar(instanceString, now+instanceReset)
        end
    end
    self:UpdateDailyHeroicForChar()
    
    -- Daily
    self.db.global.chars[currentRealm][currentChar].dailypvp = nil
    self.db.global.chars[currentRealm][currentChar].dailypvp = (GetRandomBGHonorCurrencyBonuses())

    -- Weekly Raid tracking!
    -- The quests from dalaran "<XY> Must Die!"
    QueryQuestsCompleted()
end


Ailo.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Ailo")
function Ailo:UPDATE_INSTANCE_INFO()
    self:UpdatePlayer()
end

local INSTANCE_SAVED = _G["INSTANCE_SAVED"]
function Ailo:CHAT_MSG_SYSTEM(event, msg)
    -- You are now saved to this instances.
    -- Refresh RaidInfo
    if tostring(msg) == INSTANCE_SAVED then
        RequestRaidInfo()
    end
end

function Ailo:CheckDailyHeroicLockouts()
    local charsdb = self.db.global.chars
    local iterateRealm, iteratePlayer, instances, expireTime
    local now = time()
    for iterateRealm, _ in pairs(charsdb) do
        for iteratePlayer, instances in pairs(charsdb[iterateRealm]) do 
            if instances.dailyheroic and now > instances.dailyheroic then
                self.db.global.chars[iterateRealm][iteratePlayer].dailyheroic = nil
            end
        end
    end
end

function Ailo:UpdateDailyHeroicForChar()
    if not self.db.global.chars[currentRealm] then
        self.db.global.chars[currentRealm] = {}
    end
    if not self.db.global.chars[currentRealm][currentChar] then
        self.db.global.chars[currentRealm][currentChar] = {}
    end
    --[[
    GetLFGDungeonRewards(type)
    first return value: true if it was already done in this "Daily Quests"-lockout, false else
    type: 261 WotLK-nhc, 262 WotLK-hc
    ]]--
    if (GetLFGDungeonRewards(262)) then
        local expireTime = time()+GetQuestResetTime()
        self.db.global.chars[currentRealm][currentChar].dailyheroic = expireTime
        if expireTime < self.db.global.nextPurge or self.db.global.nextPurge == 0 then
            self.db.global.nextPurge = expireTime
        end
    else
        self.db.global.chars[currentRealm][currentChar].dailyheroic = nil
    end
   
end
local questscompleted = {}
function Ailo:QUEST_QUERY_COMPLETE()
    GetQuestsCompleted(questscompleted)
    if not self.db.global.chars[currentRealm] then
        self.db.global.chars[currentRealm] = {}
    end
    if not self.db.global.chars[currentRealm][currentChar] then
        self.db.global.chars[currentRealm][currentChar] = {}
    end

    self.db.global.chars[currentRealm][currentChar].weeklydone = nil
    self.db.global.chars[currentRealm][currentChar].wgvictory = nil

    --[[ 13181 and 13183 are horde and alliance versions
    of the Victory in Wintergrasp weekly quest ]]--
    if questscompleted[13181] or questscompleted[13183] then
        self.db.global.chars[currentRealm][currentChar].wgvictory = true
    end

    --[[ ID's of all raid weekly quests:
    24590, 24589, 24588, 24587, 24586, 24585
    24584, 24583, 24582, 24581, 24580, 24579
    ]]--
    for i=24579,24590 do
        if questscompleted[i] then
            self.db.global.chars[currentRealm][currentChar].weeklydone = true
            return
        end
    end
end

function Ailo:LFG_UPDATE_RANDOM_INFO()
    -- See below why we update here
    self:UpdateDailyHeroicForChar()
end

function Ailo:LFG_COMPLETION_REWARD()
    --[[
    Fires when a random dungeon is completed and the achievement-like
    alert window pops up. The problem is that this DOES NOT update
    the return values of GetLFGDungeonRewards(x), those are updated
    when LFG_UPDATE_RANDOM_INFO is recieved, so force the client to
    call for an update
    ]]--
    RequestLFDPlayerLockInfo()
end

