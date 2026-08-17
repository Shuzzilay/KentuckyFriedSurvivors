// Steam A2S query client. PZ answers it on the game port itself, so this is
// the only source that knows who is *connected* rather than what ECS is
// running - and it needs no AWS permission, no console access and no
// dependency. Kept free of AWS imports so it can be run against the real
// server from anywhere.

import { createSocket } from "node:dgram";

const HEADER = Buffer.from([0xff, 0xff, 0xff, 0xff]);
const INFO_REQUEST = Buffer.concat([
  HEADER,
  Buffer.from("TSource Engine Query\0", "ascii"),
]);

const CHALLENGE = 0x41;
const INFO_REPLY = 0x49;
const PLAYER_REPLY = 0x44;
const SPLIT_PACKET = -2;

export const DEFAULT_PORT = 16261;

function sendQuery(ip, port, payload, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = createSocket("udp4");
    let settled = false;

    const finish = (err, msg) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.close();
      err ? reject(err) : resolve(msg);
    };

    const timer = setTimeout(
      () => finish(new Error("game server did not answer the query")),
      timeoutMs,
    );

    socket.once("message", (msg) => finish(null, msg));
    socket.once("error", (err) => finish(err));
    socket.send(payload, port, ip, (err) => err && finish(err));
  });
}

// Each query is two round trips: the server answers the first request with a
// 4-byte challenge to echo back. `build` is called with null, then those bytes.
async function query(ip, port, build, deadline) {
  const remaining = () => {
    const left = deadline - Date.now();
    if (left <= 0) throw new Error("ran out of time querying the game server");
    return left;
  };

  let reply = await sendQuery(ip, port, build(null), remaining());
  if (reply.length >= 9 && reply.readUInt8(4) === CHALLENGE) {
    reply = await sendQuery(ip, port, build(reply.subarray(5, 9)), remaining());
  }

  if (reply.length >= 4 && reply.readInt32LE(0) === SPLIT_PACKET) {
    throw new Error("split-packet response is not supported");
  }
  return reply;
}

const infoRequest = (challenge) =>
  challenge ? Buffer.concat([INFO_REQUEST, challenge]) : INFO_REQUEST;

const playerRequest = (challenge) =>
  Buffer.concat([HEADER, Buffer.from([0x55]), challenge ?? HEADER]);

function cursor(buf, start) {
  let i = start;
  return {
    u8: () => buf.readUInt8(i++),
    i32: () => ((i += 4), buf.readInt32LE(i - 4)),
    f32: () => ((i += 4), buf.readFloatLE(i - 4)),
    skip: (n) => {
      i += n;
    },
    str: () => {
      const end = buf.indexOf(0, i);
      const stop = end < 0 ? buf.length : end;
      const value = buf.toString("utf8", i, stop);
      i = stop + 1;
      return value;
    },
    remaining: () => buf.length - i,
  };
}

export function parseInfo(buf) {
  if (buf.readUInt8(4) !== INFO_REPLY) throw new Error("not an A2S_INFO reply");

  const c = cursor(buf, 5);
  c.u8(); // protocol
  const name = c.str();
  c.str(); // map
  c.str(); // folder
  c.str(); // game
  c.skip(2); // appid
  return { name, players: c.u8(), maxPlayers: c.u8() };
}

export function parsePlayers(buf) {
  if (buf.readUInt8(4) !== PLAYER_REPLY) {
    throw new Error("not an A2S_PLAYER reply");
  }

  const c = cursor(buf, 5);
  const count = c.u8();
  const players = [];

  // Records are index + name + score(4) + duration(4); stop rather than read
  // past the end if the list is short or truncated.
  for (let n = 0; n < count; n++) {
    if (c.remaining() < 2) break;
    c.u8(); // index - PZ reports 0 for everyone
    const name = c.str();
    if (c.remaining() < 8) {
      players.push({ name, seconds: null });
      break;
    }
    c.i32(); // score
    players.push({ name, seconds: c.f32() });
  }

  return players;
}

// Returns { name, players, maxPlayers, list: [{ name, seconds }] }, or throws
// if the server does not answer inside the budget.
export async function queryServer(ip, { port = DEFAULT_PORT, budgetMs } = {}) {
  const deadline = Date.now() + budgetMs;

  const [info, list] = await Promise.all([
    query(ip, port, infoRequest, deadline).then(parseInfo),
    query(ip, port, playerRequest, deadline).then(parsePlayers),
  ]);

  return { ...info, list };
}

const forDuration = (seconds) => {
  if (seconds === null || !Number.isFinite(seconds) || seconds < 60) {
    return "just joined";
  }
  const mins = Math.floor(seconds / 60);
  if (mins < 60) return `${mins}m`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
};

// Lives here rather than in index.mjs only so it is testable without the AWS
// SDK. A player can be counted before they are named, so the count leads.
export function describePlayers(server) {
  const count = `${server.players}/${server.maxPlayers}`;
  if (server.players === 0) return `👥 **Players** nobody online (${count})`;

  const named = server.list
    .filter((p) => p.name)
    .map((p) => `${p.name} (${forDuration(p.seconds)})`);

  return named.length === 0
    ? `👥 **Players** ${count} online`
    : `👥 **Players** ${count} · ${named.join(", ")}`;
}
