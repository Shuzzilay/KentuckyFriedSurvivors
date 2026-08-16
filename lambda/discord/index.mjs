
import { createPublicKey, verify } from "node:crypto";
import {
  ECSClient,
  DescribeServicesCommand,
  UpdateServiceCommand,
  ListContainerInstancesCommand,
  DescribeContainerInstancesCommand,
  DescribeTaskDefinitionCommand,
  ListTasksCommand,
  DescribeTasksCommand,
} from "@aws-sdk/client-ecs";
import { ECRClient, DescribeImagesCommand } from "@aws-sdk/client-ecr";
import {
  CloudWatchClient,
  GetMetricStatisticsCommand,
} from "@aws-sdk/client-cloudwatch";
import {
  EC2Client,
  DescribeInstancesCommand,
  DescribeInstanceStatusCommand,
  DescribeVolumesCommand,
} from "@aws-sdk/client-ec2";
import { S3Client, ListObjectsV2Command } from "@aws-sdk/client-s3";

const CLUSTER = process.env.PZ_CLUSTER;
const SERVICE = process.env.PZ_SERVICE;
const INSTANCE_TAG = process.env.PZ_INSTANCE_TAG_NAME;
const DATA_VOLUME_ID = process.env.PZ_DATA_VOLUME_ID;
const BACKUP_BUCKET = process.env.PZ_BACKUP_BUCKET;
const BACKUP_PREFIX = process.env.PZ_BACKUP_PREFIX;
const BACKUP_INTERVAL_S = Number(process.env.PZ_BACKUP_INTERVAL ?? 900);
const PUBLIC_KEY = process.env.DISCORD_PUBLIC_KEY;
const GUILD_ID = process.env.DISCORD_GUILD_ID;
const CHANNEL_ID = process.env.DISCORD_CHANNEL_ID;
const ADMIN_ROLE_ID = process.env.DISCORD_ADMIN_ROLE_ID;

const ECR_REPO = process.env.PZ_ECR_REPO;
const METRIC_NAMESPACE = process.env.PZ_METRIC_NAMESPACE ?? "PZServer";

const MOD_CATALOGUE = (() => {
  const map = new Map();
  try {
    for (const entry of JSON.parse(process.env.PZ_MOD_CATALOGUE ?? "[]")) {
      const ids = entry.mod_ids ?? [];
      for (const id of ids) {
        map.set(id, {
          workshopId: entry.workshop_id,
          name: ids.length === 1 ? entry.name : id,
        });
      }
    }
  } catch (err) {
    console.error("could not parse PZ_MOD_CATALOGUE", err);
  }
  return map;
})();

const WORKSHOP_URL = "https://steamcommunity.com/sharedfiles/filedetails/?id=";

function renderMod(modId) {
  const entry = MOD_CATALOGUE.get(modId);
  if (!entry?.workshopId) return modId;

  const label = entry.name || modId;
  return `[${label}](<${WORKSHOP_URL}${entry.workshopId}>)`;
}

const ecs = new ECSClient({});
const ec2 = new EC2Client({});
const s3 = new S3Client({});
const ecr = new ECRClient({});
const cw = new CloudWatchClient({});

const PING = 1;
const APPLICATION_COMMAND = 2;
const PONG = 1;
const CHANNEL_MESSAGE = 4;

const EPHEMERAL = 1 << 6;

const reply = (content, { ephemeral = false } = {}) => ({
  statusCode: 200,
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    type: CHANNEL_MESSAGE,
    data: { content, ...(ephemeral ? { flags: EPHEMERAL } : {}) },
  }),
});

const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function signatureIsValid(rawBody, signature, timestamp) {
  if (!signature || !timestamp) return false;
  try {
    const key = createPublicKey({
      key: Buffer.concat([SPKI_PREFIX, Buffer.from(PUBLIC_KEY, "hex")]),
      format: "der",
      type: "spki",
    });
    return verify(
      null,
      Buffer.from(timestamp + rawBody),
      key,
      Buffer.from(signature, "hex"),
    );
  } catch {
    return false;
  }
}

async function describeService() {
  const out = await ecs.send(
    new DescribeServicesCommand({ cluster: CLUSTER, services: [SERVICE] }),
  );
  return out.services?.[0];
}

async function publicIp() {
  const out = await ec2.send(
    new DescribeInstancesCommand({
      Filters: [
        { Name: "tag:Name", Values: [INSTANCE_TAG] },
        { Name: "instance-state-name", Values: ["running"] },
      ],
    }),
  );
  return out.Reservations?.[0]?.Instances?.[0]?.PublicIpAddress;
}

const deploymentInProgress = (service) =>
  (service?.deployments ?? []).some(
    (d) => d.status === "PRIMARY" && d.rolloutState === "IN_PROGRESS",
  );

async function handleStatus() {
  const service = await describeService();
  if (!service) return reply("Could not find the server's ECS service.");

  const running = service.runningCount ?? 0;
  const desired = service.desiredCount ?? 0;
  const restarting = deploymentInProgress(service);

  let line;
  if (restarting) line = "🟡 **Restarting** - the world is still loading.";
  else if (running >= 1) line = "🟢 **Up**";
  else if (desired === 0) line = "🔴 **Stopped** - deliberately scaled to zero.";
  else line = "🔴 **Down** - no task running.";

  const details = [`tasks: ${running}/${desired}`];

  if (running >= 1 && !restarting) {
    const ip = await publicIp();
    if (ip) details.push(`address: \`${ip}:16261\``);
  }

  return reply(`${line}\n${details.join(" · ")}`);
}


const ago = (date) => {
  const mins = Math.floor((Date.now() - new Date(date).getTime()) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  return hrs < 24 ? `${hrs}h ${mins % 60}m ago` : `${Math.floor(hrs / 24)}d ago`;
};

async function instanceHealth() {
  const out = await ec2.send(
    new DescribeInstancesCommand({
      Filters: [
        { Name: "tag:Name", Values: [INSTANCE_TAG] },
        { Name: "instance-state-name", Values: ["pending", "running"] },
      ],
    }),
  );
  const inst = out.Reservations?.[0]?.Instances?.[0];
  if (!inst) return { line: "🔴 **Host** - no running instance." };

  const status = await ec2.send(
    new DescribeInstanceStatusCommand({ InstanceIds: [inst.InstanceId] }),
  );
  const s = status.InstanceStatuses?.[0];
  const sys = s?.SystemStatus?.Status ?? "unknown";
  const ins = s?.InstanceStatus?.Status ?? "unknown";
  const healthy = sys === "ok" && ins === "ok";

  return {
    instanceId: inst.InstanceId,
    line:
      `${healthy ? "🟢" : "🟡"} **Host** \`${inst.InstanceId}\` ` +
      `(${inst.InstanceType}) · up ${ago(inst.LaunchTime)} · ` +
      `checks ${sys}/${ins}`,
  };
}

async function volumeHealth() {
  if (!DATA_VOLUME_ID) return null;
  const out = await ec2.send(
    new DescribeVolumesCommand({ VolumeIds: [DATA_VOLUME_ID] }),
  );
  const v = out.Volumes?.[0];
  if (!v) return "🔴 **World volume** - not found.";

  const att = v.Attachments?.[0];
  return att?.State === "attached"
    ? `🟢 **World volume** ${v.Size} GiB · attached`
    : `🟡 **World volume** ${v.Size} GiB · ${v.State} (not attached)`;
}

async function agentHealth() {
  const list = await ecs.send(
    new ListContainerInstancesCommand({ cluster: CLUSTER }),
  );
  const arns = list.containerInstanceArns ?? [];
  if (arns.length === 0) return "🔴 **ECS agent** - no host registered.";

  const out = await ecs.send(
    new DescribeContainerInstancesCommand({
      cluster: CLUSTER,
      containerInstances: arns,
    }),
  );
  const ci = out.containerInstances?.[0];
  if (!ci?.agentConnected) {
    return "🔴 **ECS agent** registered but DISCONNECTED.";
  }

  const n = ci.runningTasksCount ?? 0;
  return `🟢 **ECS agent** connected · ${n} task${n === 1 ? "" : "s"} on host`;
}

async function backupHealth() {
  if (!BACKUP_BUCKET) return null;

  const out = await s3.send(
    new ListObjectsV2Command({
      Bucket: BACKUP_BUCKET,
      Prefix: `${BACKUP_PREFIX}/`,
    }),
  );
  const objects = out.Contents ?? [];
  if (objects.length === 0) return "🔴 **Backups** - none found.";

  const newest = objects.reduce((a, b) =>
    new Date(a.LastModified) > new Date(b.LastModified) ? a : b,
  );
  const ageS = (Date.now() - new Date(newest.LastModified).getTime()) / 1000;
  const mb = (newest.Size / 1048576).toFixed(1);

  const stale = ageS > BACKUP_INTERVAL_S * 2;
  return (
    `${stale ? "🔴" : "🟢"} **Backups** ${objects.length} archives · ` +
    `latest ${ago(newest.LastModified)} (${mb} MB)` +
    (stale ? " — **STALE**" : "")
  );
}

async function deploymentHealth() {
  const list = await ecs.send(
    new ListTasksCommand({ cluster: CLUSTER, serviceName: SERVICE }),
  );
  const arns = list.taskArns ?? [];
  if (arns.length === 0) return "🔴 **Deployment** - no running task.";

  const tasks = await ecs.send(
    new DescribeTasksCommand({ cluster: CLUSTER, tasks: arns }),
  );
  const task = tasks.tasks?.[0];

  const def = await ecs.send(
    new DescribeTaskDefinitionCommand({
      taskDefinition: task.taskDefinitionArn,
    }),
  );
  const pz = def.taskDefinition?.containerDefinitions?.find(
    (c) => c.name === "pz",
  );

  const tag = (pz?.image ?? "").split(":").pop() ?? "unknown";
  const short = tag.slice(0, 7);

  const env = Object.fromEntries(
    (pz?.environment ?? []).map((e) => [e.name, e.value]),
  );
  const mods = (env.PZ_INI_Mods ?? "").split(";").filter(Boolean);

  const lines = [
    `🟢 **Deployment** \`${short}\` · rev ${def.taskDefinition?.revision}`,
  ];

  if (task?.startedAt) {
    lines.push(`⏱️ **Uptime** ${ago(task.startedAt)} since last restart`);
  }

  lines.push(
    mods.length > 0
      ? `🧩 **Mods** ${mods.map(renderMod).join(", ")}`
      : "🧩 **Mods** none loaded",
  );

  return { lines, deployedTag: tag };
}

async function ecrHealth(deployedTag) {
  if (!ECR_REPO) return null;

  const out = await ecr.send(
    new DescribeImagesCommand({ repositoryName: ECR_REPO }),
  );
  const images = (out.imageDetails ?? []).filter(
    (i) => (i.imageTags ?? []).length > 0,
  );
  if (images.length === 0) return "🔴 **ECR** - no tagged images.";

  const newest = images.reduce((a, b) =>
    new Date(a.imagePushedAt) > new Date(b.imagePushedAt) ? a : b,
  );
  const newestTag = newest.imageTags[0];

  if (!deployedTag) {
    return (
      `⚪ **ECR** ${images.length} images · newest \`${newestTag.slice(0, 7)}\`` +
      " (nothing running to compare against)"
    );
  }

  if (newestTag === deployedTag) {
    return `🟢 **ECR** ${images.length} images · running the newest`;
  }
  return (
    `🟡 **ECR** ${images.length} images · newer build available: ` +
    `\`${newestTag.slice(0, 7)}\` (pushed ${ago(newest.imagePushedAt)})`
  );
}

async function latestMetric(metricName, statistic = "Maximum") {
  const now = new Date();
  const out = await cw.send(
    new GetMetricStatisticsCommand({
      Namespace: METRIC_NAMESPACE,
      MetricName: metricName,
      StartTime: new Date(now.getTime() - 3600_000),
      EndTime: now,
      Period: 3600,
      Statistics: [statistic],
    }),
  );

  const point = (out.Datapoints ?? []).sort(
    (a, b) => new Date(b.Timestamp) - new Date(a.Timestamp),
  )[0];

  return point ? point[statistic] : null;
}

async function metricAbsenceReason(metricName) {
  const now = new Date();
  try {
    const out = await cw.send(
      new GetMetricStatisticsCommand({
        Namespace: METRIC_NAMESPACE,
        MetricName: metricName,
        StartTime: new Date(now.getTime() - 14 * 86400_000),
        EndTime: now,
        Period: 86400,
        Statistics: ["Maximum"],
      }),
    );

    const points = (out.Datapoints ?? []).sort(
      (a, b) => new Date(b.Timestamp) - new Date(a.Timestamp),
    );

    if (points.length === 0) {
      return "never published - the running sidecar predates this metric, so it needs a deploy";
    }

    const cadenceMins = Math.round(BACKUP_INTERVAL_S / 60);
    return `last published ${ago(points[0].Timestamp)}; the sidecar publishes every ${cadenceMins}m`;
  } catch {
    return "no data, and the lookback failed";
  }
}

async function loadHealth() {
  const [loadPerCore, memPct] = await Promise.all([
    latestMetric("HostLoadPerCore", "Average"),
    latestMetric("HostMemoryUsedPercent", "Average"),
  ]);

  if (loadPerCore === null && memPct === null) {
    return `⚪ **Load** no recent metric — ${await metricAbsenceReason("HostLoadPerCore")}.`;
  }

  const parts = [];

  if (loadPerCore !== null) {
    const icon = loadPerCore >= 1.0 ? "🔴" : loadPerCore >= 0.7 ? "🟡" : "🟢";
    parts.push(`${icon} **CPU** ${loadPerCore.toFixed(2)} load/core`);
  }

  if (memPct !== null) {
    const icon = memPct >= 93 ? "🔴" : memPct >= 85 ? "🟡" : "🟢";
    parts.push(`${icon} **Memory** ${memPct.toFixed(0)}% used`);
  }

  return parts.join(" · ");
}

async function diskHealth() {
  const raw = await latestMetric("DataVolumeUsedPercent");

  if (raw === null) {
    return `⚪ **Disk** no recent metric — ${await metricAbsenceReason("DataVolumeUsedPercent")}.`;
  }

  const pct = Math.round(raw);
  const icon = pct >= 90 ? "🔴" : pct >= 75 ? "🟡" : "🟢";
  return `${icon} **Disk** ${pct}% of the world volume used`;
}

async function handleInfraStatus() {
  let deployment = null;
  let deploymentLines = [];
  try {
    deployment = await deploymentHealth();
    deploymentLines =
      typeof deployment === "object" ? deployment.lines : [deployment];
  } catch (err) {
    console.error("infra check failed", { label: "Deployment", err });
    deploymentLines = [`⚠️ **Deployment** - check failed (${err.name})`];
  }

  const checks = [
    ["ECR", () => ecrHealth(deployment?.deployedTag)],
    ["Host", instanceHealth],
    ["Load", loadHealth],
    ["World volume", volumeHealth],
    ["Disk", diskHealth],
    ["ECS agent", agentHealth],
    ["Backups", backupHealth],
  ];

  const results = await Promise.all(
    checks.map(async ([label, fn]) => {
      try {
        const out = await fn();
        return typeof out === "object" && out !== null ? out.line : out;
      } catch (err) {
        console.error("infra check failed", { label, err });
        return `⚠️ **${label}** - check failed (${err.name})`;
      }
    }),
  );

  return reply([...deploymentLines, ...results].filter(Boolean).join("\n"));
}

async function handleRestart(member) {
  const roles = member?.roles ?? [];
  if (!roles.includes(ADMIN_ROLE_ID)) {
    return reply("You need the admin role to restart the server.", {
      ephemeral: true,
    });
  }

  const service = await describeService();
  if (deploymentInProgress(service)) {
    return reply("A restart is already in progress - give it a few minutes.", {
      ephemeral: true,
    });
  }

  await ecs.send(
    new UpdateServiceCommand({
      cluster: CLUSTER,
      service: SERVICE,
      forceNewDeployment: true,
    }),
  );

  return reply(
    "🔄 **Restart started.** The world is saved first, so this takes a few " +
      "minutes. Check back with `/pz server-status`.",
  );
}

export const handler = async (event) => {
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? "", "base64").toString("utf8")
    : (event.body ?? "");

  const headers = event.headers ?? {};
  if (
    !signatureIsValid(
      rawBody,
      headers["x-signature-ed25519"],
      headers["x-signature-timestamp"],
    )
  ) {
    return { statusCode: 401, body: "invalid request signature" };
  }

  const interaction = JSON.parse(rawBody);

  if (interaction.type === PING) {
    return {
      statusCode: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: PONG }),
    };
  }

  if (interaction.type !== APPLICATION_COMMAND) {
    return reply("Unsupported interaction.", { ephemeral: true });
  }

  if (interaction.guild_id !== GUILD_ID) {
    return reply("This bot only works in its home server.", {
      ephemeral: true,
    });
  }

  if (CHANNEL_ID && interaction.channel_id !== CHANNEL_ID) {
    return reply(`Use these commands in <#${CHANNEL_ID}>.`, {
      ephemeral: true,
    });
  }

  const sub = interaction.data?.options?.[0]?.name;

  try {
    if (sub === "server-status") return await handleStatus();
    if (sub === "infra-status") return await handleInfraStatus();
    if (sub === "restart") return await handleRestart(interaction.member);
    return reply(`Unknown command: ${sub}`, { ephemeral: true });
  } catch (err) {
    console.error("command failed", { sub, err });
    return reply(`Something went wrong: ${err.name}`, { ephemeral: true });
  }
};
