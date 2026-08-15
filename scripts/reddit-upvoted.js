#!/usr/bin/env node
// Import your Reddit upvoted posts into vinboard via the Pinboard-compat API.
//
// Reddit's listing API only returns the ~1000 most recent upvotes.
// Link posts save their target URL (reddit permalink kept in notes);
// self posts save the reddit permalink. Tags: reddit + subreddit.
//
// Requires a Reddit "script" app (https://www.reddit.com/prefs/apps).
// With 2FA enabled, set REDDIT_PASSWORD to "password:otp".
//
// Env:
//   REDDIT_CLIENT_ID, REDDIT_CLIENT_SECRET, REDDIT_USERNAME, REDDIT_PASSWORD
//   VINBOARD_AUTH   handle:TOKEN (from /v1/user/api_token or settings)
//   VINBOARD_URL    default https://hotter.myaddr.dev/vinboard
//
// Usage: reddit-upvoted.js [--dry-run] [--limit N]

const env = (k) => {
  const v = process.env[k];
  if (!v) {
    console.error(`missing env: ${k}`);
    process.exit(2);
  }
  return v;
};

const DRY = process.argv.includes("--dry-run");
const limIx = process.argv.indexOf("--limit");
const MAX = limIx > -1 ? Number(process.argv[limIx + 1]) : Infinity;

const CLIENT_ID = env("REDDIT_CLIENT_ID");
const CLIENT_SECRET = env("REDDIT_CLIENT_SECRET");
const USERNAME = env("REDDIT_USERNAME");
const PASSWORD = env("REDDIT_PASSWORD");
const VINBOARD_AUTH = DRY ? process.env.VINBOARD_AUTH : env("VINBOARD_AUTH");
const VINBOARD_URL = (process.env.VINBOARD_URL || "https://hotter.myaddr.dev/vinboard").replace(/\/$/, "");
const UA = `vinboard-import/1.0 by ${USERNAME}`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function redditToken() {
  const res = await fetch("https://www.reddit.com/api/v1/access_token", {
    method: "POST",
    headers: {
      Authorization: "Basic " + Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString("base64"),
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": UA,
    },
    body: new URLSearchParams({ grant_type: "password", username: USERNAME, password: PASSWORD }),
  });
  const j = await res.json();
  if (!j.access_token) throw new Error(`reddit auth failed: ${JSON.stringify(j)}`);
  return j.access_token;
}

async function* upvoted(token) {
  let after = null;
  while (true) {
    const u = new URL(`https://oauth.reddit.com/user/${USERNAME}/upvoted`);
    u.searchParams.set("limit", "100");
    u.searchParams.set("type", "links");
    if (after) u.searchParams.set("after", after);
    const res = await fetch(u, { headers: { Authorization: `Bearer ${token}`, "User-Agent": UA } });
    if (!res.ok) throw new Error(`reddit listing failed: ${res.status} ${await res.text()}`);
    const j = await res.json();
    for (const c of j.data.children) if (c.kind === "t3") yield c.data;
    after = j.data.after;
    if (!after) return;
    await sleep(1100); // stay under Reddit's rate limit
  }
}

function toBookmark(p) {
  const permalink = `https://www.reddit.com${p.permalink}`;
  const isSelf = p.is_self || !p.url || p.url.startsWith(permalink);
  return {
    url: isSelf ? permalink : p.url,
    description: p.title || permalink,
    extended: isSelf ? "" : permalink,
    tags: `reddit ${p.subreddit.toLowerCase()}`,
    dt: new Date(p.created_utc * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
}

async function saveToVinboard(bm) {
  const u = new URL(`${VINBOARD_URL}/v1/posts/add`);
  for (const [k, v] of Object.entries(bm)) u.searchParams.set(k, v);
  u.searchParams.set("replace", "no");
  u.searchParams.set("shared", "no");
  u.searchParams.set("auth_token", VINBOARD_AUTH);
  const res = await fetch(u, { headers: { "User-Agent": UA } });
  if (!res.ok) throw new Error(`vinboard ${res.status}: ${await res.text()}`);
  return (await res.json()).result_code;
}

const token = await redditToken();
let n = 0, added = 0, dup = 0;
for await (const post of upvoted(token)) {
  if (n >= MAX) break;
  const bm = toBookmark(post);
  n++;
  if (DRY) {
    console.log(`[dry] ${bm.dt}  r/${post.subreddit}  ${bm.url}`);
    continue;
  }
  const code = await saveToVinboard(bm);
  code === "done" ? added++ : dup++;
  console.log(`${code === "done" ? "+" : "="} ${bm.url}`);
}
console.log(`\n${n} upvotes processed${DRY ? " (dry run)" : `: ${added} added, ${dup} already existed`}`);
