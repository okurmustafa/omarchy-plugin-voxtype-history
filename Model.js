function normalizeEntry(value) {
  if (!value || typeof value !== "object") return null
  var text = String(value.text || "")
  if (text.trim().length === 0) return null
  var id = String(value.id || "")
  if (!id) return null
  return {
    id: id,
    ts: String(value.ts || ""),
    text: text,
    pinned: value.pinned === true
  }
}

function parseHistory(raw) {
  var lines = String(raw || "").split("\n")
  var next = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var entry = normalizeEntry(JSON.parse(line))
      if (entry) next.push(entry)
    } catch (e) {
    }
  }
  return next
}

function parseMeta(raw) {
  try {
    var parsed = JSON.parse(String(raw || "{}"))
    if (!parsed || typeof parsed !== "object") parsed = {}
    return {
      paused: parsed.paused === true,
      maxEntries: Math.max(1, parseInt(parsed.maxEntries, 10) || 500)
    }
  } catch (e) {
    return { paused: false, maxEntries: 500 }
  }
}

function configLooksWired(raw) {
  var text = String(raw || "")
  var section = text.match(/^\[output\.post_process\][\s\S]*?(?=^\[|\Z)/m)
  var body = section ? section[0] : text
  var lines = body.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/^\s*#/.test(line)) continue
    if (/^\s*command\s*=/.test(line) && line.indexOf("voxtype-history") >= 0)
      return true
  }
  return false
}

function compareEntries(a, b) {
  if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
  if (a.ts === b.ts) return a.id < b.id ? 1 : (a.id > b.id ? -1 : 0)
  return a.ts < b.ts ? 1 : -1
}

function sortedEntries(entries) {
  var next = (entries || []).slice()
  next.sort(compareEntries)
  return next
}

function filterEntries(entries, query) {
  var needle = String(query || "").trim().toLowerCase()
  var source = sortedEntries(entries)
  if (!needle) return source
  var next = []
  for (var i = 0; i < source.length; i++) {
    var entry = source[i]
    if (String(entry.text).toLowerCase().indexOf(needle) >= 0) next.push(entry)
  }
  return next
}

function asDate(value) {
  if (value === undefined || value === null || value === "") return new Date()
  var date = new Date(value)
  return isNaN(date.getTime()) ? new Date() : date
}

function isSameLocalDay(iso, now) {
  if (!iso) return false
  var date = new Date(iso)
  if (isNaN(date.getTime())) return false
  var current = asDate(now)
  return date.getFullYear() === current.getFullYear()
    && date.getMonth() === current.getMonth()
    && date.getDate() === current.getDate()
}

function todayCount(entries, now) {
  var count = 0
  var values = entries || []
  for (var i = 0; i < values.length; i++) {
    if (isSameLocalDay(values[i].ts, now)) count += 1
  }
  return count
}

function relativeTime(iso, now) {
  var date = new Date(iso)
  if (isNaN(date.getTime())) return ""
  var current = asDate(now)
  var delta = Math.max(0, Math.floor((current.getTime() - date.getTime()) / 1000))
  if (delta < 10) return "just now"
  if (delta < 60) return delta + "s ago"
  var minutes = Math.floor(delta / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days === 1) return "yesterday"
  if (days < 7) return days + "d ago"
  if (typeof Qt !== "undefined" && Qt.formatDate) return Qt.formatDate(date, "MMM d")
  return iso.slice(0, 10)
}

function previewText(text, maxLength) {
  var compact = String(text || "").replace(/\s+/g, " ").trim()
  var limit = maxLength === undefined || maxLength === null ? 140 : Number(maxLength)
  if (!isFinite(limit) || limit < 8) limit = 140
  if (compact.length <= limit) return compact
  return compact.slice(0, limit - 1) + "…"
}

function barTooltip(wired, paused, recordingState, count, today) {
  if (recordingState === "recording") return "Recording…"
  if (recordingState === "transcribing") return "Transcribing…"
  if (!wired) return "Dictation history — capture is off"
  if (paused) return "Dictation history — paused"
  if (today > 0) return "Dictation history — " + today + " today"
  if (count > 0) return "Dictation history — " + count + " saved"
  return "Dictation history"
}
