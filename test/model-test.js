#!/usr/bin/env node
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const root = path.resolve(__dirname, "..")
const source = fs.readFileSync(path.join(root, "Model.js"), "utf8")
const model = {}
vm.createContext(model)
vm.runInContext(source + "\nthis.exports = this", model)
const M = model

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(message + "\n  expected: " + JSON.stringify(expected) + "\n  actual:   " + JSON.stringify(actual))
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

const now = new Date("2026-08-25T21:00:00Z")
const raw = [
  JSON.stringify({ id: "aaa", ts: "2026-08-25T10:00:00Z", text: "hello world", pinned: false }),
  JSON.stringify({ id: "bbb", ts: "2026-08-24T10:00:00Z", text: "older note", pinned: true }),
  JSON.stringify({ id: "ccc", ts: "2026-08-25T20:00:00Z", text: "latest dictation", pinned: false }),
  "not json",
  JSON.stringify({ id: "skip", ts: "2026-08-25T20:00:00Z", text: "   " })
].join("\n")

const entries = M.parseHistory(raw)
assertEqual(entries.length, 3, "skips invalid and empty lines")
assertEqual(M.todayCount(entries, now), 2, "counts local-day entries")

const sorted = M.sortedEntries(entries)
assertEqual(sorted[0].id, "bbb", "pinned entries sort first")
assertEqual(sorted[1].id, "ccc", "newest unpinned follows")

const filtered = M.filterEntries(entries, "DICTATION")
assertEqual(filtered.length, 1, "filter is case-insensitive")
assertEqual(filtered[0].id, "ccc", "filter keeps the matching row")

assertEqual(M.previewText("  many\n  spaces  here  ", 8), "many sp…", "preview collapses whitespace")
assertEqual(M.relativeTime("2026-08-25T21:00:00Z", now), "just now", "relative time for fresh entries")
assertEqual(M.barTooltip(false, false, "idle", 0, 0), "Dictation (Voxtype) History — capture is off", "tooltip when unwired")
assertEqual(M.barTooltip(true, false, "recording", 4, 2), "Recording…", "tooltip while recording")

const wired = M.configLooksWired(`
[output]
mode = "type"

[output.post_process]
command = "/tmp/voxtype-history log"
timeout_ms = 5000
`)
assert(wired, "detects an uncommented hook command")

const commented = M.configLooksWired(`
[output.post_process]
# command = "/tmp/voxtype-history log"
`)
assert(!commented, "ignores a commented hook command")

console.log("ok")
