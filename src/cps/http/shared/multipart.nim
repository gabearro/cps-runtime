## Multipart Form Data Parser
##
## Parses multipart/form-data bodies as used in file uploads.

import std/[tables, strutils]

type
  UploadedFile* = object
    fieldName*: string
    filename*: string
    contentType*: string
    data*: string
    size*: int

  MultipartData* = object
    fields*: Table[string, string]
    files*: Table[string, seq[UploadedFile]]

proc extractBoundary*(contentType: string): string =
  ## Extract the boundary string from a Content-Type header.
  ## "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"
  for part in contentType.split(';'):
    let trimmed = part.strip()
    if trimmed.toLowerAscii.startsWith("boundary="):
      return trimmed[9 .. ^1].strip(chars = {'"'})
  return ""

proc parseContentDisposition(header: string): (string, string) =
  ## Parse Content-Disposition header.
  ## Returns (fieldName, filename). filename may be "".
  var name = ""
  var filename = ""
  for part in header.split(';'):
    let trimmed = part.strip()
    if trimmed.toLowerAscii.startsWith("name="):
      name = trimmed[5 .. ^1].strip(chars = {'"'})
    elif trimmed.toLowerAscii.startsWith("filename="):
      filename = trimmed[9 .. ^1].strip(chars = {'"'})
  return (name, filename)

proc parsePartHeaders(headerSection: string): (string, string, string) =
  ## Parse headers from a multipart part.
  ## Returns (fieldName, filename, contentType).
  var fieldName = ""
  var filename = ""
  var contentType = "application/octet-stream"
  for line in headerSection.split("\r\n"):
    let colonIdx = line.find(':')
    if colonIdx > 0:
      let key = line[0 ..< colonIdx].strip().toLowerAscii
      let val = line[colonIdx + 1 .. ^1].strip()
      case key
      of "content-disposition":
        (fieldName, filename) = parseContentDisposition(val)
      of "content-type":
        contentType = val
  return (fieldName, filename, contentType)

proc parseMultipart*(body: string, contentType: string): MultipartData =
  ## Parse a multipart/form-data body.
  ## contentType should be the full Content-Type header value.
  result = MultipartData(
    fields: initTable[string, string](),
    files: initTable[string, seq[UploadedFile]]()
  )

  let boundary = extractBoundary(contentType)
  if boundary.len == 0:
    return

  let delimiter = "--" & boundary
  let endDelimiter = delimiter & "--"

  # Split body on boundary
  var parts: seq[string]
  var pos = body.find(delimiter)
  if pos < 0:
    return

  pos += delimiter.len
  # Skip past \r\n after first boundary
  if pos < body.len and body[pos] == '\r':
    inc pos
  if pos < body.len and body[pos] == '\n':
    inc pos

  while pos < body.len:
    let nextBoundary = body.find(delimiter, pos)
    if nextBoundary < 0:
      break

    # Part content is between pos and nextBoundary (minus trailing \r\n)
    var partEnd = nextBoundary
    if partEnd >= 2 and body[partEnd - 2] == '\r' and body[partEnd - 1] == '\n':
      partEnd -= 2

    let partContent = body[pos ..< partEnd]
    parts.add partContent

    # Move past boundary
    pos = nextBoundary + delimiter.len
    # Check for end delimiter
    if pos + 2 <= body.len and body[pos ..< pos + 2] == "--":
      break
    # Skip \r\n
    if pos < body.len and body[pos] == '\r':
      inc pos
    if pos < body.len and body[pos] == '\n':
      inc pos

  # Process each part
  for part in parts:
    # Split headers from body at \r\n\r\n
    let headerEnd = part.find("\r\n\r\n")
    if headerEnd < 0:
      continue

    let headerSection = part[0 ..< headerEnd]
    let partBody = part[headerEnd + 4 .. ^1]

    let (fieldName, filename, contentType) = parsePartHeaders(headerSection)

    if fieldName.len == 0:
      continue

    if filename.len > 0:
      # File upload
      let file = UploadedFile(
        fieldName: fieldName,
        filename: filename,
        contentType: contentType,
        data: partBody,
        size: partBody.len
      )
      if fieldName notin result.files:
        result.files[fieldName] = @[]
      result.files[fieldName].add file
    else:
      # Regular form field
      result.fields[fieldName] = partBody

proc getUploadedFile*(body: string, contentType: string, fieldName: string): UploadedFile =
  ## Get the first uploaded file from a multipart form field.
  let mp = parseMultipart(body, contentType)
  if fieldName in mp.files and mp.files[fieldName].len > 0:
    return mp.files[fieldName][0]
  return UploadedFile()

proc getUploadedFiles*(body: string, contentType: string, fieldName: string): seq[UploadedFile] =
  ## Get all uploaded files from a multipart form field.
  let mp = parseMultipart(body, contentType)
  if fieldName in mp.files:
    return mp.files[fieldName]
  return @[]

proc getMultipartField*(body: string, contentType: string, fieldName: string): string =
  ## Get a text field value from a multipart form.
  let mp = parseMultipart(body, contentType)
  return mp.fields.getOrDefault(fieldName)
