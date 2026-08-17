// node --test lambda/discord/
//
// Frames are built to the layout captured from the live server, with
// placeholder names, plus variants for the cases a live server will not
// produce on demand (empty, truncated).

import test from "node:test";
import assert from "node:assert/strict";
import { parseInfo, parsePlayers, describePlayers } from "./a2s.mjs";

const hex = (s) => Buffer.from(s.replace(/\s+/g, ""), "hex");

// index(1) + name + score(4) + duration(4), the layout PZ actually sends.
const playerRecord = (name, score, seconds) => {
  const tail = Buffer.alloc(8);
  tail.writeInt32LE(score, 0);
  tail.writeFloatLE(seconds, 4);
  return Buffer.concat([Buffer.from([0]), Buffer.from(`${name}\0`), tail]);
};

const playerReply = (...records) =>
  Buffer.concat([
    hex("ffffffff44"),
    Buffer.from([records.length]),
    ...records,
  ]);

test("parses an A2S_PLAYER reply", () => {
  const players = parsePlayers(playerReply(playerRecord("player-one", 63, 936)));
  assert.equal(players.length, 1);
  assert.equal(players[0].name, "player-one");
  assert.ok(Math.abs(players[0].seconds - 936) < 1);
});

test("an empty server yields no players", () => {
  assert.deepEqual(parsePlayers(hex("ffffffff4400")), []);
});

test("a truncated record does not read past the end", () => {
  // Name present, score/duration cut off mid-frame.
  const truncated = Buffer.concat([
    hex("ffffffff4401"),
    Buffer.from([0]),
    Buffer.from("player-one\0"),
    hex("3f00"),
  ]);
  assert.deepEqual(parsePlayers(truncated), [
    { name: "player-one", seconds: null },
  ]);
});

test("a count larger than the payload stops cleanly", () => {
  const players = parsePlayers(hex("ffffffff4405004100"));
  assert.ok(players.length < 5);
});

test("rejects a reply of the wrong type", () => {
  assert.throws(() => parsePlayers(hex("ffffffff4900")), /not an A2S_PLAYER/);
  assert.throws(() => parseInfo(hex("ffffffff4400")), /not an A2S_INFO/);
});

test("renders the player line", () => {
  const line = describePlayers({
    players: 2,
    maxPlayers: 32,
    list: [
      { name: "player-one", seconds: 936 },
      { name: "player-two", seconds: 7500 },
    ],
  });
  assert.equal(
    line,
    "👥 **Players** 2/32 · player-one (15m), player-two (2h 5m)",
  );
});

test("renders an empty server without naming anyone", () => {
  const line = describePlayers({ players: 0, maxPlayers: 32, list: [] });
  assert.equal(line, "👥 **Players** nobody online (0/32)");
});

test("falls back to the count when a player is counted but unnamed", () => {
  const line = describePlayers({
    players: 1,
    maxPlayers: 32,
    list: [{ name: "", seconds: 2 }],
  });
  assert.equal(line, "👥 **Players** 1/32 online");
});

test("a player under a minute reads as just joined", () => {
  const line = describePlayers({
    players: 1,
    maxPlayers: 32,
    list: [{ name: "player-one", seconds: 12 }],
  });
  assert.equal(line, "👥 **Players** 1/32 · player-one (just joined)");
});

test("parses name and counts out of an A2S_INFO reply", () => {
  const info = Buffer.concat([
    hex("ffffffff4911"),
    Buffer.from("Kentucky Fried Survivors\0Muldraugh, KY\0PZ\0Project Zomboid\0"),
    hex("d825"), // appid
    hex("0120"), // players, maxPlayers
    hex("00"), // bots
  ]);

  assert.deepEqual(parseInfo(info), {
    name: "Kentucky Fried Survivors",
    players: 1,
    maxPlayers: 32,
  });
});
