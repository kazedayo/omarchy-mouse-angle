// Check: node test_model.js  (pure logic only, no shell or Hyprland)
var fs = require("fs"), vm = require("vm"), assert = require("assert")

var ctx = {}
vm.createContext(ctx)
vm.runInContext(fs.readFileSync(__dirname + "/Model.js", "utf8"), ctx)

// hwid normalization: pad, lowercase, serial passthrough, reject junk
assert.strictEqual(ctx.normalizeHwid("3:361d:100:AB12"), "0003:361d:0100:ab12")
assert.strictEqual(ctx.normalizeHwid("0003:361d:0100"), "0003:361d:0100")
assert.strictEqual(ctx.normalizeHwid(""), null)
assert.strictEqual(ctx.normalizeHwid("0003:361d"), null)
assert.strictEqual(ctx.normalizeHwid("zzzz:361d:0100"), null)
assert.strictEqual(ctx.normalizeHwid("0003:361d:0100:bad serial!"), null)
assert.strictEqual(ctx.isSafeHwid("0003:361d:0100:ab12"), true)
assert.strictEqual(ctx.isSafeHwid("0003:361d:0100"), true)
assert.strictEqual(ctx.isSafeHwid("0003:361d"), false)
assert.strictEqual(ctx.isSafeHwid('0003:361d:0100"\nhl.device'), false)

// round-trip: 400 -> 40, -7 -> 353, hwid rides along as a comment
var text = ctx.formatAngleFile([
  { name: "finalmouse-ultralightx-dongle-mouse", hwid: "0003:361d:0100:6e6785b5d42579a6", rotation: -7 },
  { name: "x-mouse", rotation: 400 }
])
assert.deepStrictEqual(
  JSON.parse(JSON.stringify(ctx.parseAngleFile(text))),
  [
    { name: "finalmouse-ultralightx-dongle-mouse", hwid: "0003:361d:0100:6e6785b5d42579a6", rotation: 353 },
    { name: "x-mouse", hwid: null, rotation: 40 }
  ]
)
// the generated file is what Hyprland reads back
assert.ok(text.indexOf('hl.device({ name = "x-mouse", rotation = 40 })') !== -1)
assert.ok(text.indexOf('-- hwid 0003:361d:0100:6e6785b5d42579a6') !== -1)
// malformed hwid in the file degrades to name-keyed, not a crash
assert.deepStrictEqual(
  JSON.parse(JSON.stringify(ctx.parseAngleFile('hl.device({ name = "x-mouse", rotation = 5 }) -- hwid junk'))),
  [{ name: "x-mouse", hwid: null, rotation: 5 }]
)

// unsigned storage, signed display
assert.strictEqual(ctx.label(353), "-7\u00b0")
assert.strictEqual(ctx.describe(353), "7\u00b0 anticlockwise")
assert.strictEqual(ctx.describe(7), "7\u00b0 clockwise")
assert.strictEqual(ctx.label(0), "0\u00b0")

// identity: hwid beats name, name is the fallback key
assert.strictEqual(ctx.keyOf({ hwid: "0003:361d:0100", name: "a-mouse" }), "0003:361d:0100")
assert.strictEqual(ctx.keyOf({ name: "a-mouse" }), "a-mouse")

// upsert replaces by identity, keeps other mice, no duplicates
var list = ctx.upsert(ctx.upsert([], { name: "a-mouse", rotation: 5 }), { name: "a-mouse", rotation: 6 })
assert.strictEqual(JSON.stringify(list), JSON.stringify([{ name: "a-mouse", rotation: 6 }]))
assert.strictEqual(ctx.find(list, "a-mouse").rotation, 6)
// a name-keyed entry and its hwid-keyed form are distinct identities until
// syncEntries migrates the old one
var withHwid = ctx.upsert(list, { name: "a-mouse", hwid: "0003:1111:2222", rotation: 6 })
assert.strictEqual(withHwid.length, 2)
assert.strictEqual(ctx.find(withHwid, "0003:1111:2222").rotation, 6)
assert.deepStrictEqual(ctx.upsert(withHwid, { name: "b-mouse", rotation: 1 }).length, 3)

// device names are validated before landing in generated Lua
assert.strictEqual(ctx.isSafeName('evil", rotation = 1 })\nhl.device({ name = "x'), false)

// hyprctl junk nodes are filtered out
var mice = ctx.parseMice(JSON.stringify({ mice: [
  { name: "finalmouse-ultralightx-dongle-mouse" },
  { name: "wooting-wooting-60he-(arm)-mouse" },
  { name: "wooting-wooting-60he-(arm)-consumer-control-1" },
  { name: "endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse-keyboard-1" }
] }))
assert.strictEqual(JSON.stringify(mice), JSON.stringify(["finalmouse-ultralightx-dongle-mouse", "wooting-wooting-60he-(arm)-mouse"]))

// keyboard-node detection from sysfs key masks (words print highest first)
assert.strictEqual(ctx.isKeyboardNode("1f0000 0 0 0 0"), false)
assert.strictEqual(ctx.isKeyboardNode("1000000000007 ff980000000007ff febeffdfffefffff fffffffffffffffe"), true)
assert.strictEqual(ctx.isKeyboardNode(""), false)
assert.strictEqual(ctx.normalizeName("Wooting Wooting 60HE (ARM) Mouse"), "wooting-wooting-60he-(arm)-mouse")

// the real dump: keyboards' embedded mouse nodes are hidden, standalone mice
// keep their evdev hardware id; composite EGG matches its node by suffix
var dump = JSON.stringify({ mice: [
  { name: "endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse" },
  { name: "endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse-keyboard-1" },
  { name: "wooting-wooting-60he-(arm)-consumer-control-1" },
  { name: "wooting-wooting-60he-(arm)-mouse" },
  { name: "finalmouse-ultralightx-dongle-mouse" },
  { name: "finalmouse-ultralightx-dongle-mouse-1" }
] }) + "\n" + ctx.NODES_MARKER + "\n" +
  "Wooting Wooting 60HE (ARM)\t1000000000007 ff980000000007ff febeffdfffefffff fffffffffffffffe\t0003:341d:0101\n" +
  "Wooting Wooting 60HE (ARM) System Control\tc000 10000000000000 0\t0003:341d:0101\n" +
  "Wooting Wooting 60HE (ARM) Consumer Control\t733fff 0 0 483ffff17aff32d\t0003:341d:0101\n" +
  "Wooting Wooting 60HE (ARM) Mouse\t1f0000 0 0 0 0\t0003:341d:0101\n" +
  "Endgame Gear Endgame Gear OP1 8k v2 Gaming Mouse\t1f0000 0 0 0 0\t0003:33fa:0901:4d4b\n" +
  "Endgame Gear Endgame Gear OP1 8k v2 Gaming Mouse Keyboard\t733eff 0 0 483ffff17aff32d e09effdf01cfffff fffffffffffffffe\t0003:33fa:0901:4d4b\n" +
  "Finalmouse UltralightX dongle Mouse\t1f0000 0 0 0 0\t0003:361d:0100:6e6785b5d42579a6\n"
assert.strictEqual(
  JSON.stringify(ctx.parseDeviceDump(dump)),
  JSON.stringify([
    { name: "endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse", hwid: "0003:33fa:0901:4d4b" },
    { name: "finalmouse-ultralightx-dongle-mouse", hwid: "0003:361d:0100:6e6785b5d42579a6" },
    { name: "finalmouse-ultralightx-dongle-mouse-1", hwid: "0003:361d:0100:6e6785b5d42579a6" }
  ])
)
// a marker-less dump (sysfs unreadable) falls back to name filtering only
assert.strictEqual(
  JSON.stringify(ctx.parseDeviceDump('{"mice":[{"name":"wooting-wooting-60he-(arm)-mouse"}]}')),
  JSON.stringify([{ name: "wooting-wooting-60he-(arm)-mouse", hwid: null }])
)

assert.strictEqual(ctx.prettyName("wooting-wooting-60he-(arm)-mouse"), "Wooting 60he (arm)")
assert.strictEqual(ctx.prettyName("endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse"), "Endgame Gear Op1 8k v2 Gaming")
assert.strictEqual(ctx.prettyName("finalmouse-ultralightx-dongle-mouse"), "Finalmouse Ultralightx Dongle")

console.log("ok")
