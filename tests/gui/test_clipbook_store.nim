import ../../examples/gui/clipbook/bridge
import std/[os, sequtils, strutils]

var store = newClipStore()

let textId = store.addClipItem("hello from clipboard", "Notes")
assert textId > 0
assert store.items.len == 1
assert store.items[0].kind == ckText

let duplicateId = store.addClipItem("hello from clipboard", "Notes")
assert duplicateId == textId
assert store.items.len == 1

let linkId = store.addClipItem("https://clipbook.app/guides/", "Safari")
let colorId = store.addClipItem("#0A84FF", "Sketch")
let fileId = store.addClipItem("file:///tmp/report.pdf", "Finder", "/tmp/report.pdf")
assert linkId > 0 and colorId > 0 and fileId > 0
assert store.items[store.findItemIndex(linkId)].kind == ckLink
assert store.items[store.findItemIndex(colorId)].kind == ckColor
assert store.items[store.findItemIndex(fileId)].kind == ckFile

store.addTag(linkId, "research")
store.searchQuery = "research"
assert store.visibleItems().len == 1
assert store.visibleItems()[0].id == linkId

store.searchQuery = "clipbook"
assert store.visibleItems().len == 1
store.items[store.findItemIndex(fileId)].ocrText = "invoice total"
store.searchQuery = "invoice"
assert store.visibleItems().len == 1
assert store.visibleItems()[0].id == fileId

store.searchQuery = ""
store.activeFormatFilter = "Link"
assert store.visibleItems().len == 1
assert store.visibleItems()[0].id == linkId

store.activeFormatFilter = "Rich Text"
assert store.visibleItems().len == 0

store.activeFormatFilter = "All"
let mergedId = store.mergeTextItems()
assert mergedId > 0
assert store.items[store.findItemIndex(mergedId)].text.contains("hello from clipboard")
assert store.items[store.findItemIndex(mergedId)].text.contains("https://clipbook.app/guides/")

store.pinItem(colorId)
assert store.items[store.findItemIndex(colorId)].favorite
store.pinItem(colorId)
assert not store.items[store.findItemIndex(colorId)].favorite

store.toggleFavorite(textId)
store.activeFormatFilter = "Favorites"
assert store.visibleItems().len == 1
assert store.visibleItems()[0].id == textId
store.activeFormatFilter = "All"
store.clearHistory()
assert store.items.len == 1
assert store.items[0].id == textId

store.settings.ignoredApps = @["Passwords"]
assert store.addClipItem("secret", "Passwords") == -1
assert store.items.len == 1

store.settings.maxItems = 1
discard store.addClipItem("new visible item", "Notes")
store.enforceRetention()
assert store.items.anyIt(it.favorite)
assert store.items.len <= 2

let oldSupport = getEnv("CLIPBOOK_APP_SUPPORT")
let tmpSupport = getTempDir() / "clipbook-store-test-" & $getCurrentProcessId()
if dirExists(tmpSupport):
  removeDir(tmpSupport)
putEnv("CLIPBOOK_APP_SUPPORT", tmpSupport)

var persisted = newClipStore()
let persistedId = persisted.addClipItem("persistent text", "UnitTest")
persisted.addTag(persistedId, "saved")
persisted.toggleFavorite(persistedId)
persisted.saveSettings()
persisted.saveHistory()
assert fileExists(historyMetadataPath())
assert dirExists(payloadsDir())

var restored = newClipStore()
restored.loadSettings()
restored.loadHistory()
assert restored.items.len == 1
assert restored.items[0].text == "persistent text"
assert restored.items[0].favorite
assert restored.items[0].tags == @["saved"]

if oldSupport.len > 0:
  putEnv("CLIPBOOK_APP_SUPPORT", oldSupport)
else:
  putEnv("CLIPBOOK_APP_SUPPORT", "")
if dirExists(tmpSupport):
  removeDir(tmpSupport)

echo "PASS: ClipBook store serialization-adjacent behavior, dedupe, search, merge, tags, retention, ignored apps"
