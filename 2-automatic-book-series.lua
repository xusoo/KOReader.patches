-- Automatic Series Grouping Patch
local FileChooser = require("ui/widget/filechooser")
local logger = require("logger")
local userpatch = require("userpatch")
local _ = require("gettext")
local util = require("util")

logger.dbg("AutomaticSeries Patch: Loading...")

local up_folder_visible = false
local up_folder_text = "../"
local titlebar_title = nil

-- Global cache mapping virtual series folder paths to their book items
-- This allows the ProjectTitle plugin to find books for folder cover rendering
local series_items_cache = {}

-- State for persisting virtual folder across refreshes
local current_series_group = nil

-- Flag to prevent duplicate menu items
local menu_item_added = false

local function patchCoverBrowser(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then return end
    local BookInfoManager = userpatch.getUpValue(MosaicMenuItem.update, "BookInfoManager")
    
    if not BookInfoManager then
        logger.warn("AutomaticSeries Patch: BookInfoManager not found")
        return
    end
    
    logger.warn("AutomaticSeries Patch: Initialized with BookInfoManager")
    
    -- Settings
    local setting_name = "automatic_series_grouping_enabled"
    local function isEnabled()
        local setting = BookInfoManager:getSetting(setting_name)
        -- Default to true if nil (not explicitly disabled)
        return setting ~= "N"
    end
    
    local function setEnabled(enabled)
        -- Store "Y" for enabled, "N" for disabled (avoid false->NULL issue)
        BookInfoManager:saveSetting(setting_name, enabled and "Y" or "N")
    end
    
    -- Hook MosaicMenuItem to support folder covers for virtual series groups
    local original_MosaicMenuItem_update = MosaicMenuItem.update
    function MosaicMenuItem:update(...)
        -- Call the original update (which includes folder-cover patch logic)
        original_MosaicMenuItem_update(self, ...)
        
        -- If this is a series group and we haven't processed it yet, set its cover
        if self.entry and self.entry.is_series_group and not self._seriescover_processed and self.do_cover_image then
            self._seriescover_processed = true
            
            -- Get the first book from series_items
            local series_items = self.entry.series_items
            if series_items and #series_items > 0 then
                -- Set the mandatory field (book count) that the folder-cover patch expects
                -- Format: "X 📁" where X is the number of books
                if not self.mandatory then
                    self.mandatory = tostring(#series_items) .. " \u{F016}"
                end
                
                -- Try to use the cover from the first book in the series
                for _, book_entry in ipairs(series_items) do
                    if book_entry.path then
                        local bookinfo = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bookinfo 
                            and bookinfo.cover_bb 
                            and bookinfo.has_cover 
                            and bookinfo.cover_fetched 
                            and not bookinfo.ignore_cover 
                            and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs) then
                            -- Use the _setFolderCover function from the folder-cover patch
                            if self._setFolderCover then
                                self:_setFolderCover({ 
                                    data = bookinfo.cover_bb, 
                                    w = bookinfo.cover_w, 
                                    h = bookinfo.cover_h 
                                })
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    
    -- Hook ptutil.getSubfolderCoverImages for ProjectTitle plugin compatibility
    -- This allows virtual series folders to display book covers
    local ok, ptutil = pcall(require, "ptutil")
    if ok and ptutil and ptutil.getSubfolderCoverImages then
        -- Get the internal helper functions from ptutil using upvalues
        local build_cover_images = userpatch.getUpValue(ptutil.getSubfolderCoverImages, "build_cover_images")
        local build_diagonal_stack = userpatch.getUpValue(ptutil.getSubfolderCoverImages, "build_diagonal_stack")
        local build_grid = userpatch.getUpValue(ptutil.getSubfolderCoverImages, "build_grid")
        
        if build_cover_images and (build_diagonal_stack or build_grid) then
            local original_getSubfolderCoverImages = ptutil.getSubfolderCoverImages
            ptutil.getSubfolderCoverImages = function(filepath, max_w, max_h)
                -- Check if this is a virtual series folder path
                local series_items = series_items_cache[filepath]
                if series_items and #series_items > 0 then
                    -- Format our series items to look like the database result
                    -- db_res format: { [1] = directories, [2] = filenames }
                    local directories = {}
                    local filenames = {}
                    for _, book_item in ipairs(series_items) do
                        if book_item.path then
                            local dir = book_item.path:match("(.*/)")
                            local fname = book_item.path:match("([^/]+)$")
                            if dir and fname then
                                table.insert(directories, dir)
                                table.insert(filenames, fname)
                            end
                        end
                    end
                    
                    if #filenames > 0 then
                        local db_res = { directories, filenames }
                        local images = build_cover_images(db_res, max_w, max_h)
                        
                        if #images > 0 then
                            -- Use the same display logic as ptutil.getSubfolderCoverImages
                            if BookInfoManager:getSetting("use_stacked_foldercovers") and build_diagonal_stack then
                                return build_diagonal_stack(images, max_w, max_h)
                            elseif build_grid then
                                return build_grid(images, max_w, max_h)
                            end
                        end
                    end
                end
                
                -- Fall back to original function for real folders
                return original_getSubfolderCoverImages(filepath, max_w, max_h)
            end
            logger.dbg("AutomaticSeries: Hooked ptutil.getSubfolderCoverImages for ProjectTitle compatibility")
        else
            logger.warn("AutomaticSeries: Could not get ptutil helper functions, ProjectTitle cover hook not installed")
        end
    end
    
    -- Local logic container
    local AutomaticSeries = {
        BookInfoManager = BookInfoManager,
    }

    -- Helper to reset title bar
    local function resetTitle(file_chooser, parent_path)
        if file_chooser.title_bar then
            if titlebar_title then
                file_chooser.title_bar:setTitle(titlebar_title)
                titlebar_title = nil -- Clear after use
            else
                local _, folder_name = util.splitFilePathName(parent_path)
                file_chooser.title_bar:setTitle(folder_name)
            end
        end
    end
    
    function AutomaticSeries:processItemTable(item_table, file_chooser)
        logger.dbg("AutomaticSeries: Processing Items")
        local collate, collate_id = file_chooser:getCollate()
        local reverse = G_reader_settings:isTrue("reverse_collate")
        local sort_func = file_chooser:getSortingFunction(collate, reverse)
        local mixed = G_reader_settings:isTrue("collate_mixed") and collate.can_collate_mixed
        
        -- Check if we are sorting by some form of Name/Title
        local is_name_sort = (collate_id == "strcoll" or collate_id == "natural" or collate_id == "title")
    
        local series_map = {}
        local processed_list = {}
        
        -- Check if the original item table has an up-folder item
        up_folder_visible = false
        for _, item in ipairs(item_table) do
            if item.is_go_up then
                up_folder_visible = true
                up_folder_text = item.text
                logger.dbg("AutomaticSeries: Found up-folder item", up_folder_text)
                break
            end
        end
        
        for _, item in ipairs(item_table) do
            -- Skip "go up" items, handle them separately
            if item.is_go_up then
                table.insert(processed_list, item)
            else
                -- Ensure safe sort properties for ALL items (files and directories)
                if not item.sort_percent then item.sort_percent = 0 end
                if not item.percent_finished then item.percent_finished = 0 end
                if not item.opened then item.opened = false end
    
                -- Robustly check for file/dir properties using standard BookList/FileChooser structure
                local is_file = item.is_file 
    
                local series_handled = false
                
                if is_file and item.path then
                    local info = self.BookInfoManager:getBookInfo(item.path)
                    if info and info.series then
                        logger.dbg("AutomaticSeries: Found series", info.series)
                        local s_name = info.series
                        if not series_map[s_name] then
                            -- New Series Group
                            
                            -- Shallow copy attributes
                            local group_attr = {}
                            if item.attr then
                                for k, v in pairs(item.attr) do group_attr[k] = v end
                            end
                            group_attr.mode = "directory" 
    
                            local group_item = {
                                text = s_name,
                                is_file = false,
                                is_directory = true,
                                -- Fake path, but keep base path of first item
                                path = (item.path:match("(.*/)") or item.path) .. s_name, 
                                is_series_group = true,
                                series_items = { item },
                                attr = group_attr,
                                mode = "directory",
                                -- Inherit sort properties from the first book (which determines position)
                                sort_percent = item.sort_percent,
                                percent_finished = item.percent_finished,
                                opened = item.opened,
                                doc_props = item.doc_props,
                                suffix = item.suffix,
                            }
                            -- Cache this group
                            series_map[s_name] = group_item
                            table.insert(processed_list, group_item)
                            -- Store the list index to allow replacement if ungrouping needed
                            group_item._list_index = #processed_list
                        else
                            -- Existing Series Group
                            table.insert(series_map[s_name].series_items, item)
                        end
                        series_handled = true
                    end
                end
                
                if not series_handled then
                    table.insert(processed_list, item)
                end
            end
        end
    
        logger.dbg("AutomaticSeries: Done loop. Map size", #series_map)
    
        -- Update the item count in the text for each series group
        for _, group in pairs(series_map) do
            if #group.series_items == 1 then
                -- Single book in series: Ungroup it!
                -- Replace the group item in the list with the single book item
                -- We use the stored index to find where the group was inserted
                if group._list_index and processed_list[group._list_index] == group then
                    -- The single book is the first (and only) item in series_items
                    local single_book = group.series_items[1]
                    processed_list[group._list_index] = single_book
                end
            else
                -- Set mandatory to show book count with folder icon (displays as badge on right)
                group.mandatory = tostring(#group.series_items) .. " \u{F016}"
                -- Also sort the internal list of books by series index
                table.sort(group.series_items, function(a, b)
                    local info_a = self.BookInfoManager:getBookInfo(a.path)
                    local info_b = self.BookInfoManager:getBookInfo(b.path)
                    local idx_a = (info_a and info_a.series_index) or 0
                    local idx_b = (info_b and info_b.series_index) or 0
                    return idx_a < idx_b
                end)
                -- Cache the series items by the virtual folder path for ProjectTitle hook
                if group.path then
                    series_items_cache[group.path] = group.series_items
                end
            end
        end
        
        local final_table = {}
        
        if mixed then
            if is_name_sort then
                local up_item
                local to_sort = {}
                for _, item in ipairs(processed_list) do
                    if item.is_go_up then up_item = item else table.insert(to_sort, item) end
                end
                table.sort(to_sort, sort_func)
                
                if up_item then table.insert(final_table, up_item) end
                for _, item in ipairs(to_sort) do table.insert(final_table, item) end
            else
                final_table = processed_list
            end
        else
            -- Mixed is FALSE: Folders first, then Files.
            
            local dirs = {}
            local files = {}
            local up_item
            
            for _, item in ipairs(processed_list) do
                if item.is_go_up then
                    up_item = item
                elseif item.is_directory or (item.attr and item.attr.mode == "directory") or item.mode == "directory" then
                    table.insert(dirs, item)
                else
                    table.insert(files, item)
                end
            end
            
            -- We must resort 'dirs' to ensure our new Series Groups are sorted correctly among other real folders.
            table.sort(dirs, sort_func)
            
            if up_item then table.insert(final_table, up_item) end
            for _, d in ipairs(dirs) do table.insert(final_table, d) end
            for _, f in ipairs(files) do table.insert(final_table, f) end
        end
    
        logger.dbg("AutomaticSeries: Final table count", #final_table)
        
        -- Update item_table in place (clear and fill)
        for k in pairs(item_table) do item_table[k] = nil end
        for i, v in ipairs(final_table) do item_table[i] = v end
    end
    
    function AutomaticSeries:openSeriesGroup(file_chooser, group_item)
        -- Safety check
        if not file_chooser then
            return
        end
        
        local items = group_item.series_items
        
        -- Store the real parent path before entering the virtual folder
        local parent_path = file_chooser.path
        if file_chooser.title_bar then
            titlebar_title = file_chooser.title_bar.title
        end
        
        -- Store the group for state persistence across refreshes
        current_series_group = {
            series_name = group_item.text,
            parent_path = parent_path,
        }
        
        -- Check if up-item already exists (from previous entry)
        local up_item_already_present = false
        for _, item in ipairs(items) do
            if item.is_go_up then
                up_item_already_present = true
                break
            end
        end
        
        if up_folder_visible and not up_item_already_present then
            -- Create a go-up item pointing to the real parent
            local up_item = {
                text = up_folder_text,
                is_directory = true,
                path = parent_path,
                is_go_up = true,
            }
            table.insert(items, 1, up_item)
        end
        
        -- Tag this table as a virtual series view
        items.is_in_series_view = true
        items.parent_path = parent_path
        
        -- Switch view
        file_chooser:switchItemTable(group_item.text, items)
    end
    
    -- Hook FileChooser
    local old_updateItems = FileChooser.updateItems
    local old_onMenuSelect = FileChooser.onMenuSelect
    local old_onFolderUp = FileChooser.onFolderUp
    local old_changeToPath = FileChooser.changeToPath
    local old_refreshPath = FileChooser.refreshPath
    local old_goHome = FileChooser.goHome
    
    -- Hook goHome to handle Home button when inside virtual folder
    FileChooser.goHome = function(file_chooser)
        -- If we're in a virtual series view, exit it first
        if file_chooser.item_table and file_chooser.item_table.is_in_series_view then
            local parent_path = file_chooser.item_table.parent_path
            -- Clear virtual folder state
            current_series_group = nil
            -- Reset title
            resetTitle(file_chooser, parent_path)
            -- Now check if parent IS home - if so, just refresh to show parent
            local home_dir = G_reader_settings:readSetting("home_dir")
            if parent_path == home_dir then
                file_chooser:changeToPath(parent_path)
                return true
            end
            -- Otherwise, fall through to original goHome which navigates to home
        end
        return old_goHome(file_chooser)
    end
    
    -- Hook refreshPath to detect returning from a book
    FileChooser.refreshPath = function(file_chooser)
        -- Capture focused_path before the original clears it
        local book_path = file_chooser.focused_path
        
        -- Call original (which clears focused_path and loads items)
        old_refreshPath(file_chooser)
        
        -- After refresh, check if we should open a series group
        if isEnabled() and book_path and not current_series_group then
            local bookinfo = BookInfoManager:getBookInfo(book_path)
            if bookinfo and bookinfo.series then
                for _, item in ipairs(file_chooser.item_table) do
                    if item.is_series_group and item.text == bookinfo.series then
                        AutomaticSeries:openSeriesGroup(file_chooser, item)
                        break
                    end
                end
            end
        end
    end
    
    -- Override onFolderUp to handle virtual folder navigation (toolbar up button)
    FileChooser.onFolderUp = function(file_chooser)
        -- If we're in a virtual series view, navigate to the real parent
        if file_chooser.item_table and file_chooser.item_table.is_in_series_view then
            local parent_path = file_chooser.item_table.parent_path
            if parent_path then
                -- Clear virtual folder state BEFORE navigating
                current_series_group = nil
                -- Navigate to parent
                file_chooser:changeToPath(parent_path)
                -- Explicitly reset title (switchItemTable with nil title doesn't update it)
                resetTitle(file_chooser, parent_path)
                return true
            end
        end
        -- Otherwise, use the original behavior
        return old_onFolderUp(file_chooser)
    end
    
    -- Override onMenuSelect to handle up-item clicks and series group clicks
    FileChooser.onMenuSelect = function(file_chooser, item)
        -- Handle up-item click in virtual folder
        if item.is_go_up and file_chooser.item_table and file_chooser.item_table.is_in_series_view then
            local parent_path = file_chooser.item_table.parent_path
            -- Clear virtual folder state BEFORE letting original handle it
            current_series_group = nil
            -- Call original handler
            local result = old_onMenuSelect(file_chooser, item)
            -- Reset title after navigation
            resetTitle(file_chooser, parent_path)
            return result
        end
        
        -- Handle series group click
        if isEnabled() and item.is_series_group then
            AutomaticSeries:openSeriesGroup(file_chooser, item)
            return true
        end
        
        return old_onMenuSelect(file_chooser, item)
    end
    
    -- Override changeToPath to redirect ".." navigation from virtual folders
    FileChooser.changeToPath = function(file_chooser, path, ...)
        -- If we're in a virtual series view and path contains "..", redirect to real parent
        if file_chooser.item_table and file_chooser.item_table.is_in_series_view then
            local parent_path = file_chooser.item_table.parent_path
            if parent_path and path and (path:match("/%.%.") or path:match("^%.%.")) then
                -- Clear state and redirect (this handles edge cases like "../..")
                current_series_group = nil
                return old_changeToPath(file_chooser, parent_path)
            end
        end
        
        -- Any explicit navigation (like Home button, Go To, etc.) should exit the virtual folder state
        -- This fixes the loop where clicking Home would just restore the series view if Home == parent_path
        current_series_group = nil
        
        -- Otherwise, use the original behavior
        return old_changeToPath(file_chooser, path, ...)
    end
    
    FileChooser.updateItems = function(file_chooser, ...)
        -- Check if enabled
        if not isEnabled() then
            current_series_group = nil
            return old_updateItems(file_chooser, ...)
        end
        
        -- Check trigger conditions early
        if not file_chooser.item_table or #file_chooser.item_table == 0 then
            return old_updateItems(file_chooser, ...)
        end
        
        -- Prevent recursive grouping inside a virtual series folder
        if file_chooser.item_table.is_in_series_view then
            return old_updateItems(file_chooser, ...)
        end
        
        logger.dbg("AutomaticSeries Patch: Grouping triggered for path", file_chooser.path)
        AutomaticSeries:processItemTable(file_chooser.item_table, file_chooser)
        
        -- Check if we should restore a virtual folder view after refresh
        if current_series_group and current_series_group.parent_path == file_chooser.path then
            -- Find the series group in the processed item table
            for _, item in ipairs(file_chooser.item_table) do
                if item.is_series_group and item.text == current_series_group.series_name then
                    -- Call updateItems first to update the UI
                    local result = old_updateItems(file_chooser, ...)
                    AutomaticSeries:openSeriesGroup(file_chooser, item)
                    return result
                end
            end
            -- If series group not found (e.g., no longer meets criteria), clear the state
            current_series_group = nil
        end
    
        return old_updateItems(file_chooser, ...)
    end
    
    -- Add menu item
    local orig_CoverBrowser_addToMainMenu = plugin.addToMainMenu
    
    function plugin:addToMainMenu(menu_items)
        orig_CoverBrowser_addToMainMenu(self, menu_items)
        
        -- Prevent duplicate menu items
        if menu_item_added then return end
        
        -- Add to File browser settings
        if not menu_items.filebrowser_settings then return end
        
        menu_item_added = true
        table.insert(menu_items.filebrowser_settings.sub_item_table, {
            text = _("Group book series into folders"),
            separator = true,
            checked_func = isEnabled,
            callback = function()
                setEnabled(not isEnabled())
                -- Refresh the file browser
                if self.ui and self.ui.file_chooser then
                    self.ui.file_chooser:refreshPath()
                end
            end,
        })
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
