const APP_ID = "1216192261193465926";
const GUILD_ID = "356569257141731339";

async function promptSecret(label) {
  const stdin = process.stdin;
  if (!stdin.isTTY) {
    console.error(
      "No terminal available to prompt for the token.\n" +
        "Set DISCORD_BOT_TOKEN in the environment instead.",
    );
    process.exit(1);
  }

  process.stdout.write(label);
  stdin.setRawMode(true);
  stdin.resume();
  stdin.setEncoding("utf8");

  return new Promise((resolve) => {
    let buf = "";
    const onData = (chunk) => {
      for (const ch of chunk) {
        if (ch === "\r" || ch === "\n" || ch === "") { // Ctrl-D
          stdin.setRawMode(false);
          stdin.pause();
          stdin.removeListener("data", onData);
          process.stdout.write("\n");
          return resolve(buf.trim());
        }
        if (ch === "") { // Ctrl-C
          stdin.setRawMode(false);
          process.stdout.write("\n");
          process.exit(130);
        }
        if (ch === "" || ch === "\b") buf = buf.slice(0, -1);
        else buf += ch;
      }
    };
    stdin.on("data", onData);
  });
}

const TOKEN =
  process.env.DISCORD_BOT_TOKEN || (await promptSecret("Bot token (hidden): "));

if (!TOKEN) {
  console.error("No token given.");
  process.exit(1);
}

const commands = [
  {
    name: "pz",
    description: "Project Zomboid server controls",
    options: [
      {
        type: 1, // SUB_COMMAND
        name: "server-status",
        description: "Is the game server up, and what is its address?",
      },
      {
        type: 1,
        name: "infra-status",
        description: "Health of the host, world volume, ECS agent and backups",
      },
      {
        type: 1,
        name: "restart",
        description: "Restart the server (admin only; saves the world first)",
      },
    ],
  },
];

const url = `https://discord.com/api/v10/applications/${APP_ID}/guilds/${GUILD_ID}/commands`;

const res = await fetch(url, {
  method: "PUT",
  headers: {
    Authorization: `Bot ${TOKEN}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify(commands),
});

const body = await res.text();

if (!res.ok) {
  console.error(`Registration failed (HTTP ${res.status}):\n${body}`);
  process.exit(1);
}

console.log("Registered commands:");
for (const c of JSON.parse(body)) {
  const subs = (c.options ?? []).map((o) => o.name).join(", ");
  console.log(`  /${c.name}${subs ? ` [${subs}]` : ""}`);
}
