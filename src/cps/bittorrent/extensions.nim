## BEP 10: Extension Protocol.
##
## Provides a framework for extending the BitTorrent protocol.
## Each extension registers a name and gets a local message ID.
## Extension handshake messages exchange supported extensions and metadata.

import std/tables
import bencode

const
  ExtHandshakeId* = 0'u8  ## Extension handshake message ID

type
  ExtensionId* = uint8

  ExtensionRegistry* = object
    ## Tracks local and remote extension ID mappings.
    localIds: Table[string, ExtensionId]    ## name -> our local ID
    remoteIds: Table[string, ExtensionId]   ## name -> their remote ID
    nextId: ExtensionId
    reverseLocalIds: Table[ExtensionId, string]  ## local ID -> name (reverse mapping)
    reverseRemoteIds: Table[ExtensionId, string] ## remote ID -> name (reverse mapping)
    clientName*: string
    metadataSize*: int  ## From remote handshake (BEP 9)
    yourip*: string     ## Our external IP (from remote)
    remoteListenPort*: uint16  ## Remote peer's listening port from "p" (BEP 10)
    reqq*: int          ## Request queue size (from remote)
    uploadOnly*: bool   ## BEP 21: remote is a partial seed (upload only)

proc newExtensionRegistry*(): ExtensionRegistry =
  ExtensionRegistry(
    localIds: initTable[string, ExtensionId](),
    remoteIds: initTable[string, ExtensionId](),
    reverseLocalIds: initTable[ExtensionId, string](),
    reverseRemoteIds: initTable[ExtensionId, string](),
    nextId: 1,  # 0 is reserved for handshake
    reqq: 250   # default
  )

proc registerExtension*(reg: var ExtensionRegistry, name: string): ExtensionId =
  ## Register a local extension. Returns the local ID assigned.
  if name in reg.localIds:
    return reg.localIds[name]
  let id = reg.nextId
  reg.localIds[name] = id
  reg.reverseLocalIds[id] = name
  reg.nextId += 1
  return id

proc localId*(reg: ExtensionRegistry, name: string): ExtensionId =
  ## Get the local ID for an extension, or 0 if not registered.
  reg.localIds.getOrDefault(name, 0)

proc remoteId*(reg: ExtensionRegistry, name: string): ExtensionId =
  ## Get the remote peer's ID for an extension, or 0 if not supported.
  reg.remoteIds.getOrDefault(name, 0)

proc supportsExtension*(reg: ExtensionRegistry, name: string): bool =
  ## Check if the remote peer supports a given extension.
  name in reg.remoteIds and reg.remoteIds[name] != 0

proc lookupLocalName*(reg: ExtensionRegistry, id: ExtensionId): string =
  ## Look up the extension name for a local ID. Returns "" if not found.
  reg.reverseLocalIds.getOrDefault(id, "")

proc lookupRemoteName*(reg: ExtensionRegistry, id: ExtensionId): string =
  ## Look up the extension name for a remote ID. Returns "" if not found.
  reg.reverseRemoteIds.getOrDefault(id, "")

iterator localExtensions*(reg: ExtensionRegistry): tuple[name: string, id: ExtensionId] =
  ## Iterate over locally registered extensions.
  for name, id in reg.localIds:
    yield (name, id)

proc encodeExtHandshake*(reg: ExtensionRegistry,
                         metadataSize: int = 0,
                         listenPort: uint16 = 0,
                         reqq: int = 250,
                         clientName: string = "",
                         uploadOnly: bool = false): string =
  ## Encode an extension handshake message (BEP 10).
  ## This is the payload for extended message ID 0.
  var d = initTable[string, BencodeValue]()

  # "m" dictionary maps extension names to our local IDs
  var m = initTable[string, BencodeValue]()
  for name, id in reg.localIds:
    m[name] = bInt(id.int64)
  d["m"] = bDict(m)

  if listenPort > 0:
    d["p"] = bInt(listenPort.int64)
  if metadataSize > 0:
    d["metadata_size"] = bInt(metadataSize.int64)
  if reqq > 0:
    d["reqq"] = bInt(reqq.int64)
  if clientName.len > 0:
    d["v"] = bStr(clientName)
  if uploadOnly:
    d["upload_only"] = bInt(1)  # BEP 21

  return encode(bDict(d))

proc decodeExtHandshake*(reg: var ExtensionRegistry, payload: string) =
  ## Decode and process a remote extension handshake.
  let root = decode(payload)
  if root.kind != bkDict:
    return

  # Parse "m" dictionary - remote extension name -> their ID
  let mNode = root.getOrDefault("m")
  if mNode != nil and mNode.kind == bkDict:
    reg.remoteIds.clear()
    reg.reverseRemoteIds.clear()
    for key in mNode.dictKeys:
      let val = mNode.getOrDefault(key)
      if val != nil and val.kind == bkInt:
        let id = val.intVal.uint8
        reg.remoteIds[key] = id
        reg.reverseRemoteIds[id] = key

  # Parse metadata_size (BEP 9)
  let msNode = root.getOrDefault("metadata_size")
  if msNode != nil and msNode.kind == bkInt:
    reg.metadataSize = msNode.intVal.int

  # Parse listen port (BEP 10 "p")
  let pNode = root.getOrDefault("p")
  if pNode != nil and pNode.kind == bkInt and pNode.intVal > 0 and pNode.intVal <= 65535:
    reg.remoteListenPort = pNode.intVal.uint16

  # Parse client name
  let vNode = root.getOrDefault("v")
  if vNode != nil and vNode.kind == bkStr:
    reg.clientName = vNode.strVal

  # Parse yourip
  let ipNode = root.getOrDefault("yourip")
  if ipNode != nil and ipNode.kind == bkStr:
    reg.yourip = ipNode.strVal

  # Parse reqq
  let rqNode = root.getOrDefault("reqq")
  if rqNode != nil and rqNode.kind == bkInt:
    reg.reqq = rqNode.intVal.int

  # Parse upload_only (BEP 21)
  let uoNode = root.getOrDefault("upload_only")
  if uoNode != nil and uoNode.kind == bkInt:
    reg.uploadOnly = uoNode.intVal != 0
