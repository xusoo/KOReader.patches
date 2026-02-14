# KOReader Patches

This repository contains custom patches for [KOReader](https://github.com/koreader/koreader). These patches are user scripts that modify KOReader's behavior without altering the core codebase.

## How to Install

1. Download the desired `.lua` file from this repository.
2. Place the file into the `koreader/patches/` directory on your device.
   - If the `patches` directory doesn't exist inside `koreader`, create it.
3. Restart KOReader.

---

## [2-automatic-book-series.lua](2-automatic-book-series.lua): Automatic Book Series

A patch that automatically groups books belonging to the same series into virtual folders within the File Browser.

![](https://i.imgur.com/Jzph3mT.png)

### Features
- **Virtual Grouping**: Instead of seeing 10+ books scattered in a folder, you'll see a single virtual folder for the series (e.g., "Harry Potter").
- **Seamless Integration**: Works directly in your existing folder structure. No need to reorganize your files or use Calibre.
- **Automatic Sorting**: Books inside the virtual folder are sorted automatically by their series index.
- **Smart Skipping**: Single books from a series won't be grouped. If all books in a folder belong to the same series, grouping is skipped to avoid creating virtual folders inside your existing series folders.
- **Toggleable**: Can be enabled/disabled via the File Browser menu.

### How to Use
1. Install the patch as described above.
2. Open the File Browser.
3. To toggle the feature, go to the top menu:
   - **File Browser** (first icon) → **Settings** → **Group book series into folders**

### Compatibility
This patch is designed to work harmoniously with other popular plugins and patches:
- **ProjectTitle / CoverBrowser**: Fully compatible. Virtual series folders will display cover images (either grid or stack) generated from the books inside them.
- **browser-folder-cover patch**: Supported. The virtual folder icon will display the number of books it contains (e.g., "7 📁").
- **browser-up-folder patch**: Supported. If you use a patch to hide/show the `../` (up) item, this patch respects that setting inside virtual folders.

### Release Notes

**v1.0.4 (Current)**
- Improved performance when browsing folders with many books
- Improved compatibility with browser-up-folder extension
- Fixed: Page position is now properly restored when navigating folders or returning from a book
- Series grouping no longer appears in folder selection dialogs
- Various code optimizations and bug fixes

**v1.0.3**
- Improved detection of ProjectTitle plugin
- Fixed some issues with the go-up/home buttons not remembering the page number

**v1.0.2**
- Fixed crash when displaying covers for certain books
- Series folders now properly reopen after reading a book

**v1.0.1**
- Prevent crashes from books with missing metadata
- Avoid grouping if only one book of the series exists
- Don't group series inside existing series folders

**v1.0.0**
- Initial release
- Automatically groups books into virtual series folders
- Works with both default and ProjectTitle cover browsers
