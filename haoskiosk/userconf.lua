--[[
Add-on: HAOS Kiosk Display (haoskiosk)
File: userconf.lua for HA minimal browser run on server
Version: 0.9.8
Copyright Jeff Kosowsky
Date: June 2025

Code does the following:
    - Sets browser window to fullscreen
    - Sets zooms level to value of $ZOOM_LEVEL (default 100%)
    - Starts first window in 'passthrough' mode so that you can type text as needed without
       triggering browser commands
    - Auto-logs in to Home Assistant using $HA_USERNAME and $HA_PASSWORD
    - Redefines key to return to normal mode (used for commands) from 'passthrough' mode to: 'Ctl-Alt-Esc'
      (rather than just 'Esc') to prevent unintended  returns to normal mode and activation of unwanted commands
    - Adds <Control-r> binding to reload browser screen (all modes)
    - Prevent printing of '--PASS THROUGH--' status line when in 'passthrough' mode
    - Set up periodic browser refresh every $BROWSWER_REFRESH seconds (disabled if 0)
      NOTE: this is important since console messages overwrite dashboards
    - Allows for configurable browser $ZOOM_LEVEL
    - Sets Home Assistant theme and sidebar visibility using $THEME and $SIDEBAR environment variables
]]

-- -----------------------------------------------------------------------
-- Load required Luakit modules
local window = require "window"
local webview = require "webview"
local settings = require "settings"
local modes = package.loaded["modes"]

-- -----------------------------------------------------------------------
-- Configurable variables
local New_Escape_Key = "<Control-Mod1-Escape>" -- Ctl-Alt-Esc

-- Load in environment variables to configure options
local defaults = {
    HA_USERNAME = "",
    HA_PASSWORD = "",
    HA_URL = "http://localhost:8123",
    HA_THEME = "",
    HA_SIDEBAR = "",

    LOGIN_DELAY = 1,
    ZOOM_LEVEL = 100,
    BROWSER_REFRESH = 600,
                        }
local username = os.getenv("HA_USERNAME") or defaults.HA_USERNAME
local password = os.getenv("HA_PASSWORD") or defaults.HA_PASSWORD

local ha_url = os.getenv("HA_URL") or defaults.HA_URL  -- Starting URL
if not ha_url:match("^https?://[%w%.%-%%:]+[/%?%#]?[/%w%.%-%?%#%=%%]*$") then
    msg.warn("Invalid HA_URL value: '%s'; defaulting to %s", os.getenv("HA_URL") or "", defaults.HA_URL)
    ha_url = defaults.HA_URL
end
ha_url = string.gsub(ha_url, "/+$", "") -- Strip trailing '/'
local ha_url_base = ha_url:match("^(https?://[%w%.%-%%:]+)") or ha_url
ha_url_base = string.gsub(ha_url_base, "/+$", "") -- Strip trailing '/'

local raw_theme = os.getenv("HA_THEME") or defaults.HA_THEME -- Valid entries: auto, dark, light, none (or "")
local valid_themes = { auto = '{}', dark = '{"dark":true}', light = '{"dark":false}', none = '', [""] = ''}
local theme = valid_themes[raw_theme]
if theme == nil then
    msg.warn("Invalid HA_THEME value: '%s'; defaulting to unset", raw_theme)
    theme = ''
end

local raw_sidebar = os.getenv("HA_SIDEBAR") or defaults.HA_SIDEBAR -- Valid entries: full (or ""), narrow, none,
local valid_sidebars = { full = '', none = '"always_hidden"', narrow = '"auto"', [""] = '' }
local sidebar = valid_sidebars[raw_sidebar]
if sidebar == nil then
    msg.warn("Invalid HA_SIDEBAR value: '%s'; defaulting to unset", raw_sidebar)
    sidebar = ''
end

local login_delay = tonumber(os.getenv("LOGIN_DELAY")) or defaults.LOGIN_DELAY -- Delay in seconds before auto-login
if login_delay <= 0 then
    msg.warn("Invalid LOGIN_DELAY value: '%s'; defaulting to %d", os.getenv("LOGIN_DELAY") or "", defaults.LOGIN_DELAY)
    login_delay = defaults.LOGIN_DELAY
end

local zoom_level = tonumber(os.getenv("ZOOM_LEVEL")) or defaults.ZOOM_LEVEL
if zoom_level <= 0 then
    msg.warn("Invalid ZOOM_LEVEL value: '%s'; defaulting to %d", os.getenv("ZOOM_LEVEL") or "", defaults.ZOOM_LEVEL)
    zoom_level = defaults.ZOOM_LEVEL
end

local browser_refresh = tonumber(os.getenv("BROWSER_REFRESH")) or defaults.BROWSER_REFRESH  -- Refresh interval in seconds
if browser_refresh < 0 then
    msg.warn("Invalid BROWSER_REFRESH value: '%s'; defaulting to %d", os.getenv("BROWSER_REFRESH") or "", defaults.BROWSER_REFRESH)
    browser_refresh = defaults.BROWSER_REFRESH
end

-- -----------------------------------------------------------------------
-- Set window to fullscreen
window.add_signal("init", function(w)
    w.win.fullscreen = true
end)

-- Set zoom level for windows (default 100%)
settings.webview.zoom_level = zoom_level

-- -----------------------------------------------------------------------
-- Helper functions
local function single_quote_escape(str) -- Single quote strings before injection into JS
    if not str or str == "" then return str end
    str = str:gsub("'", "\\'")
    return str
end

-- -----------------------------------------------------------------------
local first_window = true
local ha_settings_applied = false -- Flag to track if HA settings have already been applied in this session
webview.add_signal("init", function(view)
    -- Listen for page load events
    view:add_signal("load-status", function(v, status)
        if status ~= "finished" then return end  -- Only proceed when the page is fully loaded
        msg.info("URI: %s", v.uri) -- DEBUG

        -- We want to start in passthrough mode (i.e. not normal command mode) -- 4 potential options for doing this
        -- Option#1 Sets passthrough mode for the first window (or all initial windows if using xdotool line)
        if first_window then
            -- Option 1a: [USED]
            webview.window(v):set_mode("passthrough") -- This method only works  if no pre-existing tabs (e.g., using 'luakit -U')
                                                      -- Otherwise, first saved (and recovered) tab gets set to passthrough mode and not the specified start url
            -- Option 1b: [NOT USED] Requires adding 'apk add xdotool' to Dockerfile -- also seems  to set for all pre-existing windows
--          os.execute("xdotool key ctrl+z")
--          msg.info("Setting passthrough mode...") -- DEBUG
            first_window = false
        end

--[[
        -- Option#2 [NOT USED] Set passthrough mode for all windows with url beginning with 'ha_url'
        if (v.uri .. "/"):match("^" .. ha_url_base .. "/") then -- Note ha_url was stripped of trailing slashes
            webview.window(v):set_mode("passthrough")
--          msg.info("Setting passthrough mode...") -- DEBUG
        end
]]

        -- Set up auto-login for Home Assistant
        -- Check if current URL matches the Home Assistant auth page
        if v.uri:match("^" .. ha_url_base .. "/auth/authorize%?response_type=code") then
            -- JavaScript to auto-fill and submit the login form
            local js_auto_login = string.format([[
                setTimeout(function() {
                    var usernameField = document.querySelector('input[name="username"]');
                    var passwordField = document.querySelector('input[name="password"]');
                    var submitButton = document.querySelector('mwc-button');
                    if (usernameField && passwordField && submitButton) {
                        usernameField.value = '%s';
                        usernameField.dispatchEvent(new Event('input', { bubbles: true }));
                        passwordField.value = '%s';
                        passwordField.dispatchEvent(new Event('input', { bubbles: true }));
                        submitButton.click();
                    }
                }, %d);
            ]], single_quote_escape(username), single_quote_escape(password), login_delay * 1000)
            v:eval_js(js_auto_login, { source = "auto_login.js" })  -- Execute the login script
        end

        -- Set Home Assistant theme and sidebar visibility after dashboard load
        -- Check if current URL starts with ha_url but not an auth page
        if not ha_settings_applied
           and (v.uri .. "/"):match("^" .. ha_url_base .. "/") -- Note ha_url was stripped of trailing slashes
           and not v.uri:match("^" .. ha_url_base .. "/auth/") then

            msg.info("Applying HA settings on dashboard %s: theme=%s, sidebar=%s", v.uri, theme, sidebar) -- DEBUG

            local js_settings = string.format([[
                try {
                    // Set theme and sidebar visibility
                    let Theme = '%s';
                    let Sidebar = '%s';

                    let currentTheme = localStorage.getItem('selectedTheme') || '';
                    let currentSidebar = localStorage.getItem('dockedSidebar') || '';
                    let needsReload = false;

                    if (Theme !== currentTheme) {
                        needsReload = true;
                        if (Theme !== "") {
                            localStorage.setItem('selectedTheme', Theme);
                        } else {
                            localStorage.removeItem('selectedTheme');
                        }
                    }

                    if (Sidebar !== currentSidebar) {
                        needsReload = true;
                        if (Sidebar !== "") {
                            localStorage.setItem('dockedSidebar', Sidebar);
                        } else {
                            localStorage.removeItem('dockedSidebar');
                        }
                    }

//                  localStorage.setItem('DebugLog', "Setting: Theme: " + currentTheme + " -> " + Theme +
//                                   " ;Sidebar: " + currentSidebar + " -> " + Sidebar + " [Reload: " + needsReload + "]"); // DEBUG

                    if (needsReload) { // Reload to apply settings
                        setTimeout(function() {
                            location.reload();
                        }, 500);
                    }

                } catch (err) {
                    localStorage.setItem('DebugLog', "FAILED to set: Theme: " + Theme + " ;Sidebar: " + Sidebar); // DEBUG
                }
            ]], single_quote_escape(theme), single_quote_escape(sidebar))

            v:eval_js(js_settings, { source = "ha_settings.js" })
            ha_settings_applied = true
        end

        -- Set up periodic page refresh if browser_interval is positive
        if browser_refresh > 0 then
            local js_refresh = string.format([[
                if (window.ha_refresh_id) clearInterval(window.ha_refresh_id);
                window.ha_refresh_id = setInterval(function() {
                    location.reload();
                }, %d);
                window.addEventListener('beforeunload', function() {
                    clearInterval(window.ha_refresh_id);
                });
            ]], browser_refresh * 1000)
            v:eval_js(js_refresh, { source = "auto_refresh.js" })  -- Execute the refresh script
        end

    end)
end)


-- -----------------------------------------------------------------------
-- Redefine <Esc> to 'New_Escape_Key' (e.g., <Ctl-Alt-Esc>) to exit current mode and enter normal mode
modes.remove_binds({"passthrough"}, {"<Escape>"})
modes.add_binds("passthrough", {
    {New_Escape_Key, "Switch to normal mode", function(w)
        w:set_prompt()
        w:set_mode() -- Use this if not redefining 'default_mode' since defaults to "normal"
--        w:set_mode("normal") -- Use this if redefining 'default_mode' [Option#3]
     end}
}
)
-- Add <Control-r> binding in all modes to reload page
modes.add_binds("all", {
    { "<Control-r>", "reload page", function (w) w:reload() end },
    })

-- Clear the command line when entering passthrough instead of typing '-- PASS THROUGH --'
modes.get_modes()["passthrough"].enter = function(w)
    w:set_prompt()            -- Clear the command line prompt
    w:set_input()             -- Activate the input field (e.g., URL bar or form)
    w.view.can_focus = true   -- Ensure the webview can receive focus
    w.view:focus()            -- Focus the webview for keyboard input
end

-- Option#3:[NOT USED]  Makes 'passthrough' *always* the default mode for 'set_mode'
--[[
local lousy = require('lousy.mode')
window.methods.set_mode = function (object, mode, ...)
    local default_mode = 'passthrough'
    return lousy.set(object, mode or default_mode)
end
]]
