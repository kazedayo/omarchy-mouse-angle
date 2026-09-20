// Check: node test_model.js  (pure logic only, no shell or Hyprland)
var fs = require("fs"), vm = require("vm"), assert = require("assert")

var ctx = {}
vm.createContext(ctx)
vm.runInContext(fs.readFileSync(__dirname + "/Model.js", "utf8"), ctx)

// round-trip: 400 -> 40, -7 -> 353
var text = ctx.formatAngleFile([{ name: "finalmouse-ultralightx-dongle-mouse", rotation: -7 }, { name: "x-mouse", rotation: 400 }])
assert.deepStrictEqual(
  JSON.parse(JSON.stringify(ctx.parseAngleFile(text))),
  [
    { name: "finalmouse-ultralightx-dongle-mouse", rotation: 353 },
    { name: "x-mouse", rotation: 40 }
  ]
)

// the generated file is what Hyprland reads back
assert.ok(text.indexOf('hl.device({ name = "x-mouse", rotation = 40 })') !== -1)

// unsigned storage, signed display
assert.strictEqual(ctx.label(353), "-7\u00b0")
assert.strictEqual(ctx.describe(353), "7\u00b0 anticlockwise")
assert.strictEqual(ctx.describe(7), "7\u00b0 clockwise")
assert.strictEqual(ctx.label(0), "0\u00b0")

// upsert keeps unplugged mice, no duplicates
var list = ctx.upsert(ctx.upsert([], "a-mouse", 5), "a-mouse", 6)
assert.strictEqual(JSON.stringify(list), JSON.stringify([{ name: "a-mouse", rotation: 6 }]))
assert.deepStrictEqual(ctx.upsert(list, "b-mouse", 1).length, 2)

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

// the real dump: keyboards' embedded mouse nodes are hidden, standalone mice stay
var dump = JSON.stringify({ mice: [
  { name: "endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse" },
  { name: "endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse-keyboard-1" },
  { name: "wooting-wooting-60he-(arm)-consumer-control-1" },
  { name: "wooting-wooting-60he-(arm)-mouse" },
  { name: "finalmouse-ultralightx-dongle-mouse" }
] }) + "\n" + ctx.NODES_MARKER + "\n" +
  "Wooting Wooting 60HE (ARM)\t1000000000007 ff980000000007ff febeffdfffefffff fffffffffffffffe\n" +
  "Wooting Wooting 60HE (ARM) System Control\tc000 10000000000000 0\n" +
  "Wooting Wooting 60HE (ARM) Consumer Control\t733fff 0 0 483ffff17aff32d\n" +
  "Wooting Wooting 60HE (ARM) Mouse\t1f0000 0 0 0 0\n" +
  "Endgame Gear Endgame Gear OP1 8k v2 Gaming Mouse\t1f0000 0 0 0 0\n" +
  "Endgame Gear Endgame Gear OP1 8k v2 Gaming Mouse Keyboard\t733eff 0 0 483ffff17aff32d e09effdf01cfffff fffffffffffffffe\n" +
  "Finalmouse UltralightX dongle Mouse\t1f0000 0 0 0 0\n"
assert.strictEqual(
  JSON.stringify(ctx.parseDeviceDump(dump)),
  JSON.stringify(["endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse", "finalmouse-ultralightx-dongle-mouse"])
)
// a marker-less dump (sysfs unreadable) falls back to name filtering only
assert.strictEqual(
  JSON.stringify(ctx.parseDeviceDump("{\"mice\":[{\"name\":\"wooting-wooting-60he-(arm)-mouse\"}]}")),
  JSON.stringify(["wooting-wooting-60he-(arm)-mouse"])
)

assert.strictEqual(ctx.prettyName("wooting-wooting-60he-(arm)-mouse"), "Wooting 60he (arm)")
assert.strictEqual(ctx.prettyName("endgame-gear-endgame-gear-op1-8k-v2-gaming-mouse"), "Endgame Gear Op1 8k v2 Gaming")
assert.strictEqual(ctx.prettyName("finalmouse-ultralightx-dongle-mouse"), "Finalmouse Ultralightx Dongle")

console.log("ok")
