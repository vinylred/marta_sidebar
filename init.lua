marta.expose()

plugin {
    id = "marta.example.sidebar",
    name = "Places Sidebar",
    apiVersion = "2.2",
    author = "Balaji",
    email = "balaji@dreamfolks.com"
}

local interop = require "libmartasidebar"

-- ---------------------------------------------------------------------------
-- Theme parsing
--
-- Marta does not expose theme colors to plugins, so we read the active theme
-- file directly and extract the colors we need. The sidebar is then rendered
-- with these so it matches the main UI. Anything we can't read falls back to
-- the native Swift defaults.
-- ---------------------------------------------------------------------------

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Returns the string contents of the named top-level block, e.g. block("base", text).
local function block(name, text)
    -- match `name {  ... }` (single level of nesting tolerated for our keys)
    local s = text:find(name .. "%s*{")
    if not s then return nil end
    local open = text:find("{", s)
    local depth, i = 0, open
    while i <= #text do
        local c = text:sub(i, i)
        if c == "{" then depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return text:sub(open + 1, i - 1) end
        end
        i = i + 1
    end
    return nil
end

-- Extracts `key #hexhex` from a chunk of theme text.
local function color(chunk, key)
    if not chunk then return nil end
    return chunk:match(key .. "%s*(#%x+)")
end

-- Reads the active theme and returns a table of hex strings + appearance.
local function loadTheme()
    local app = marta.globalContext.application
    local confDir = app.configurationFolder.rawValue

    local conf = readFile(confDir .. "/conf.marco") or ""
    local themeName = conf:match('theme%s*"([^"]+)"') or "Kon"

    -- Search user themes dir, then the app bundle's Themes dir.
    local candidates = {}
    local ok, themesDir = pcall(function() return app.themesFolder.rawValue end)
    if ok and themesDir then
        candidates[#candidates + 1] = themesDir .. "/" .. themeName .. ".theme"
        candidates[#candidates + 1] = themesDir .. "/" .. themeName .. ".ettyTheme"
    end
    candidates[#candidates + 1] =
        "/Applications/Marta.app/Contents/Resources/Themes/" .. themeName .. ".theme"
    candidates[#candidates + 1] =
        "/Applications/Marta.app/Contents/Resources/Themes/" .. themeName .. ".ettyTheme"

    local text
    for _, p in ipairs(candidates) do
        text = readFile(p)
        if text then break end
    end
    if not text then return {} end

    local base  = block("base", text)
    local files = block("files", text)
    local filesBg   = files and block("background", files) or nil
    local filesText = files and block("text", files) or nil

    return {
        appearance    = base and base:match('appearance%s*"([^"]+)"') or nil,
        background     = color(base, "background"),
        text           = color(base, "text"),
        selection      = color(filesBg, "current"),
        selectionText  = color(filesText, "current"),
        alternate      = color(filesBg, "alternate"),
    }
end

action {
    id = "show",
    name = "Show Places Sidebar",
    apply = function(context)
        local window = context.window
        -- Pass Marta's window so we can dock to its left edge, and a callback
        -- that navigates the active file pane to the clicked folder.
        local owner = window and window.nsWindow or nil

        local t = {}
        local ok = pcall(function() t = loadTheme() end)
        if not ok then t = {} end

        -- Handles a sidebar click. Two kinds of commands arrive here:
        --   "action:<id>"  -> run a built-in Marta action (Back/Forward/Up)
        --   "<path>"       -> navigate the active pane to that folder
        -- Invoked from Swift on every click.
        local function navigate(path)
            if not path then return end

            -- Toolbar buttons: run Marta's own navigation actions by id, so
            -- "Back" goes to the previously VISITED folder (core.back), not the
            -- parent. core.go.up is the existing "Up" behavior.
            local actionId = path:match("^action:(.+)$")
            if actionId then
                local act = marta.globalContext.actions:getById(actionId)
                if not act then
                    martax.alert("Unknown action: " .. actionId)
                    return
                end
                local ran, aerr = pcall(function()
                    window:runAction(act)
                end)
                if not ran then
                    martax.alert("Could not run " .. actionId .. "\n" .. tostring(aerr))
                end
                return
            end

            -- parsePath -> Path; the file system turns a Path into a File,
            -- which is what model:load expects.
            local p = marta.parsePath(path)
            if not p then
                martax.alert("Invalid path: " .. tostring(path))
                return
            end

            -- Resolve the active pane FRESH on every click (read through the
            -- window's pane manager), so it follows whichever pane is focused
            -- now -- not the pane that was active when the sidebar opened.
            local pane = window.panes.activePane
            if not pane then
                martax.alert("No active pane to navigate.")
                return
            end

            local file = marta.localFileSystem:get(p)
            local loaded, err = pcall(function()
                pane.model:load(file)
            end)
            if not loaded then
                martax.alert("Could not open " .. path .. "\n" .. tostring(err))
            end
        end

        -- Argument order MUST match the Swift bridge:
        --   (nsWindow, callback, appearance, bg, text,
        --    selection, selectionText, alternate, fontName, fontSize)
        interop.showSidebar(
            owner,
            navigate,
            t.appearance,
            t.background,
            t.text,
            t.selection,
            t.selectionText,
            t.alternate,
            nil,    -- fontName: use Marta's default (system font)
            12.5    -- fontSize: Marta's default list font size
        )
    end
}
