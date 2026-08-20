## Nim bridge logic for the ClipBook-style clipboard manager example.
##
## Payload contract (ABI v5):
## - 4 bytes: action tag (u32 little-endian)
## - 2 bytes: request field count (u16 little-endian)
## - 2 bytes: reserved
## - repeated fields:
##   - 2 bytes field id, 1 byte type, 1 byte reserved, 4 bytes payload length
##   - N bytes field payload

import std/[json, os, sequtils, strutils, tables, times]

type
  ClipboardKind* = enum
    ckText = "Text"
    ckImage = "Image"
    ckFile = "File"
    ckLink = "Link"
    ckColor = "Color"
    ckEmail = "Email"
    ckRichText = "Rich Text"

  ClipItem* = object
    id*: int
    kind*: ClipboardKind
    title*: string
    text*: string
    payloadPath*: string
    sourceApp*: string
    createdAt*: int64
    favorite*: bool
    tags*: seq[string]
    ocrText*: string
    colorHex*: string
    payloadHash*: string
    sizeBytes*: int

  ClipSettings* = object
    preserveFavoritesOnClear*: bool
    clearOnQuit*: bool
    clearOnRestart*: bool
    captureImages*: bool
    captureFiles*: bool
    captureSensitiveApps*: bool
    retainDays*: int
    maxItems*: int
    appearanceMode*: string
    ignoredApps*: seq[string]

  ClipStore* = object
    items*: seq[ClipItem]
    nextId*: int
    selectedItemId*: int
    searchQuery*: string
    activeFormatFilter*: string
    selectedTagFilter*: string
    activeSourceApp*: string
    incomingClipboardKind*: string
    incomingClipboardText*: string
    incomingClipboardPath*: string
    incomingClipboardSource*: string
    pausedCapture*: bool
    settings*: ClipSettings
    statusText*: string
    lastHash*: string

  GUIBridgeBuffer {.bycopy.} = object
    data: ptr uint8
    len: uint32

  GUIBridgeDispatchOutput {.bycopy.} = object
    statePatch: GUIBridgeBuffer
    effects: GUIBridgeBuffer
    emittedActions: GUIBridgeBuffer
    diagnostics: GUIBridgeBuffer

  GUIBridgeFunctionTable {.bycopy.} = object
    abiVersion: uint32
    alloc: proc(size: csize_t): pointer {.cdecl.}
    free: proc(p: pointer) {.cdecl.}
    dispatch: proc(payload: ptr uint8, payloadLen: uint32,
                   outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.}
    getNotifyFd: proc(): int32 {.cdecl.}
    waitShutdown: proc(timeoutMs: int32): int32 {.cdecl.}

  BridgeRuntime* = object
    store*: ClipStore
    persistenceLoaded*: bool

  BridgeDispatchTestResult* = object
    status*: int32
    statePatch*: seq[byte]
    effects*: seq[byte]
    emittedActions*: seq[byte]
    diagnostics*: string

  RequestField = object
    fieldId: uint16
    valueType: uint8
    payload: seq[byte]

  PatchField = object
    fieldId: uint16
    valueType: uint8
    payload: seq[byte]

const
  guiBridgeAbiVersion = 5'u32

  # Action tags (must match action declaration order in app.gui).
  tagPoll = 0'u32
  tagStartCapture = 1'u32
  tagCaptureClipboard = 2'u32
  tagSelectItem = 3'u32
  tagSearchChanged = 4'u32
  tagClearSearch = 5'u32
  tagSetFilterAll = 6'u32
  tagSetFilterText = 7'u32
  tagSetFilterImages = 8'u32
  tagSetFilterFiles = 9'u32
  tagSetFilterLinks = 10'u32
  tagSetFilterColors = 11'u32
  tagSetFilterEmails = 12'u32
  tagToggleFavorite = 13'u32
  tagAddTag = 14'u32
  tagRemoveTag = 15'u32
  tagSelectTag = 16'u32
  tagClearTagFilter = 17'u32
  tagCopyItem = 18'u32
  tagCopyItemAs = 19'u32
  tagPasteItem = 20'u32
  tagShareItem = 21'u32
  tagPinItem = 22'u32
  tagPasteSelectedRange = 23'u32
  tagMergeTextItems = 24'u32
  tagShowMergeConfirm = 25'u32
  tagHideMergeConfirm = 26'u32
  tagEditItem = 27'u32
  tagSaveEdit = 28'u32
  tagHideEditSheet = 29'u32
  tagDeleteItem = 30'u32
  tagClearHistory = 31'u32
  tagCopyOcrText = 32'u32
  tagRunOcr = 33'u32
  tagSaveImage = 34'u32
  tagShowFileInFinder = 35'u32
  tagOpenUrl = 36'u32
  tagTogglePause = 37'u32
  tagShowSettings = 38'u32
  tagHideSettings = 39'u32
  tagSaveSettings = 40'u32
  tagSetAppearanceSystem = 41'u32
  tagSetAppearanceLight = 42'u32
  tagSetAppearanceDark = 43'u32
  tagSetCaptureImages = 44'u32
  tagSetCaptureFiles = 45'u32
  tagSetCaptureSensitiveApps = 46'u32
  tagSetPreserveFavorites = 47'u32
  tagSetClearOnQuit = 48'u32
  tagSetClearOnRestart = 49'u32
  tagTogglePreviewPane = 50'u32
  tagToggleDetailsPane = 51'u32
  tagRestoreWindow = 52'u32
  tagPersistWindow = 53'u32
  tagPasteSlot = 54'u32
  tagSettingsChanged = 55'u32
  tagAppShutdown = 56'u32
  tagRequestDeleteItem = 57'u32
  tagCancelDeleteItem = 58'u32
  tagRequestClearHistory = 59'u32
  tagCancelClearHistory = 60'u32
  tagRequestSaveEdit = 61'u32
  tagCancelSaveEdit = 62'u32
  tagRequestAddTag = 63'u32
  tagCancelAddTag = 64'u32
  tagRequestToggleFavorite = 65'u32
  tagCancelToggleFavorite = 66'u32
  tagRequestRunOcr = 67'u32
  tagCancelRunOcr = 68'u32
  tagSetFilterFavorites = 69'u32
  tagSetFilterRichText = 70'u32

  # Binary field IDs (must match app.gui state field declaration order).
  fldHistory = 1'u16
  fldFormats = 2'u16
  fldTags = 3'u16
  fldSourceApps = 4'u16
  fldStats = 5'u16
  fldSelectedItemId = 6'u16
  fldSelectedKind = 7'u16
  fldSelectedTitle = 8'u16
  fldSelectedPreviewText = 9'u16
  fldSelectedDetailText = 10'u16
  fldSelectedTagsText = 11'u16
  fldSelectedSourceApp = 12'u16
  fldSelectedTimestamp = 13'u16
  fldSelectedPayloadPath = 14'u16
  fldSelectedColorHex = 15'u16
  fldSelectedOcrText = 16'u16
  fldSelectedIsFavorite = 17'u16
  fldSearchQuery = 18'u16
  fldActiveFormatFilter = 19'u16
  fldSelectedTagFilter = 20'u16
  fldActiveSourceApp = 21'u16
  fldEditTitle = 22'u16
  fldEditText = 23'u16
  fldTagDraft = 24'u16
  fldShowPreview = 25'u16
  fldShowDetails = 26'u16
  fldShowSettings = 27'u16
  fldShowEditSheet = 28'u16
  fldShowMergeConfirm = 29'u16
  fldShowDeleteConfirm = 30'u16
  fldShowClearHistoryConfirm = 31'u16
  fldShowSaveEditConfirm = 32'u16
  fldShowAddTagConfirm = 33'u16
  fldShowFavoriteConfirm = 34'u16
  fldShowOcrConfirm = 35'u16
  fldPausedCapture = 36'u16
  fldPreserveFavoritesOnClear = 37'u16
  fldClearOnQuit = 38'u16
  fldClearOnRestart = 39'u16
  fldCaptureImages = 40'u16
  fldCaptureFiles = 41'u16
  fldCaptureSensitiveApps = 42'u16
  fldRetainDays = 43'u16
  fldMaxItems = 44'u16
  fldAppearanceMode = 45'u16
  fldIgnoredAppsText = 46'u16
  fldMultiPasteCount = 47'u16
  fldStatusText = 48'u16
  fldPollActive = 49'u16
  fldAccessibilityTrusted = 50'u16
  fldIncomingClipboardKind = 51'u16
  fldIncomingClipboardText = 52'u16
  fldIncomingClipboardPath = 53'u16
  fldIncomingClipboardSource = 54'u16
  fldStoragePath = 55'u16
  fldActionItemId = 56'u16
  fldRestoreClipboardItemId = 57'u16
  fldRevealInFinderItemId = 58'u16
  fldPendingDeleteItemId = 59'u16
  fldPendingFavoriteItemId = 60'u16
  fldHistoryCountText = 61'u16
  fldCopyAsItemId = 62'u16
  fldShareItemId = 63'u16

  # Binary wire value types.
  bridgeTypeBool = 1'u8
  bridgeTypeInt64 = 2'u8
  bridgeTypeDouble = 3'u8
  bridgeTypeString = 4'u8
  bridgeTypeJson = 5'u8

var
  gRuntime: BridgeRuntime
  gInitialized = false

proc defaultSettings(): ClipSettings =
  ClipSettings(
    preserveFavoritesOnClear: true,
    clearOnQuit: false,
    clearOnRestart: false,
    captureImages: true,
    captureFiles: true,
    captureSensitiveApps: false,
    retainDays: 30,
    maxItems: 500,
    appearanceMode: "System",
    ignoredApps: @[]
  )

proc initStore*(store: var ClipStore) =
  store.items = @[]
  store.nextId = 1
  store.selectedItemId = -1
  store.searchQuery = ""
  store.activeFormatFilter = "All"
  store.selectedTagFilter = ""
  store.activeSourceApp = "All Apps"
  store.incomingClipboardKind = ""
  store.incomingClipboardText = ""
  store.incomingClipboardPath = ""
  store.incomingClipboardSource = ""
  store.pausedCapture = false
  store.settings = defaultSettings()
  store.statusText = "Ready"
  store.lastHash = ""

proc newClipStore*(): ClipStore =
  initStore(result)

proc newTestRuntime*(): BridgeRuntime =
  result.store = newClipStore()
  result.persistenceLoaded = true

proc bridgeAlloc(size: csize_t): pointer {.cdecl.} =
  if size <= 0:
    return nil
  allocShared(size)

proc bridgeFree(p: pointer) {.cdecl.} =
  if p != nil:
    deallocShared(p)

proc writeBlob(value: openArray[byte]): GUIBridgeBuffer =
  if value.len == 0:
    return GUIBridgeBuffer(data: nil, len: 0)
  let mem = cast[ptr uint8](bridgeAlloc(value.len.csize_t))
  if mem == nil:
    return GUIBridgeBuffer(data: nil, len: 0)
  copyMem(mem, unsafeAddr value[0], value.len)
  GUIBridgeBuffer(data: mem, len: value.len.uint32)

proc copyBlob(buf: GUIBridgeBuffer): seq[byte] =
  if buf.data == nil or buf.len == 0:
    return @[]
  result = newSeq[byte](buf.len.int)
  copyMem(addr result[0], buf.data, result.len)

proc freeBlob(buf: GUIBridgeBuffer) =
  if buf.data != nil:
    bridgeFree(buf.data)

proc toBytes(text: string): seq[byte] =
  if text.len == 0:
    return @[]
  result = newSeq[byte](text.len)
  copyMem(addr result[0], unsafeAddr text[0], text.len)

proc toText(bytes: openArray[byte]): string =
  if bytes.len == 0:
    return ""
  result = newString(bytes.len)
  copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc appendLeU16(dst: var seq[byte], value: uint16) {.inline.} =
  dst.add byte(value and 0xFF'u16)
  dst.add byte((value shr 8) and 0xFF'u16)

proc appendLeU32(dst: var seq[byte], value: uint32) {.inline.} =
  dst.add byte(value and 0xFF'u32)
  dst.add byte((value shr 8) and 0xFF'u32)
  dst.add byte((value shr 16) and 0xFF'u32)
  dst.add byte((value shr 24) and 0xFF'u32)

proc decodeLeU16(data: ptr UncheckedArray[uint8], offset: int): uint16 =
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc decodeLeU32(data: ptr UncheckedArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
    (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or
    (uint32(data[offset + 3]) shl 24)

proc encodeInt64Bytes(value: int64): seq[byte] =
  let bits = cast[uint64](value)
  result = newSeq[byte](8)
  for i in 0 ..< 8:
    result[i] = byte((bits shr (8 * i)) and 0xFF'u64)

proc decodeInt64Bytes(payload: openArray[byte], default: int64 = 0): int64 =
  if payload.len < 8:
    return default
  var bits: uint64 = 0
  for i in 0 ..< 8:
    bits = bits or (uint64(payload[i]) shl (8 * i))
  cast[int64](bits)

proc parseKind*(value: string): ClipboardKind =
  case value.strip().toLowerAscii()
  of "image", "images": ckImage
  of "file", "files": ckFile
  of "link", "url", "urls": ckLink
  of "color", "colors": ckColor
  of "email", "emails": ckEmail
  of "rich text", "richtext", "rtf": ckRichText
  else: ckText

proc inferKind*(text, payloadPath: string): ClipboardKind =
  let t = text.strip()
  if payloadPath.len > 0:
    let ext = splitFile(payloadPath).ext.toLowerAscii()
    if ext in [".png", ".jpg", ".jpeg", ".gif", ".heic", ".tiff", ".webp"]:
      return ckImage
    return ckFile
  if t.startsWith("http://") or t.startsWith("https://"):
    return ckLink
  if t.len > 3 and t[0] == '#' and t.len in [4, 7, 9]:
    return ckColor
  if t.contains("@") and t.contains(".") and not t.contains(" "):
    return ckEmail
  ckText

proc stableHash*(kind: ClipboardKind, text, payloadPath: string): string =
  ## Deterministic FNV-1a hash, suitable for local dedupe keys.
  var h = 1469598103934665603'u64
  let material = $kind & "\0" & text & "\0" & payloadPath
  for c in material:
    h = h xor uint64(ord(c))
    h = h * 1099511628211'u64
  result = toHex(h)

proc titleFor(kind: ClipboardKind, text, payloadPath: string): string =
  if payloadPath.len > 0:
    return extractFilename(payloadPath)
  let oneLine = text.replace("\n", " ").strip()
  if oneLine.len == 0:
    return $kind
  if oneLine.len > 64:
    oneLine[0 ..< 61] & "..."
  else:
    oneLine

proc timestampLabel(epoch: int64): string =
  try:
    fromUnix(epoch).local.format("HH:mm")
  except CatchableError:
    ""

proc sizeLabel(item: ClipItem): string =
  let n = if item.sizeBytes > 0: item.sizeBytes else: item.text.len
  if n >= 1024 * 1024:
    $(n div (1024 * 1024)) & " MB"
  elif n >= 1024:
    $(n div 1024) & " KB"
  else:
    $n & " B"

proc normalizeApp(value: string): string =
  let v = value.strip()
  if v.len == 0: "Unknown"
  else: v

proc isIgnored(store: ClipStore, sourceApp: string): bool =
  let app = sourceApp.normalizeApp.toLowerAscii()
  for ignored in store.settings.ignoredApps:
    if ignored.strip().toLowerAscii() == app:
      return true
  false

proc enforceRetention*(store: var ClipStore) =
  if store.settings.retainDays > 0:
    let cutoff = getTime().toUnix() - int64(store.settings.retainDays) * 24 * 60 * 60
    store.items = store.items.filterIt(it.favorite or it.createdAt >= cutoff)
  if store.settings.maxItems > 0 and store.items.len > store.settings.maxItems:
    var keep: seq[ClipItem] = @[]
    var nonFavBudget = store.settings.maxItems
    for item in store.items:
      if item.favorite:
        keep.add item
      elif nonFavBudget > 0:
        keep.add item
        dec nonFavBudget
    store.items = keep

proc addClipItem*(store: var ClipStore, text: string, sourceApp = "Unknown",
                  payloadPath = "", kindOverride = ""): int =
  if store.pausedCapture:
    store.statusText = "Capture paused"
    return -1
  let app = sourceApp.normalizeApp()
  if store.isIgnored(app):
    store.statusText = "Ignored clipboard from " & app
    return -1
  let kind = if kindOverride.len > 0: parseKind(kindOverride) else: inferKind(text, payloadPath)
  if kind == ckImage and not store.settings.captureImages:
    store.statusText = "Image capture disabled"
    return -1
  if kind == ckFile and not store.settings.captureFiles:
    store.statusText = "File capture disabled"
    return -1
  let hash = stableHash(kind, text, payloadPath)
  for i in 0 ..< store.items.len:
    if store.items[i].payloadHash == hash:
      let existing = store.items[i]
      store.items.delete(i)
      store.items.insert(existing, 0)
      store.selectedItemId = existing.id
      store.statusText = "Moved duplicate to top"
      return existing.id
  let item = ClipItem(
    id: store.nextId,
    kind: kind,
    title: titleFor(kind, text, payloadPath),
    text: text,
    payloadPath: payloadPath,
    sourceApp: app,
    createdAt: getTime().toUnix(),
    favorite: false,
    tags: @[],
    ocrText: "",
    colorHex: if kind == ckColor: text.strip() else: "",
    payloadHash: hash,
    sizeBytes: max(text.len, payloadPath.len)
  )
  inc store.nextId
  store.items.insert(item, 0)
  store.selectedItemId = item.id
  store.lastHash = hash
  store.statusText = "Captured " & $kind & " from " & app
  store.enforceRetention()
  item.id

proc findItemIndex*(store: ClipStore, itemId: int): int =
  for i, item in store.items:
    if item.id == itemId:
      return i
  -1

proc selectedIndex(store: ClipStore): int =
  store.findItemIndex(store.selectedItemId)

proc searchableText(item: ClipItem): string =
  ($item.kind & " " & item.title & " " & item.text & " " & item.payloadPath & " " &
    item.sourceApp & " " & item.ocrText & " " & item.tags.join(" ")).toLowerAscii()

proc visibleItems*(store: ClipStore): seq[ClipItem] =
  let query = store.searchQuery.strip().toLowerAscii()
  let kindFilter = store.activeFormatFilter.strip()
  let tagFilter = store.selectedTagFilter.strip().toLowerAscii()
  let appFilter = store.activeSourceApp.strip().toLowerAscii()
  for item in store.items:
    if kindFilter == "Favorites":
      if not item.favorite:
        continue
    elif kindFilter.len > 0 and kindFilter != "All" and $item.kind != kindFilter:
      continue
    if tagFilter.len > 0 and not item.tags.anyIt(it.toLowerAscii() == tagFilter):
      continue
    if appFilter.len > 0 and appFilter != "all apps" and item.sourceApp.toLowerAscii() != appFilter:
      continue
    if query.len > 0 and not item.searchableText.contains(query):
      continue
    result.add item

proc selectItem*(store: var ClipStore, itemId: int) =
  if store.findItemIndex(itemId) >= 0:
    store.selectedItemId = itemId
    store.statusText = "Selected item " & $itemId

proc toggleFavorite*(store: var ClipStore, itemId: int) =
  let idx = store.findItemIndex(itemId)
  if idx >= 0:
    store.items[idx].favorite = not store.items[idx].favorite
    store.statusText = if store.items[idx].favorite: "Added favorite" else: "Removed favorite"

proc recordCopiedItem*(store: var ClipStore, itemId: int, asPlainText = false): int =
  let idx = store.findItemIndex(itemId)
  if idx < 0:
    store.statusText = "No item selected"
    return -1
  let src = store.items[idx]
  if not asPlainText:
    store.items.delete(idx)
    store.items.insert(src, 0)
    store.selectedItemId = src.id
    store.statusText = "Moved copied item to top"
    return src.id
  let now = getTime().toUnix()
  let text =
    if src.text.len > 0: src.text
    elif src.payloadPath.len > 0: src.payloadPath
    else: src.title
  let kind = ckText
  let payloadPath = ""
  let item = ClipItem(
    id: store.nextId,
    kind: kind,
    title: titleFor(kind, text, payloadPath),
    text: text,
    payloadPath: payloadPath,
    sourceApp: "ClipBook",
    createdAt: now,
    favorite: false,
    tags: src.tags,
    ocrText: src.ocrText,
    colorHex: if kind == ckColor: src.colorHex else: "",
    payloadHash: "clipbook-copy:" & $src.id & ":" & $now & ":" & $store.nextId,
    sizeBytes: max(text.len, payloadPath.len)
  )
  inc store.nextId
  store.items.insert(item, 0)
  store.selectedItemId = item.id
  store.statusText = "Copied item as plain text"
  store.enforceRetention()
  item.id

proc pinItem*(store: var ClipStore, itemId: int) =
  let idx = store.findItemIndex(itemId)
  if idx >= 0:
    store.items[idx].favorite = not store.items[idx].favorite
    store.selectedItemId = itemId
    store.statusText = if store.items[idx].favorite: "Pinned item" else: "Unpinned item"

proc addTag*(store: var ClipStore, itemId: int, tag: string) =
  let clean = tag.strip()
  if clean.len == 0:
    return
  let idx = store.findItemIndex(itemId)
  if idx >= 0 and not store.items[idx].tags.anyIt(it.cmpIgnoreCase(clean) == 0):
    store.items[idx].tags.add clean
    store.statusText = "Tagged " & clean

proc removeTag*(store: var ClipStore, itemId: int, tag: string) =
  let idx = store.findItemIndex(itemId)
  if idx < 0:
    return
  store.items[idx].tags = store.items[idx].tags.filterIt(it.cmpIgnoreCase(tag) != 0)
  store.statusText = "Removed tag"

proc mergeTextItems*(store: var ClipStore): int =
  var parts: seq[string] = @[]
  for item in store.visibleItems:
    if item.kind in {ckText, ckLink, ckEmail, ckColor, ckRichText}:
      parts.add item.text
    if parts.len >= 5:
      break
  if parts.len == 0:
    store.statusText = "No mergeable text items"
    return -1
  result = store.addClipItem(parts.join("\n"), "ClipBook", "", "Text")
  if result >= 0:
    store.statusText = "Merged " & $parts.len & " items"

proc deleteItem*(store: var ClipStore, itemId: int) =
  let idx = store.findItemIndex(itemId)
  if idx >= 0:
    store.items.delete(idx)
    if store.selectedItemId == itemId:
      store.selectedItemId = if store.items.len > 0: store.items[0].id else: -1
    store.statusText = "Deleted item"

proc clearHistory*(store: var ClipStore) =
  if store.settings.preserveFavoritesOnClear:
    store.items = store.items.filterIt(it.favorite)
  else:
    store.items.setLen(0)
  store.selectedItemId = if store.items.len > 0: store.items[0].id else: -1
  store.statusText = "Cleared history"

proc editSelected*(store: var ClipStore, title, text: string) =
  let idx = store.selectedIndex()
  if idx >= 0:
    if title.strip().len > 0:
      store.items[idx].title = title.strip()
    if store.items[idx].kind in {ckText, ckLink, ckEmail, ckColor, ckRichText}:
      store.items[idx].text = text
      store.items[idx].payloadHash = stableHash(store.items[idx].kind, text, store.items[idx].payloadPath)
    store.statusText = "Saved item"

proc selectedItem(store: ClipStore): ClipItem =
  let idx = store.selectedIndex()
  if idx >= 0:
    store.items[idx]
  else:
    ClipItem(id: -1, kind: ckText, title: "No item selected", text: "", sourceApp: "", createdAt: 0)

proc storageRoot*(): string =
  let overrideDir = getEnv("CLIPBOOK_APP_SUPPORT")
  if overrideDir.len > 0:
    return overrideDir
  let home = getHomeDir()
  home / "Library" / "Application Support" / "CPS ClipBook"

proc persistenceDir(): string =
  storageRoot()

proc payloadsDir*(): string =
  persistenceDir() / "Payloads"

proc historyMetadataPath*(): string =
  persistenceDir() / "history.json"

proc metadataPath(): string =
  historyMetadataPath()

proc settingsPath*(): string =
  persistenceDir() / "settings.json"

proc ensureStorageDirs*() =
  createDir(persistenceDir())
  createDir(payloadsDir())

proc writeFileAtomic(path, content: string) =
  ensureStorageDirs()
  let tmp = path & ".tmp"
  writeFile(tmp, content)
  if fileExists(path):
    removeFile(path)
  moveFile(tmp, path)

proc saveSettings*(store: ClipStore) =
  let node = %*{
    "preserveFavoritesOnClear": store.settings.preserveFavoritesOnClear,
    "clearOnQuit": store.settings.clearOnQuit,
    "clearOnRestart": store.settings.clearOnRestart,
    "captureImages": store.settings.captureImages,
    "captureFiles": store.settings.captureFiles,
    "captureSensitiveApps": store.settings.captureSensitiveApps,
    "retainDays": store.settings.retainDays,
    "maxItems": store.settings.maxItems,
    "appearanceMode": store.settings.appearanceMode,
    "ignoredApps": store.settings.ignoredApps
  }
  writeFileAtomic(settingsPath(), $node)

proc loadSettings*(store: var ClipStore) =
  if not fileExists(settingsPath()):
    return
  try:
    let node = parseFile(settingsPath())
    store.settings.preserveFavoritesOnClear = node{"preserveFavoritesOnClear"}.getBool(store.settings.preserveFavoritesOnClear)
    store.settings.clearOnQuit = node{"clearOnQuit"}.getBool(store.settings.clearOnQuit)
    store.settings.clearOnRestart = node{"clearOnRestart"}.getBool(store.settings.clearOnRestart)
    store.settings.captureImages = node{"captureImages"}.getBool(store.settings.captureImages)
    store.settings.captureFiles = node{"captureFiles"}.getBool(store.settings.captureFiles)
    store.settings.captureSensitiveApps = node{"captureSensitiveApps"}.getBool(store.settings.captureSensitiveApps)
    store.settings.retainDays = node{"retainDays"}.getInt(store.settings.retainDays)
    store.settings.maxItems = node{"maxItems"}.getInt(store.settings.maxItems)
    store.settings.appearanceMode = node{"appearanceMode"}.getStr(store.settings.appearanceMode)
    store.settings.ignoredApps = @[]
    for child in node{"ignoredApps"}.items:
      store.settings.ignoredApps.add child.getStr()
  except CatchableError:
    store.statusText = "Could not load settings"

proc itemToJson(item: ClipItem): JsonNode =
  %*{
    "id": item.id,
    "kind": $item.kind,
    "title": item.title,
    "text": item.text,
    "payloadPath": item.payloadPath,
    "sourceApp": item.sourceApp,
    "createdAt": item.createdAt,
    "favorite": item.favorite,
    "tags": item.tags,
    "ocrText": item.ocrText,
    "colorHex": item.colorHex,
    "payloadHash": item.payloadHash,
    "sizeBytes": item.sizeBytes
  }

proc itemFromJson(node: JsonNode): ClipItem =
  result.kind = parseKind(node{"kind"}.getStr("Text"))
  result.id = node{"id"}.getInt(0)
  result.title = node{"title"}.getStr("")
  result.text = node{"text"}.getStr("")
  result.payloadPath = node{"payloadPath"}.getStr("")
  result.sourceApp = node{"sourceApp"}.getStr("Unknown")
  result.createdAt = node{"createdAt"}.getBiggestInt(0).int64
  result.favorite = node{"favorite"}.getBool(false)
  result.tags = @[]
  for child in node{"tags"}.items:
    result.tags.add child.getStr()
  result.ocrText = node{"ocrText"}.getStr("")
  result.colorHex = node{"colorHex"}.getStr("")
  result.payloadHash = node{"payloadHash"}.getStr(stableHash(result.kind, result.text, result.payloadPath))
  result.sizeBytes = node{"sizeBytes"}.getInt(max(result.text.len, result.payloadPath.len))

proc saveHistory*(store: ClipStore) =
  var arr = newJArray()
  for item in store.items:
    arr.add item.itemToJson()
  writeFileAtomic(metadataPath(), $arr)

proc loadHistory*(store: var ClipStore) =
  if not fileExists(metadataPath()):
    return
  try:
    let arr = parseFile(metadataPath())
    store.items = @[]
    var maxId = 0
    for child in arr.items:
      let item = itemFromJson(child)
      store.items.add item
      maxId = max(maxId, item.id)
    store.nextId = max(store.nextId, maxId + 1)
    store.selectedItemId = if store.items.len > 0: store.items[0].id else: -1
  except CatchableError:
    store.statusText = "Could not load history"

proc escapeJson(s: string): string =
  $(%s)

proc itemSubtitle(item: ClipItem): string =
  if item.payloadPath.len > 0:
    return item.payloadPath
  let p = item.text.replace("\n", " ").strip()
  if p.len > 92: p[0 ..< 89] & "..." else: p

proc buildHistoryJson(store: ClipStore): string =
  var arr = newJArray()
  for item in store.visibleItems:
    arr.add %*{
      "id": item.id,
      "kind": $item.kind,
      "title": item.title,
      "subtitle": item.itemSubtitle(),
      "preview": item.text,
      "sourceApp": item.sourceApp,
      "timestamp": timestampLabel(item.createdAt),
      "sizeText": sizeLabel(item),
      "favorite": item.favorite,
      "tagsText": item.tags.join(", "),
      "colorHex": item.colorHex,
      "active": item.id == store.selectedItemId
    }
  $arr

proc buildFormatsJson(store: ClipStore): string =
  var counts = initTable[string, int]()
  for item in store.items:
    counts[$item.kind] = counts.getOrDefault($item.kind) + 1
  var arr = newJArray()
  let names = @["All", "Text", "Image", "File", "Link", "Color", "Email"]
  for i, name in names:
    arr.add %*{
      "id": i,
      "name": name,
      "count": if name == "All": store.items.len else: counts.getOrDefault(name),
      "active": store.activeFormatFilter == name
    }
  $arr

proc buildTagsJson(store: ClipStore): string =
  var counts = initTable[string, int]()
  for item in store.items:
    for tag in item.tags:
      counts[tag] = counts.getOrDefault(tag) + 1
  var arr = newJArray()
  var i = 0
  for tag, count in counts.pairs:
    arr.add %*{
      "id": i,
      "name": tag,
      "color": "#0A84FF",
      "count": count,
      "selected": tag.cmpIgnoreCase(store.selectedTagFilter) == 0
    }
    inc i
  $arr

proc buildSourceAppsJson(store: ClipStore): string =
  var counts = initTable[string, int]()
  for item in store.items:
    counts[item.sourceApp] = counts.getOrDefault(item.sourceApp) + 1
  var arr = newJArray()
  var i = 0
  arr.add %*{"id": i, "name": "All Apps", "count": store.items.len, "ignored": false}
  inc i
  for app, count in counts.pairs:
    arr.add %*{
      "id": i,
      "name": app,
      "count": count,
      "ignored": store.isIgnored(app)
    }
    inc i
  $arr

proc buildStatsJson(store: ClipStore): string =
  var textCount, imageCount, fileCount, favCount: int
  for item in store.items:
    if item.kind in {ckText, ckLink, ckEmail, ckColor, ckRichText}: inc textCount
    if item.kind == ckImage: inc imageCount
    if item.favorite: inc favCount
  $(%*[
    {
      "total": store.items.len,
      "text": textCount,
      "images": imageCount,
      "files": fileCount,
      "favorites": favCount
    }
  ])

proc selectedDetail(item: ClipItem): string =
  if item.id < 0:
    return ""
  @[
    "ID: " & $item.id,
    "Type: " & $item.kind,
    "Source: " & item.sourceApp,
    "Path: " & item.payloadPath,
    "Tags: " & item.tags.join(", "),
    "OCR: " & (if item.ocrText.len > 0: item.ocrText else: "none")
  ].join("\n")

proc addPatchField(fields: var seq[PatchField], fieldId: uint16, valueType: uint8, payload: seq[byte]) =
  fields.add PatchField(fieldId: fieldId, valueType: valueType, payload: payload)

proc addPatchString(fields: var seq[PatchField], fieldId: uint16, value: string) =
  addPatchField(fields, fieldId, bridgeTypeString, toBytes(value))

proc addPatchJson(fields: var seq[PatchField], fieldId: uint16, value: string) =
  addPatchField(fields, fieldId, bridgeTypeJson, toBytes(value))

proc addPatchBool(fields: var seq[PatchField], fieldId: uint16, value: bool) =
  addPatchField(fields, fieldId, bridgeTypeBool, @[if value: 1'u8 else: 0'u8])

proc addPatchInt(fields: var seq[PatchField], fieldId: uint16, value: int) =
  addPatchField(fields, fieldId, bridgeTypeInt64, encodeInt64Bytes(value.int64))

proc encodePatch(fields: seq[PatchField]): seq[byte] =
  appendLeU16(result, min(fields.len, int(high(uint16))).uint16)
  appendLeU16(result, 0'u16)
  for field in fields:
    appendLeU16(result, field.fieldId)
    result.add field.valueType
    result.add 0'u8
    appendLeU32(result, field.payload.len.uint32)
    if field.payload.len > 0:
      result.add field.payload

proc buildPatch*(store: ClipStore, actionTag: uint32 = high(uint32)): seq[byte] =
  let item = store.selectedItem()
  let historyCountLabel = $store.items.len & (if store.items.len == 1: " clip" else: " clips")
  var fields: seq[PatchField] = @[]
  addPatchJson(fields, fldHistory, store.buildHistoryJson())
  addPatchJson(fields, fldFormats, store.buildFormatsJson())
  addPatchJson(fields, fldTags, store.buildTagsJson())
  addPatchJson(fields, fldSourceApps, store.buildSourceAppsJson())
  addPatchJson(fields, fldStats, store.buildStatsJson())
  addPatchInt(fields, fldSelectedItemId, store.selectedItemId)
  addPatchString(fields, fldSelectedKind, if item.id >= 0: $item.kind else: "")
  addPatchString(fields, fldSelectedTitle, item.title)
  addPatchString(fields, fldSelectedPreviewText, item.text)
  addPatchString(fields, fldSelectedDetailText, item.selectedDetail() & "\nStorage: " & metadataPath())
  addPatchString(fields, fldSelectedTagsText, item.tags.join(", "))
  addPatchString(fields, fldSelectedSourceApp, item.sourceApp)
  addPatchString(fields, fldSelectedTimestamp, timestampLabel(item.createdAt))
  addPatchString(fields, fldSelectedPayloadPath, item.payloadPath)
  addPatchString(fields, fldSelectedColorHex, item.colorHex)
  addPatchString(fields, fldSelectedOcrText, item.ocrText)
  addPatchBool(fields, fldSelectedIsFavorite, item.favorite)
  addPatchString(fields, fldSearchQuery, store.searchQuery)
  addPatchString(fields, fldActiveFormatFilter, store.activeFormatFilter)
  addPatchString(fields, fldSelectedTagFilter, store.selectedTagFilter)
  addPatchString(fields, fldActiveSourceApp, store.activeSourceApp)
  case actionTag
  of tagEditItem, tagRestoreWindow, tagStartCapture:
    addPatchString(fields, fldEditTitle, item.title)
    addPatchString(fields, fldEditText, item.text)
  else:
    discard
  addPatchBool(fields, fldPausedCapture, store.pausedCapture)
  addPatchBool(fields, fldPreserveFavoritesOnClear, store.settings.preserveFavoritesOnClear)
  addPatchBool(fields, fldClearOnQuit, store.settings.clearOnQuit)
  addPatchBool(fields, fldClearOnRestart, store.settings.clearOnRestart)
  addPatchBool(fields, fldCaptureImages, store.settings.captureImages)
  addPatchBool(fields, fldCaptureFiles, store.settings.captureFiles)
  addPatchBool(fields, fldCaptureSensitiveApps, store.settings.captureSensitiveApps)
  addPatchString(fields, fldRetainDays, $store.settings.retainDays)
  addPatchString(fields, fldMaxItems, $store.settings.maxItems)
  addPatchString(fields, fldAppearanceMode, store.settings.appearanceMode)
  addPatchString(fields, fldIgnoredAppsText, store.settings.ignoredApps.join(", "))
  addPatchString(fields, fldStatusText, store.statusText)
  addPatchBool(fields, fldPollActive, true)
  addPatchBool(fields, fldAccessibilityTrusted, false)
  addPatchString(fields, fldStoragePath, metadataPath())
  addPatchInt(fields, fldActionItemId, -1)
  addPatchInt(fields, fldRestoreClipboardItemId, -1)
  addPatchInt(fields, fldRevealInFinderItemId, -1)
  addPatchString(fields, fldHistoryCountText, historyCountLabel)
  addPatchInt(fields, fldCopyAsItemId, -1)
  addPatchInt(fields, fldShareItemId, -1)
  encodePatch(fields)

proc decodeRequestFields(payload: ptr uint8, payloadLen: uint32): seq[RequestField] =
  if payload == nil or payloadLen < 8:
    return @[]
  let arr = cast[ptr UncheckedArray[uint8]](payload)
  let count = decodeLeU16(arr, 4).int
  var offset = 8
  for _ in 0 ..< count:
    if offset + 7 >= payloadLen.int:
      break
    let fieldId = decodeLeU16(arr, offset)
    let valueType = arr[offset + 2]
    let valueLen = decodeLeU32(arr, offset + 4).int
    offset += 8
    if valueLen < 0 or offset + valueLen > payloadLen.int:
      break
    var bytes: seq[byte] = @[]
    if valueLen > 0:
      bytes = newSeq[byte](valueLen)
      copyMem(addr bytes[0], addr arr[offset], valueLen)
    result.add RequestField(fieldId: fieldId, valueType: valueType, payload: bytes)
    offset += valueLen

proc decodeActionTag(payload: ptr uint8, payloadLen: uint32): uint32 =
  if payload == nil or payloadLen < 4:
    return high(uint32)
  decodeLeU32(cast[ptr UncheckedArray[uint8]](payload), 0)

proc syncFromFields(store: var ClipStore, fields: seq[RequestField]) =
  for field in fields:
    case field.fieldId
    of fldSelectedItemId:
      if field.valueType == bridgeTypeInt64:
        store.selectedItemId = decodeInt64Bytes(field.payload, store.selectedItemId.int64).int
    of fldSearchQuery:
      if field.valueType == bridgeTypeString:
        store.searchQuery = toText(field.payload)
    of fldActiveFormatFilter:
      if field.valueType == bridgeTypeString:
        store.activeFormatFilter = toText(field.payload)
    of fldSelectedTagFilter:
      if field.valueType == bridgeTypeString:
        store.selectedTagFilter = toText(field.payload)
    of fldActiveSourceApp:
      if field.valueType == bridgeTypeString:
        store.activeSourceApp = toText(field.payload)
    of fldEditTitle:
      discard
    of fldEditText:
      discard
    of fldTagDraft:
      discard
    of fldPausedCapture:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        store.pausedCapture = field.payload[0] != 0
    of fldPreserveFavoritesOnClear:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        store.settings.preserveFavoritesOnClear = field.payload[0] != 0
    of fldClearOnQuit:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        store.settings.clearOnQuit = field.payload[0] != 0
    of fldClearOnRestart:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        store.settings.clearOnRestart = field.payload[0] != 0
    of fldCaptureImages:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        store.settings.captureImages = field.payload[0] != 0
    of fldCaptureFiles:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        store.settings.captureFiles = field.payload[0] != 0
    of fldCaptureSensitiveApps:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        store.settings.captureSensitiveApps = field.payload[0] != 0
    of fldRetainDays:
      if field.valueType == bridgeTypeString:
        try: store.settings.retainDays = max(0, parseInt(toText(field.payload)))
        except ValueError: discard
    of fldMaxItems:
      if field.valueType == bridgeTypeString:
        try: store.settings.maxItems = max(1, parseInt(toText(field.payload)))
        except ValueError: discard
    of fldAppearanceMode:
      if field.valueType == bridgeTypeString:
        store.settings.appearanceMode = toText(field.payload)
    of fldIgnoredAppsText:
      if field.valueType == bridgeTypeString:
        store.settings.ignoredApps = toText(field.payload).split(",").mapIt(it.strip()).filterIt(it.len > 0)
    of fldIncomingClipboardKind:
      if field.valueType == bridgeTypeString:
        store.incomingClipboardKind = toText(field.payload)
    of fldIncomingClipboardText:
      if field.valueType == bridgeTypeString:
        store.incomingClipboardText = toText(field.payload)
    of fldIncomingClipboardPath:
      if field.valueType == bridgeTypeString:
        store.incomingClipboardPath = toText(field.payload)
    of fldIncomingClipboardSource:
      if field.valueType == bridgeTypeString:
        store.incomingClipboardSource = toText(field.payload)
    else:
      discard

proc actionName(tag: uint32): string =
  case tag
  of tagPoll: "Poll"
  of tagStartCapture: "StartCapture"
  of tagCaptureClipboard: "CaptureClipboard"
  of tagSelectItem: "SelectItem"
  of tagSearchChanged: "SearchChanged"
  of tagClearSearch: "ClearSearch"
  of tagMergeTextItems: "MergeTextItems"
  of tagClearHistory: "ClearHistory"
  of tagSaveSettings: "SaveSettings"
  of tagSettingsChanged: "SettingsChanged"
  of tagCopyItem: "CopyItem"
  of tagCopyItemAs: "CopyItemAs"
  of tagShareItem: "ShareItem"
  of tagPinItem: "PinItem"
  else: "Action" & $tag

proc ensureInitialized(runtime: var BridgeRuntime) =
  if runtime.store.nextId == 0:
    runtime.store = newClipStore()
    runtime.persistenceLoaded = false
  if not gInitialized:
    gRuntime.store = newClipStore()
    gRuntime.persistenceLoaded = false
    gInitialized = true

proc loadPersistence(runtime: var BridgeRuntime, allowClearOnRestart: bool) =
  if runtime.persistenceLoaded:
    return
  ensureStorageDirs()
  runtime.store.loadSettings()
  if allowClearOnRestart and runtime.store.settings.clearOnRestart:
    runtime.store.items.setLen(0)
    runtime.store.nextId = 1
    runtime.store.selectedItemId = -1
    runtime.store.saveHistory()
  else:
    runtime.store.loadHistory()
  runtime.persistenceLoaded = true

proc shouldSaveHistory(actionTag: uint32): bool =
  case actionTag
  of tagCaptureClipboard, tagCopyItem, tagCopyItemAs, tagPinItem,
     tagToggleFavorite, tagAddTag, tagRemoveTag, tagMergeTextItems,
     tagSaveEdit, tagDeleteItem, tagClearHistory, tagRunOcr:
    true
  else:
    false

proc dispatch*(runtime: var BridgeRuntime, payload: ptr uint8, payloadLen: uint32,
               outp: ptr GUIBridgeDispatchOutput): int32 =
  ensureInitialized(runtime)
  let actionTag = decodeActionTag(payload, payloadLen)
  let fields = decodeRequestFields(payload, payloadLen)
  if actionTag == tagStartCapture:
    runtime.loadPersistence(allowClearOnRestart = true)
  elif actionTag != tagPoll and actionTag != tagRestoreWindow and actionTag != tagPersistWindow:
    runtime.loadPersistence(allowClearOnRestart = false)
    runtime.store.syncFromFields(fields)

  var selectedParam = runtime.store.selectedItemId
  var stringParam = ""
  for field in fields:
    if field.fieldId == fldSelectedItemId and field.valueType == bridgeTypeInt64:
      selectedParam = decodeInt64Bytes(field.payload, selectedParam.int64).int
    if field.fieldId == fldActionItemId and field.valueType == bridgeTypeInt64:
      selectedParam = decodeInt64Bytes(field.payload, selectedParam.int64).int
    if field.fieldId == fldTagDraft and field.valueType == bridgeTypeString:
      stringParam = toText(field.payload)

  case actionTag
  of tagPoll:
    discard
  of tagStartCapture:
    runtime.store.statusText = "Monitoring clipboard"
  of tagCaptureClipboard:
    let text = runtime.store.incomingClipboardText
    let path = runtime.store.incomingClipboardPath
    let source = runtime.store.incomingClipboardSource
    let kind = runtime.store.incomingClipboardKind
    if text.len > 0 or path.len > 0:
      discard runtime.store.addClipItem(text, source, path, kind)
      runtime.store.incomingClipboardKind = ""
      runtime.store.incomingClipboardText = ""
      runtime.store.incomingClipboardPath = ""
      runtime.store.incomingClipboardSource = ""
    else:
      runtime.store.statusText = "Clipboard unchanged"
  of tagSelectItem:
    runtime.store.selectItem(selectedParam)
  of tagSearchChanged:
    runtime.store.statusText =
      if runtime.store.searchQuery.strip().len == 0: "Monitoring clipboard"
      else: "Searching history"
  of tagClearSearch:
    runtime.store.searchQuery = ""
  of tagSetFilterAll:
    runtime.store.activeFormatFilter = "All"
  of tagSetFilterText:
    runtime.store.activeFormatFilter = "Text"
  of tagSetFilterImages:
    runtime.store.activeFormatFilter = "Image"
  of tagSetFilterFiles:
    runtime.store.activeFormatFilter = "File"
  of tagSetFilterLinks:
    runtime.store.activeFormatFilter = "Link"
  of tagSetFilterColors:
    runtime.store.activeFormatFilter = "Color"
  of tagSetFilterEmails:
    runtime.store.activeFormatFilter = "Email"
  of tagSetFilterFavorites:
    runtime.store.activeFormatFilter = "Favorites"
  of tagSetFilterRichText:
    runtime.store.activeFormatFilter = "Rich Text"
  of tagToggleFavorite:
    runtime.store.toggleFavorite(selectedParam)
  of tagAddTag:
    runtime.store.addTag(runtime.store.selectedItemId, stringParam)
  of tagRemoveTag:
    runtime.store.removeTag(runtime.store.selectedItemId, stringParam)
  of tagSelectTag:
    runtime.store.selectedTagFilter = stringParam
  of tagClearTagFilter:
    runtime.store.selectedTagFilter = ""
  of tagCopyItem:
    discard runtime.store.recordCopiedItem(selectedParam)
  of tagCopyItemAs:
    discard runtime.store.recordCopiedItem(selectedParam, asPlainText = true)
  of tagPasteItem:
    runtime.store.statusText = "Restored clipboard; paste requires Accessibility permission"
  of tagShareItem:
    runtime.store.selectItem(selectedParam)
    runtime.store.statusText = "Share requested"
  of tagPinItem:
    runtime.store.pinItem(selectedParam)
  of tagPasteSelectedRange:
    runtime.store.statusText = "Prepared multi-paste"
  of tagMergeTextItems:
    discard runtime.store.mergeTextItems()
  of tagEditItem:
    runtime.store.selectItem(selectedParam)
  of tagSaveEdit:
    var title = ""
    var text = ""
    for field in fields:
      if field.fieldId == fldEditTitle and field.valueType == bridgeTypeString:
        title = toText(field.payload)
      if field.fieldId == fldEditText and field.valueType == bridgeTypeString:
        text = toText(field.payload)
    runtime.store.editSelected(title, text)
  of tagDeleteItem:
    runtime.store.deleteItem(selectedParam)
  of tagClearHistory:
    runtime.store.clearHistory()
  of tagCopyOcrText:
    runtime.store.statusText = "Copied OCR text"
  of tagRunOcr:
    let idx = runtime.store.selectedIndex()
    if idx >= 0:
      runtime.store.items[idx].ocrText = "OCR text placeholder from local Vision request"
      runtime.store.statusText = "OCR complete"
  of tagSaveImage:
    runtime.store.statusText = "Image save requested"
  of tagShowFileInFinder:
    runtime.store.statusText = "Finder reveal requested"
  of tagOpenUrl:
    runtime.store.statusText = "Open link requested"
  of tagTogglePause:
    runtime.store.pausedCapture = not runtime.store.pausedCapture
  of tagSaveSettings:
    runtime.store.saveSettings()
    runtime.store.statusText = "Settings saved"
  of tagSettingsChanged:
    runtime.store.saveSettings()
    runtime.store.statusText = "Settings applied"
  of tagSetAppearanceSystem:
    runtime.store.settings.appearanceMode = "System"
  of tagSetAppearanceLight:
    runtime.store.settings.appearanceMode = "Light"
  of tagSetAppearanceDark:
    runtime.store.settings.appearanceMode = "Dark"
  of tagAppShutdown:
    if runtime.store.settings.clearOnQuit:
      runtime.store.items.setLen(0)
    runtime.store.saveSettings()
    runtime.store.saveHistory()
  else:
    discard

  runtime.store.enforceRetention()
  if shouldSaveHistory(actionTag):
    runtime.store.saveHistory()

  if outp != nil:
    outp[].statePatch = writeBlob(runtime.store.buildPatch(actionTag))
    outp[].effects = writeBlob(@[])
    outp[].emittedActions = writeBlob(@[])
    outp[].diagnostics = writeBlob(toBytes("nim.clipbook action=" & actionName(actionTag) & " items=" & $runtime.store.items.len))
  0'i32

proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32,
                    outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.} =
  try:
    dispatch(gRuntime, payload, payloadLen, outp)
  except CatchableError as e:
    if outp != nil:
      outp[].statePatch = writeBlob(@[])
      outp[].effects = writeBlob(@[])
      outp[].emittedActions = writeBlob(@[])
      outp[].diagnostics = writeBlob(toBytes("Error: " & e.msg))
    -1'i32

proc dispatchTest*(runtime: var BridgeRuntime, payload: openArray[byte]): BridgeDispatchTestResult =
  var outBuf = GUIBridgeDispatchOutput()
  let payloadPtr = if payload.len == 0: nil else: cast[ptr uint8](unsafeAddr payload[0])
  result.status = dispatch(runtime, payloadPtr, payload.len.uint32, addr outBuf)
  result.statePatch = copyBlob(outBuf.statePatch)
  result.effects = copyBlob(outBuf.effects)
  result.emittedActions = copyBlob(outBuf.emittedActions)
  let diagBytes = copyBlob(outBuf.diagnostics)
  result.diagnostics = toText(diagBytes)
  freeBlob(outBuf.statePatch)
  freeBlob(outBuf.effects)
  freeBlob(outBuf.emittedActions)
  freeBlob(outBuf.diagnostics)

proc bridgeGetNotifyFd(): int32 {.cdecl.} = -1
proc bridgeWaitShutdown(timeoutMs: int32): int32 {.cdecl.} =
  discard timeoutMs
  0

var gBridgeTable = GUIBridgeFunctionTable(
  abiVersion: guiBridgeAbiVersion,
  alloc: bridgeAlloc,
  free: bridgeFree,
  dispatch: bridgeDispatch,
  getNotifyFd: bridgeGetNotifyFd,
  waitShutdown: bridgeWaitShutdown
)

proc gui_bridge_get_table(): ptr GUIBridgeFunctionTable {.cdecl, exportc, dynlib.} =
  addr gBridgeTable
