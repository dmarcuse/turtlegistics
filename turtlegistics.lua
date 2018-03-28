assert(turtle, "Program must be run on a turtle")

local logFile = fs.combine(fs.getDir(shell.getRunningProgram()), "turtlegistics.log")
local logEnabled = settings.get("turtlegistics.log", true)

local transferBlacklist = {}

if logEnabled then
    fs.delete(logFile)
end

--[[ Write some data to the log file ]]
local function log(...)
    if logEnabled then
        local args = { ... }

        local f = fs.open(logFile, "a")

        for i, v in ipairs(args) do
            f.write(tostring(v))
        end

        f.writeLine()

        f.close()
    end
end

local function getChests()
    log("Getting chests")

    local names = peripheral.getNames()

    local chestCount = 0
    local chests = {}

    for _, name in ipairs(names) do
        if not name:match("^turtle") then
            local wrapped = peripheral.wrap(name)

            if wrapped.getTransferLocations then
                log("Found chest " .. name)
                chests[name] = wrapped
                chestCount = chestCount + 1
            end
        else
            transferBlacklist[name] = true
        end
    end

    return chests, chestCount
end

local function newStack(meta)
    local stack = {}

    stack.name = meta.name
    stack.displayName = meta.displayName
    stack.ores = meta.ores
    stack.count = meta.count
    stack.stackSize = meta.maxCount
    stack.damage = meta.damage
    stack.from = {} -- to be filled later - table of places where this stack is stored

    return setmetatable(stack, {
        __tostring = function(self)
            return self.displayName .. " x" .. stack.count
        end
    })
end

local function getItemStacks(chests)
    local items = {}

    for name, chest in pairs(chests) do
        for slot, _ in pairs(chest.list()) do
            local meta = chest.getItemMeta(slot)
            local idx = meta.name .. ";" .. meta.damage

            if items[idx] ~= nil then
                items[idx].count = items[idx].count + meta.count
            else
                items[idx] = newStack(meta)
            end

            table.insert(items[idx].from, {
                name = name,
                slot = slot,
                count = meta.count
            })
        end
    end

    return items
end

local state = {}

state.chestCount = 0
state.chests = {}

state.stacks = {}

state.sortMode = "amount"
state.displayStacks = {}
state.pageSize = 0 -- updated later in state:render
state.selectedStack = 1

state.search = ""
state.searchCursor = 1
state.didWithdraw = false

function state:updateDisplayStacks()
    self.displayStacks = {}

    -- filter according to search
    for i, stack in pairs(self.stacks) do
        if self.search == "" or stack.displayName:lower():match(self.search) then
            table.insert(self.displayStacks, stack)
        end
    end

    -- sort filtered results
    local comparator

    if self.sortMode == "amount" then
        comparator = function(a, b) return b.count < a.count end
    elseif self.sortMode == "lexical" then
        comparator = function(a, b) return a.displayName < b.displayName end
    end

    table.sort(self.displayStacks, comparator)
end

function state:refresh()
    log("Refreshing inventory")
    self.chests, self.chestCount = getChests()
    self.stacks = getItemStacks(self.chests)
    self:updateDisplayStacks()
    self:render()
end

local function themeComponent(bg, fg)
    local component = {}

    component.bg = bg
    component.fg = fg

    function component:apply()
        term.setBackgroundColor(self.bg)
        term.setTextColor(self.fg)
    end

    return component
end

local function formatNumber(n)
    if n >= 1000 then
        return string.format("%.1fk", n)
    else
        return tostring(n)
    end
end

local theme = {
    primary = themeComponent(colors.gray, colors.white),
    primary_muted = themeComponent(colors.gray, colors.lightGray),
    secondary = themeComponent(colors.black, colors.white),
    secondary_muted = themeComponent(colors.black, colors.lightGray)
}

function state:render(message)
    local w, h = term.getSize()

    term.setCursorPos(1,1)
    theme.secondary:apply()
    term.clear()
    term.setCursorBlink(false)

    -- draw status bar
    -- already at 1,1
    theme.primary:apply()
    term.clearLine()
    term.write("Turtlegistics")

    local chestStatus = self.chestCount == 1 and "1 chest" or ("%d chests"):format(self.chestCount)

    local numDisplayStacks = #self.displayStacks
    self.selectedStack = math.max(1, math.min(self.selectedStack, numDisplayStacks))

    self.pageSize = h - 3
    local totalPages = math.ceil(numDisplayStacks / self.pageSize)
    local pageOffset = math.floor((self.selectedStack - 1) / self.pageSize)
    local pageStatus = ("Page %d/%d"):format(pageOffset + 1, totalPages)

    local statusText = ("%s | %s"):format(chestStatus, pageStatus)
    term.setCursorPos(w - statusText:len(), 1)
    theme.primary_muted:apply()
    term.write(statusText)

    for i = 1, self.pageSize do
        local stackidx = (pageOffset * self.pageSize) + i
        local stack = self.displayStacks[stackidx]

        term.setCursorPos(1, i + 1)
        if stack and stackidx == self.selectedStack then theme.primary:apply() else theme.secondary:apply() end
        term.clearLine()

        if stack then
            term.write(stack.displayName)

            term.setCursorPos(w - 4, i + 1)
            if stackidx == self.selectedStack then theme.primary_muted:apply() else theme.secondary_muted:apply() end
            term.write(formatNumber(stack.count))
        end
    end

    -- draw help bar
    term.setCursorPos(1, h)
    theme.primary_muted:apply()
    term.clearLine()
    term.write("F5 scan F6 sort F7 insert F8 quit")

    -- draw search or message bar
    term.setCursorPos(1, h - 1)
    if message then
        theme.primary:apply()
        term.clearLine()
        term.write(message)
    else
        if self.search == "" then
            theme.primary_muted:apply()
            term.clearLine()
            term.write("Type to search, enter to pull stack")
        else
            theme.primary:apply()
            term.clearLine()
            term.write(self.search)
            term.setCursorPos(self.searchCursor, h - 1)
            term.setCursorBlink(true)
        end
    end
end

function state:withdraw(n)
    local stack = self.displayStacks[self.selectedStack]

    if stack ~= nil then
        log(("Withdrawing %s x%d"):format(stack.displayName, stack.stackSize))
        self:render("Withdrawing " .. stack.displayName)

        local needed = n or stack.stackSize
        local totalWithdrawn = 0
        local from = {}

        for i, source in ipairs(stack.from) do
            local amount = math.min(needed, source.count)

            if amount > 0 then
                local chest = self.chests[source.name]

                local targets = chest.getTransferLocations()
                local target

                for i, v in ipairs(targets) do
                    if v:match("^turtle") and not transferBlacklist[v] then
                        target = v
                        break
                    end
                end

                assert(target, "No connection between turtle and " .. source.name)

                local transferred = chest.pushItems(target, source.slot, needed)
                totalWithdrawn = totalWithdrawn + transferred
                source.count = math.max(0, source.count - transferred)
                log(("Transferred %s x%d from %s:%d to %s"):format(stack.displayName, transferred, source.name, source.slot, target))

                needed = math.max(0, needed - transferred)
            end
            
            if needed == 0 then break end
        end

        stack.count = math.max(0, stack.count - totalWithdrawn)
        self.didWithdraw = true
        self:updateDisplayStacks()
        self:render()
    end
end

function state:deposit()
    self:render("Inserting...")

    for turtleSlot = 1, 16 do
        local turtleStack = turtle.getItemDetail(turtleSlot)

        if turtleStack then
            local idx = turtleStack.name .. ";" .. turtleStack.damage
            local amount = turtleStack.count
            log(("Inserting %s x%d"):format(idx, amount))
            local totalDeposited = 0

            local networkStack = self.stacks[idx]

            -- fill existing partial stacks
            if networkStack then
                for i, source in ipairs(networkStack.from) do
                    local freeSpace = math.max(0, networkStack.stackSize - source.count)

                    if freeSpace > 0 then
                        local chest = self.chests[source.name]

                        local targets = chest.getTransferLocations()
                        local target

                        for i, v in ipairs(targets) do
                            if v:match("^turtle") and not transferBlacklist[v] then
                                target = v
                                break
                            end
                        end

                        assert(target, "No connection between turtle and " .. source.name)

                        local transferred = chest.pullItems(target, turtleSlot, nil, source.slot)
                        totalDeposited = totalDeposited + transferred
                        source.count = source.count + transferred
                        log(("Transferred %s x%d from %s to %s:%d"):format(networkStack.displayName, transferred, target, source.name, source.slot))

                        amount = math.max(0, amount - transferred)
                    end

                    if amount == 0 then break end
                end
            end

            if amount > 0 then
                -- we need to use an empty slot
                for name, chest in pairs(self.chests) do
                    local maxSlot = chest.size()

                    if maxSlot > 0 then
                        local contents = chest.list()

                        for chestSlot = 1, maxSlot do
                            if contents[chestSlot] == nil then
                                -- found a free slot!
                                local targets = chest.getTransferLocations()
                                local target

                                for i, v in ipairs(targets) do
                                    if v:match("^turtle") and not transferBlacklist[v] then
                                        target = v
                                        break
                                    end
                                end

                                assert(target, "No connection between turtle and " .. name)

                                local transferred = chest.pullItems(target, turtleSlot, nil, chestSlot)
                                totalDeposited = totalDeposited + transferred
                                log(("Transferred %s x%d from %s to %s:%d (previously empty slot)"):format(idx, amount, target, name, chestSlot))

                                amount = math.max(0, amount - transferred)

                                if transferred > 0 then
                                    if networkStack == nil then
                                        -- create the network stack
                                        local meta = chest.getItemMeta(chestSlot)
                                        networkStack = newStack(meta)

                                        networkStack.count = 0 -- this value is set later before the function exits

                                        -- store the new stack
                                        self.stacks[idx] = networkStack
                                    end
                                        
                                    table.insert(networkStack.from, {
                                        name = name,
                                        slot = chestSlot,
                                        count = transferred
                                    })

                                    if amount == 0 then break end
                                end
                            end
                        end
                    end

                    if amount == 0 then break end
                end
            end

            if networkStack then networkStack.count = networkStack.count + totalDeposited end
            self:updateDisplayStacks()
            self:render()
        end
    end
end

log("Starting turtlegistics")

state:render("Starting...")
state:refresh()

while true do
    local evt = { os.pullEvent() }

    if evt[1] == "mouse_scroll" then
        state.selectedStack = state.selectedStack + (3 * evt[2])
        state:render()
    elseif evt[1] == "key" then
        -- hotkeys
        if evt[2] == keys.f8 then -- exit
            break
        elseif evt[2] == keys.f5 then -- refresh
            state:render("Refreshing...")
            state:refresh()
        elseif evt[2] == keys.f6 then -- change sort mode
            if state.sortMode == "amount" then
                state.sortMode = "lexical"
            else
                state.sortMode = "amount"
            end
            state:render("Sorting...")
            state:updateDisplayStacks()
            state:render()
        elseif evt[2] == keys.enter then -- withdraw
            state:withdraw()
        elseif evt[2] == keys.f7 then -- deposit
            state:deposit()
        end

        -- navigation
        if evt[2] == keys.pageDown then
            state.selectedStack = state.selectedStack + state.pageSize
            state:render()
        elseif evt[2] == keys.pageUp then
            state.selectedStack = state.selectedStack - state.pageSize
            state:render()
        elseif evt[2] == keys.down then
            state.selectedStack = state.selectedStack + 1
            state:render()
        elseif evt[2] == keys.up then
            state.selectedStack = state.selectedStack - 1
            state:render()
        end
        
        -- text manipulation for search bar
        if evt[2] == keys.backspace then
            if state.didWithdraw then
                state.search = ""
                state.searchCursor = 1
                state.didWithdraw = false
            else
                local prefix = state.search:sub(1, math.max(0, state.searchCursor - 2))
                local suffix = state.search:sub(state.searchCursor)
    
                state.search = prefix .. suffix
                state.searchCursor = math.max(state.searchCursor - 1, 1)
            end

            state:updateDisplayStacks()
            state:render()
        elseif evt[2] == keys.delete then
            local prefix = state.search:sub(1, math.max(0, state.searchCursor - 1))
            local suffix = state.search:sub(state.searchCursor + 1)

            state.search = prefix .. suffix
            state:updateDisplayStacks()
            state:render()
        elseif evt[2] == keys.left then
            state.searchCursor = math.max(state.searchCursor - 1, 1)
            
            state:render()
        elseif evt[2] == keys.right then
            state.searchCursor = math.min(state.searchCursor + 1, state.search:len() + 1)

            state:render()
        elseif evt[2] == keys.home then
            state.searchCursor = 1

            state:render()
        elseif evt[2] == keys["end"] then
            state.searchCursor = state.search:len() + 1

            state:render()
        end
    elseif evt[1] == "char" then
        state.search = state.search:sub(1, state.searchCursor) .. evt[2] .. state.search:sub(state.searchCursor + 1)
        state.searchCursor = state.searchCursor + 1
        state.didWithdraw = false

        state:updateDisplayStacks()
        state:render()
    end
end

log("Exiting turtlegistics")

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1,1)
