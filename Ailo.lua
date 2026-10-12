-- locals, helperfunctions
local string_gsub, string_format, tsort, tinsert = string.gsub, string.format, table.sort, table.insert
local pairs, ipairs, next, type, select, time = pairs, ipairs, next, type, select, time
local wipe = wipe

-- LibDataBroker
local ldb = LibStub:GetLibrary("LibDataBroker-1.1", true)
local LDBIcon = ldb and LibStub("LibDBIcon-1.0",true)
local LibQTip = LibStub('LibQTip-1.0')
local Ailo = LibStub("AceAddon-3.0"):NewAddon("Ailo", "AceConsole-3.0", "AceEvent-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("Ailo", false)
local DB_VERSION = 3
local currentChar, currentRealm, currentCharRealm, currentMaxLevel

local ONE_WEEK = 7 * 24 * 60 * 60
local QUEST_QUERY_THROTTLE = 60 -- seconds between automatic QueryQuestsCompleted() calls
local lastQuestQuery = 0

-- Sorting (tables are reused between tooltip builds to avoid garbage)
local sortRealms = {}
local sortRealmsPlayer = {}
local sortRaids = {}
local sortSizes = {}
local sortDifficulties = {}
local raidorder = {}

local function setColor(info, r, g, b, a)
    Ailo.db.profile[info[#info]] = { r = r, g = g, b = b, a = a }
end

local function getColor(info)
    local c = Ailo.db.profile[info[#info]]
    return c.r, c.g, c.b, c.a
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
        weeklyReset = {}, -- [realm] = timestamp of the next known weekly reset
        nextPurge = 0,
        version = 0,
    },
}


function Ailo:OnInitialize()

    currentMaxLevel = MAX_PLAYER_LEVEL_TABLE[#MAX_PLAYER_LEVEL_TABLE]
    currentChar = UnitName("player")
    currentRealm = GetRealmName()
    currentCharRealm = currentChar..' - '..currentRealm

    self.db = LibStub("AceDB-3.0"):New("AiloDB", defaults, true)
    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")
    LibStub("AceConfig-3.0"):RegisterOptionsTable("Ailo", self.GenerateOptions)

    if not self.db.global.version or DB_VERSION > self.db.global.version then
        self:Output(L["DB_VERSION_UPGRADE_PURGE"])
        Ailo:WipeDB()
        self.db.global.version = DB_VERSION
    end

    local AiloLDB = ldb:NewDataObject("Ailo", {
        type = "data source",
        text = "Ailo",
        icon = "Interface\\Icons\\Achievement_Dungeon_UlduarRaid_Archway_01",
        OnClick = function(clickedframe, button)
            if button == "RightButton" then
                -- Called twice: the first call on 3.3.5 often only opens the
                -- options window without selecting the category
                InterfaceOptionsFrame_OpenToCategory(Ailo.optionsFrame)
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
            if Ailo.tooltip then
                LibQTip:Release(Ailo.tooltip)
            end
            local tooltip = LibQTip:Acquire("AiloTooltip", 1, "LEFT")
            Ailo.tooltip = tooltip
            Ailo:PrepareTooltip(tooltip)
            tooltip:SmartAnchorTo(tt)
            tooltip:Show()
        end,
        OnLeave = function(tt)
            if Ailo.tooltip then
                LibQTip:Release(Ailo.tooltip)
                Ailo.tooltip = nil
            end
        end,
    })

    LDBIcon:Register("Ailo", AiloLDB, self.db.profile.minimapIcon)
    self:SetupClasscoloredFonts()
    if CUSTOM_CLASS_COLORS then
        CUSTOM_CLASS_COLORS:RegisterCallback("SetupClasscoloredFonts", self)
    end
end

function Ailo:OnEnable()
    -- Drop anything that expired while we were logged out
    self:PurgeExpired()

    if UnitLevel("player") >= currentMaxLevel then
        self:RegisterTrackingEvents()
    else
        self:RegisterEvent("PLAYER_LEVEL_UP")
    end
end

function Ailo:RegisterTrackingEvents()
    self:RegisterEvent("CHAT_MSG_SYSTEM")
    self:RegisterEvent("UPDATE_INSTANCE_INFO")
    self:RegisterEvent("LFG_COMPLETION_REWARD")
    self:RegisterEvent("LFG_UPDATE_RANDOM_INFO")
    self:RegisterEvent("QUEST_QUERY_COMPLETE")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- Request saved raidID's for this char
    -- Will trigger UPDATE_INSTANCE_INFO when after the data is recieved
    RequestRaidInfo()
end

function Ailo:PLAYER_LEVEL_UP(event, level)
    if level and level >= currentMaxLevel then
        self:UnregisterEvent("PLAYER_LEVEL_UP")
        self:RegisterTrackingEvents()
    end
end

function Ailo:OnProfileChanged()
    self:SetupClasscoloredFonts()
    LDBIcon:Refresh("Ailo", self.db.profile.minimapIcon)
end

local RAID_CLASS_COLORS_FONTS = {}

function Ailo:SetupClasscoloredFonts()
    local CHOOSEN_CLASS_COLORS

    if self.db.profile.useCustomClassColors and CUSTOM_CLASS_COLORS then
        CHOOSEN_CLASS_COLORS = CUSTOM_CLASS_COLORS
    else
        CHOOSEN_CLASS_COLORS = RAID_CLASS_COLORS
    end
    for class,color in pairs(CHOOSEN_CLASS_COLORS) do
        -- CUSTOM_CLASS_COLORS also contains its API functions
        if type(color) == "table" and color.r then
            if not RAID_CLASS_COLORS_FONTS[class] then
                RAID_CLASS_COLORS_FONTS[class] = CreateFont("AiloClassFont"..class)
                RAID_CLASS_COLORS_FONTS[class]:CopyFontObject(GameTooltipText)
            end
            RAID_CLASS_COLORS_FONTS[class]:SetTextColor(color.r, color.g, color.b)
        end
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
    for instance in pairs(Ailo.db.profile.instanceAbbr) do
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

local function sortedKeys(t, out)
    wipe(out)
    for k in pairs(t) do
        tinsert(out, k)
    end
    tsort(out)
    return out
end

function Ailo:PrepareTooltip(tooltip)
    --[[[ Cell are just colored green/red
               ToC       VoA
            10     25   10  25
          hc nhc hc nhc nhc nhc
    Char1 [] [ ] [] [ ] [ ] [ ]
    Char2 [] [ ] [] [ ] [ ] [ ]
    Char3 [] [ ] [] [ ] [ ] [ ]
    ]]--
    local profile = self.db.profile
    local charsdb = self.db.global.chars
    local raidsdb = self.db.global.raids

    local nextPurge = self.db.global.nextPurge
    if nextPurge > 0 and time() > nextPurge then
        self:PurgeExpired()
    end

    wipe(raidorder)

    if next(raidsdb) or profile.showAllChars or
       profile.showDailyHeroic or profile.showWeeklyRaid or
       profile.showWGVictory or profile.showDailyPVP then
        -- At least one char is saved to some
        tooltip:AddHeader(L["Raid"]) -- Raid
        tooltip:AddHeader(L["Size"]) -- Size
        tooltip:AddHeader(L["Diff"]) -- Heroic

        local colcount, numdifficulties, lastcolumn, dailyHeroicColum, weeklyRaidColumn, wgVictoryColumn, dailyPVPColumn
        -- Daily Heroic column
        if profile.showDailyHeroic then
            dailyHeroicColum = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, dailyHeroicColum, "2")
            tooltip:SetCell(2, dailyHeroicColum, "x")
            tooltip:SetCell(3, dailyHeroicColum, "|TInterface\\Icons\\inv_misc_frostemblem_01:0|t")
        end
        -- Weekly Raid column
        if profile.showWeeklyRaid then
            weeklyRaidColumn = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, weeklyRaidColumn, "5")
            tooltip:SetCell(2, weeklyRaidColumn, "x")
            tooltip:SetCell(3, weeklyRaidColumn, "|TInterface\\Icons\\inv_misc_frostemblem_01:0|t")
        end

        -- PvP Daily column
        if profile.showDailyPVP then
            dailyPVPColumn = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, dailyPVPColumn, "25")
            tooltip:SetCell(2, dailyPVPColumn, "x")
            tooltip:SetCell(3, dailyPVPColumn, "|TInterface\\PVPFrame\\PVP-ArenaPoints-Icon:0|t")
        end
        -- Wintergrasp Victory column
        if profile.showWGVictory then
            wgVictoryColumn = tooltip:AddColumn("CENTER")
            tooltip:SetCell(1, wgVictoryColumn, "10")
            tooltip:SetCell(2, wgVictoryColumn, "x")
            tooltip:SetCell(3, wgVictoryColumn, "|TInterface\\Icons\\inv_misc_platnumdisks:0|t")
        end

        -- Instances with lockouts, sorted so the column order is stable
        local raidabbr, sizes, difficulties
        for _, raid in ipairs(sortedKeys(raidsdb, sortRaids)) do
            colcount = 0 -- Span needed for the 'Raid' cell above the 'Size' cells
            raidabbr = self:GetInstanceAbbr(raid)
            if raidabbr then
                sizes = raidsdb[raid]
                for _, size in ipairs(sortedKeys(sizes, sortSizes)) do
                    numdifficulties = 0 -- Span needed for the 'Size' cell above the 'Difficulty' cells

                    if size > 5 or profile.show5Man then
                        difficulties = sizes[size]
                        for _, difficulty in ipairs(sortedKeys(difficulties, sortDifficulties)) do
                            colcount = colcount +1
                            numdifficulties = numdifficulties +1

                            lastcolumn = tooltip:AddColumn("CENTER")
                            tooltip:SetCell(3, lastcolumn, (difficulty > 2 or size==5) and profile.hc or profile.nhc)

                            raidorder[(string_format("%s.%d.%s", raid, size, difficulty))] = lastcolumn
                        end
                        if numdifficulties > 0 then
                            tooltip:SetCell(2, lastcolumn - numdifficulties+1, size, numdifficulties)
                        end
                    end
                end
                if colcount > 0 then
                    tooltip:SetCell(1, lastcolumn - colcount+1, raidabbr, colcount)
                end
            end
        end
        self:BuildSortedKeyTables()

        local saved, free = profile.savedraid, profile.freeraid
        local sr, sg, sb, sa = saved.r, saved.g, saved.b, saved.a
        local fr, fg, fb, fa = free.r, free.g, free.b, free.a
        local numColumns = tooltip:GetColumnCount()
        local charClass = self.db.global.charClass
        local instances, lastline, nameString

        for _,iterateRealm in ipairs(sortRealms) do
            if profile.showRealmHeaderLines then
                lastline = tooltip:AddLine("")
                tooltip:SetCell(lastline, 1, iterateRealm, nil, "CENTER", numColumns)
            end
            for _,iteratePlayer in ipairs(sortRealmsPlayer[iterateRealm]) do
                instances = charsdb[iterateRealm][iteratePlayer]
                if profile.showAllChars or (instances.lockouts and next(instances.lockouts)) or
                   instances.dailyheroic or instances.weeklydone or instances.wgvictory or instances.dailypvp then
                    lastline = tooltip:AddLine("")
                    if profile.showCharacterRealm then
                      nameString = iteratePlayer.." - "..iterateRealm
                    else
                      nameString = iteratePlayer
                    end

                    if profile.useClassColors then
                        tooltip:SetCell(lastline, 1, nameString, RAID_CLASS_COLORS_FONTS[charClass[iteratePlayer.." - "..iterateRealm]])
                    else
                        tooltip:SetCell(lastline, 1, nameString )
                    end

                    for i = numColumns,2,-1 do
                        tooltip:SetCell(lastline, i, "")
                        tooltip:SetCellColor(lastline, i, fr, fg, fb, fa)
                    end
                    if dailyHeroicColum and instances.dailyheroic then
                        tooltip:SetCellColor(lastline, dailyHeroicColum, sr, sg, sb, sa)
                    end
                    if weeklyRaidColumn and instances.weeklydone then
                        tooltip:SetCellColor(lastline, weeklyRaidColumn, sr, sg, sb, sa)
                    end
                    if dailyPVPColumn and instances.dailypvp then
                        tooltip:SetCellColor(lastline, dailyPVPColumn, sr, sg, sb, sa)
                    end
                    if wgVictoryColumn and instances.wgvictory then
                        tooltip:SetCellColor(lastline, wgVictoryColumn, sr, sg, sb, sa)
                    end
                    if instances.lockouts then
                        for currentInstance in pairs(instances.lockouts) do
                            if raidorder[currentInstance] then
                                tooltip:SetCellColor(lastline, raidorder[currentInstance], sr, sg, sb, sa)
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
    wipe(sortRealms)
    for r, chars in pairs(self.db.global.chars) do
        tinsert(sortRealms, r)
        sortRealmsPlayer[r] = sortedKeys(chars, sortRealmsPlayer[r] or {})
    end
    tsort(sortRealms)
end

function Ailo:GetInstanceAbbr(instanceName)
    local instanceAbbr = self.db.profile.instanceAbbr
    if not instanceAbbr[instanceName] then
        -- Has no abbreviation yet, try it with a somewhat good guess
        -- Tries to get the first char of every word, does not go well with utf-8 chars
        instanceAbbr[instanceName] = (string_gsub(instanceName, "(%a)[%l%p]*[%s%-]*", "%1"))
    end

    return ( instanceAbbr[instanceName] ~= "" and instanceAbbr[instanceName] or nil )
end

-- Daily/weekly flags are stored as expire timestamps, or 'true' when
-- the expire time is unknown (expires the next time the char logs in)
local TIMED_FLAGS = { "dailyheroic", "dailypvp", "weeklydone", "wgvictory" }

function Ailo:GetNextPurge()
    local nextPurge = 0
    local value
    for realm, chars in pairs(self.db.global.chars) do
        for currentPlayer, instances in pairs(chars) do
            if instances.lockouts then
                for currentInstance, expireTime in pairs(instances.lockouts) do
                    if nextPurge == 0 or nextPurge > expireTime then
                        nextPurge = expireTime
                    end
                end
            end
            for _, flag in ipairs(TIMED_FLAGS) do
                value = instances[flag]
                if type(value) == "number" and ( nextPurge == 0 or nextPurge > value ) then
                    nextPurge = value
                end
            end
        end
    end
    return nextPurge
end

function Ailo:UpdateNextPurge(expireTime)
    if expireTime < self.db.global.nextPurge or self.db.global.nextPurge == 0 then
        self.db.global.nextPurge = expireTime
    end
end

-- Removes expired lockouts and daily/weekly flags, then recalculates the next purge
function Ailo:PurgeExpired()
    local now = time()
    local value
    for realm, chars in pairs(self.db.global.chars) do
        for currentPlayer, instances in pairs(chars) do
            if instances.lockouts then
                for currentInstance, expireTime in pairs(instances.lockouts) do
                    if now > expireTime then
                        instances.lockouts[currentInstance] = nil
                    end
                end
                if not next(instances.lockouts) then
                    instances.lockouts = nil
                end
            end
            for _, flag in ipairs(TIMED_FLAGS) do
                value = instances[flag]
                if type(value) == "number" and now > value then
                    instances[flag] = nil
                end
            end
        end
    end
    self:TrimRaidTable()
    self.db.global.nextPurge = self:GetNextPurge()
end

-- Kept for compatibility with external callers
function Ailo:PurgeOldRaidIDs()
    self:PurgeExpired()
end

function Ailo:CheckDailyHeroicLockouts()
    self:PurgeExpired()
end

function Ailo:ExtendRaidTable(instanceName, size, difficulty)
    -- Save it for the tooltip
    local raids = self.db.global.raids
    raids[instanceName] = raids[instanceName] or {}
    raids[instanceName][size] = raids[instanceName][size] or {}
    raids[instanceName][size][difficulty] = true
end

function Ailo:TrimRaidTable()
    local charsdb = self.db.global.chars
    local raidsdb = self.db.global.raids

    -- Collect every lockout still in use once, instead of scanning all chars per raid
    local used = {}
    for realm, chars in pairs(charsdb) do
        for currentPlayer, instances in pairs(chars) do
            if instances.lockouts then
                for raidString in pairs(instances.lockouts) do
                    used[raidString] = true
                end
            end
        end
    end

    for raid, sizes in pairs(raidsdb) do
        for size, difficulties in pairs(sizes) do
            for difficulty in pairs(difficulties) do
                if not used[string_format("%s.%d.%s", raid, size, difficulty)] then
                    self:DeleteFromRaidTable(raid, size, difficulty)
                end
            end
        end
    end
end

function Ailo:DeleteFromRaidTable(instanceName, size, difficulty)
    local raids = self.db.global.raids
    raids[instanceName][size][difficulty] = nil
    if not next(raids[instanceName][size]) then
        raids[instanceName][size] = nil
    end
    if not next(raids[instanceName]) then
        raids[instanceName] = nil
    end
end

function Ailo:ManualPlayerUpdate()
    if currentMaxLevel > UnitLevel("player") then return end
    self:Output(L["Updating data for current player."])
    local realmdb = self.db.global.chars[currentRealm]
    if realmdb and realmdb[currentChar] then
        wipe(realmdb[currentChar])
        realmdb[currentChar] = nil
    end

    self:TrimRaidTable()
    lastQuestQuery = 0 -- don't throttle a manual update
    -- Ask the server for fresh data, UPDATE_INSTANCE_INFO will call UpdatePlayer()
    RequestRaidInfo()
    self:UpdatePlayer()
end

function Ailo:GetCharDB(character, realm)
    character = character or currentChar
    realm = realm or currentRealm
    local chars = self.db.global.chars
    if not chars[realm] then
        chars[realm] = {}
    end
    if not chars[realm][character] then
        chars[realm][character] = {}
    end
    return chars[realm][character]
end

function Ailo:SaveRaidForChar(instance, expireTime, character, realm)
    local chardb = self:GetCharDB(character, realm)
    if not chardb.lockouts then
        chardb.lockouts = {}
    end

    chardb.lockouts[instance] = expireTime
    self:UpdateNextPurge(expireTime)
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
    self.db.global.nextPurge = 0
end

-- Returns the next weekly reset for the current realm, or nil if unknown.
-- The reset time is learned from raid lockouts, which all expire at the weekly reset
-- (except the 3-day ones like ZA/ZG/AQ20, which are filtered out).
function Ailo:GetWeeklyReset()
    local weeklyReset = self.db.global.weeklyReset
    local reset = weeklyReset[currentRealm]
    if not reset then return nil end
    local now = time()
    while reset <= now do
        reset = reset + ONE_WEEK
    end
    weeklyReset[currentRealm] = reset
    return reset
end

function Ailo:LearnWeeklyReset(secondsLeft, maxPlayers, difficulty)
    -- 25/40-man and heroic raids are always weekly, anything over 3 days must be weekly too
    if maxPlayers == 25 or maxPlayers == 40 or difficulty > 1 or secondsLeft > 3*24*60*60 then
        self.db.global.weeklyReset[currentRealm] = time() + secondsLeft
    end
end

function Ailo:UpdatePlayer()
    if currentMaxLevel > UnitLevel("player") then return end
    self.db.global.charClass[currentCharRealm] = select(2,UnitClass('player'))
    local now = time()
    local chardb = self:GetCharDB()

    -- The server data is authoritative, rebuild this char's lockouts from it so
    -- lockouts that ended early (or were reset) don't stick around
    chardb.lockouts = nil

    local _, instanceName, instanceReset, instanceDifficulty, locked, isRaid, maxPlayers
    for index=1,GetNumSavedInstances() do
        instanceName, _, instanceReset, instanceDifficulty, locked, _, _, isRaid, maxPlayers = GetSavedInstanceInfo(index)
        if locked and instanceName then
            self:ExtendRaidTable(instanceName, maxPlayers, instanceDifficulty)
            self:SaveRaidForChar(string_format("%s.%d.%s", instanceName, maxPlayers, instanceDifficulty), now+instanceReset)
            if isRaid then
                self:LearnWeeklyReset(instanceReset, maxPlayers, instanceDifficulty)
            end
        end
    end
    self:TrimRaidTable()
    self:UpdateDailyHeroicForChar()
    self:UpdateDailyPVPForChar()

    -- Weekly Raid tracking!
    -- The quests from dalaran "<XY> Must Die!"
    -- QueryQuestsCompleted() is an expensive server request, so throttle it
    if now - lastQuestQuery >= QUEST_QUERY_THROTTLE then
        lastQuestQuery = now
        QueryQuestsCompleted()
    end
end


Ailo.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Ailo")
function Ailo:UPDATE_INSTANCE_INFO()
    self:UpdatePlayer()
end

function Ailo:PLAYER_ENTERING_WORLD()
    -- Fires after leaving a battleground, so the random BG win gets picked up
    self:UpdateDailyPVPForChar()
end

local INSTANCE_SAVED = _G["INSTANCE_SAVED"]
function Ailo:CHAT_MSG_SYSTEM(event, msg)
    -- You are now saved to this instances.
    -- Refresh RaidInfo
    if msg == INSTANCE_SAVED then
        RequestRaidInfo()
    end
end

function Ailo:UpdateDailyHeroicForChar()
    local chardb = self:GetCharDB()
    --[[
    GetLFGDungeonRewards(type)
    first return value: true if it was already done in this "Daily Quests"-lockout, false else
    type: 261 WotLK-nhc, 262 WotLK-hc
    ]]--
    if (GetLFGDungeonRewards(262)) then
        local expireTime = time()+GetQuestResetTime()
        chardb.dailyheroic = expireTime
        self:UpdateNextPurge(expireTime)
    else
        chardb.dailyheroic = nil
    end
end

function Ailo:UpdateDailyPVPForChar()
    if currentMaxLevel > UnitLevel("player") then return end
    local chardb = self:GetCharDB()
    -- First return value is true if the random battleground has already been won today
    if (GetRandomBGHonorCurrencyBonuses()) then
        local expireTime = time()+GetQuestResetTime()
        chardb.dailypvp = expireTime
        self:UpdateNextPurge(expireTime)
    else
        chardb.dailypvp = nil
    end
end

local questscompleted = {}
function Ailo:QUEST_QUERY_COMPLETE()
    wipe(questscompleted)
    GetQuestsCompleted(questscompleted)
    local chardb = self:GetCharDB()

    local weeklyExpire = self:GetWeeklyReset() or true
    if type(weeklyExpire) == "number" then
        self:UpdateNextPurge(weeklyExpire)
    end

    chardb.weeklydone = nil
    chardb.wgvictory = nil

    --[[ 13181 and 13183 are horde and alliance versions
    of the Victory in Wintergrasp weekly quest ]]--
    if questscompleted[13181] or questscompleted[13183] then
        chardb.wgvictory = weeklyExpire
    end

    --[[ ID's of all raid weekly quests:
    24590, 24589, 24588, 24587, 24586, 24585
    24584, 24583, 24582, 24581, 24580, 24579
    ]]--
    for i=24579,24590 do
        if questscompleted[i] then
            chardb.weeklydone = weeklyExpire
            break
        end
    end
    -- The completed quest list holds thousands of entries, don't keep it around
    wipe(questscompleted)
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
