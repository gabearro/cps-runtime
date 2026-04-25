## Tests for BEP 10: Extension Protocol.

import cps/bittorrent/extensions
import cps/bittorrent/bencode

block: # extension registry basic operations
  var reg = newExtensionRegistry()
  let id1 = reg.registerExtension("ut_metadata")
  let id2 = reg.registerExtension("ut_pex")

  assert id1 == 1, "first extension gets ID 1"
  assert id2 == 2, "second extension gets ID 2"
  assert reg.localId("ut_metadata") == 1
  assert reg.localId("ut_pex") == 2
  assert reg.localId("nonexistent") == 0, "unknown extension returns 0"

  # Re-registering returns same ID
  let id1b = reg.registerExtension("ut_metadata")
  assert id1b == 1, "re-registering returns same ID"
  echo "PASS: extension registry basic operations"

block: # extension handshake encoding
  var reg = newExtensionRegistry()
  discard reg.registerExtension("ut_metadata")
  discard reg.registerExtension("ut_pex")

  let payload = encodeExtHandshake(reg, 12345, 6881, 250, "TestClient/1.0")
  let decoded = decode(payload)
  assert decoded.kind == bkDict

  let m = decoded.getOrDefault("m")
  assert m != nil
  assert m.kind == bkDict
  let metaId = m.getOrDefault("ut_metadata")
  assert metaId != nil and metaId.kind == bkInt and metaId.intVal == 1
  let pexId = m.getOrDefault("ut_pex")
  assert pexId != nil and pexId.kind == bkInt and pexId.intVal == 2

  let ms = decoded.getOrDefault("metadata_size")
  assert ms != nil and ms.kind == bkInt and ms.intVal == 12345

  let p = decoded.getOrDefault("p")
  assert p != nil and p.kind == bkInt and p.intVal == 6881

  let v = decoded.getOrDefault("v")
  assert v != nil and v.kind == bkStr and v.strVal == "TestClient/1.0"
  echo "PASS: extension handshake encoding"

block: # extension handshake decoding
  var reg = newExtensionRegistry()
  discard reg.registerExtension("ut_metadata")

  # Simulate remote handshake
  let payload = "d1:md11:ut_metadatai3e6:ut_pexi4ee13:metadata_sizei98765e1:v13:RemoteClient/e"
  reg.decodeExtHandshake(payload)

  assert reg.remoteId("ut_metadata") == 3, "remote ut_metadata ID"
  assert reg.remoteId("ut_pex") == 4, "remote ut_pex ID"
  assert reg.supportsExtension("ut_metadata"), "remote supports ut_metadata"
  assert reg.supportsExtension("ut_pex"), "remote supports ut_pex"
  assert not reg.supportsExtension("unknown"), "remote doesn't support unknown"
  assert reg.metadataSize == 98765
  assert reg.clientName == "RemoteClient/"
  echo "PASS: extension handshake decoding"

block: # extension handshake decoding - listen port + upload_only
  var reg = newExtensionRegistry()
  let payload = "d1:md11:ut_metadatai3ee1:pi51413e11:upload_onlyi1ee"
  reg.decodeExtHandshake(payload)
  assert reg.remoteListenPort == 51413
  assert reg.uploadOnly
  echo "PASS: ext handshake p/upload_only decoding"

block: # lookup local name
  var reg = newExtensionRegistry()
  discard reg.registerExtension("ut_metadata")
  discard reg.registerExtension("ut_pex")

  assert reg.lookupLocalName(1) == "ut_metadata"
  assert reg.lookupLocalName(2) == "ut_pex"
  assert reg.lookupLocalName(99) == ""
  echo "PASS: lookup local name"

block: # round-trip extension handshake
  var sender = newExtensionRegistry()
  discard sender.registerExtension("ut_metadata")
  discard sender.registerExtension("ut_pex")

  let payload = encodeExtHandshake(sender, 5000, 6881, 100, "Sender/1.0")

  var receiver = newExtensionRegistry()
  discard receiver.registerExtension("ut_metadata")
  receiver.decodeExtHandshake(payload)

  assert receiver.remoteId("ut_metadata") == 1, "sender's ut_metadata ID"
  assert receiver.remoteId("ut_pex") == 2, "sender's ut_pex ID"
  assert receiver.metadataSize == 5000
  assert receiver.clientName == "Sender/1.0"
  assert receiver.reqq == 100
  echo "PASS: round-trip extension handshake"

block: # extension disabled (ID 0)
  var reg = newExtensionRegistry()
  let payload = "d1:md11:ut_metadatai0eee"
  reg.decodeExtHandshake(payload)

  assert reg.remoteId("ut_metadata") == 0, "disabled extension has ID 0"
  assert not reg.supportsExtension("ut_metadata"), "disabled extension not supported"
  echo "PASS: extension disabled (ID 0)"

echo "ALL EXTENSION PROTOCOL TESTS PASSED"
