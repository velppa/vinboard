#!/usr/bin/env node
// Import your Reddit upvoted posts into vinboard via the Pinboard-compat API.
//
// Reddit's listing API only returns the ~1000 most recent upvotes.
// Link posts save their target URL (reddit permalink kept in notes);
// self posts save the reddit permalink. Tags: reddit + subreddit.
//
// Two auth modes:
//   Cookie (default, no app registration needed): set REDDIT_COOKIE to your
//     browser's reddit.com Cookie header (reddit_session=... is enough) and
//     the script pages old.reddit.com/user/<you>/upvoted.json. Works from
//     residential IPs; Reddit blocks most datacenter ranges.
//   OAuth script app: set REDDIT_CLIENT_ID/SECRET/PASSWORD instead.
//     With 2FA enabled, set REDDIT_PASSWORD to "password:otp".
//
// Env:
//   REDDIT_USERNAME              always required
//   REDDIT_COOKIE                cookie mode
//   REDDIT_CLIENT_ID, REDDIT_CLIENT_SECRET, REDDIT_PASSWORD   oauth mode
//   VINBOARD_AUTH   handle:TOKEN (from /v1/user/api_token or settings)
//   VINBOARD_URL    default https://uiuo.nl/vinboard
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

const COOKIE = process.env.REDDIT_COOKIE;
const USERNAME = env("REDDIT_USERNAME");
const VINBOARD_AUTH = DRY ? process.env.VINBOARD_AUTH : env("VINBOARD_AUTH");
const VINBOARD_URL = (process.env.VINBOARD_URL || "https://uiuo.nl/vinboard").replace(/\/$/, "");
const UA = COOKIE
  ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
  : `vinboard-import/1.0 by ${USERNAME}`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function redditToken() {
  if (COOKIE) return null;
  const CLIENT_ID = env("REDDIT_CLIENT_ID");
  const CLIENT_SECRET = env("REDDIT_CLIENT_SECRET");
  const PASSWORD = env("REDDIT_PASSWORD");
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
    const base = COOKIE
      ? `https://old.reddit.com/user/${USERNAME}/upvoted.json`
      : `https://oauth.reddit.com/user/${USERNAME}/upvoted`;
    const u = new URL(base);
    u.searchParams.set("limit", "100");
    u.searchParams.set("type", "links");
    if (after) u.searchParams.set("after", after);
    const headers = COOKIE
      ? { Cookie: COOKIE, "User-Agent": UA }
      : { Authorization: `Bearer ${token}`, "User-Agent": UA };
    const res = await fetch(u, { headers });
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
  // Notes carry the post's own content: selftext for self posts, the
  // permalink for link posts, plus direct image URLs for galleries.
  // The archive worker captures the bookmarked URL itself (full page,
  // images inlined), so notes are capped to fit the request line.
  let notes = isSelf ? (p.selftext || "") : permalink;
  if (p.is_gallery && p.media_metadata) {
    const imgs = (p.gallery_data?.items || [])
      .map((it) => {
        const m = p.media_metadata[it.media_id];
        const u = m?.s?.u || m?.s?.gif || m?.s?.mp4;
        return u ? u.replaceAll("&amp;", "&") : null;
      })
      .filter(Boolean);
    if (imgs.length) notes = `${notes}\n\nImages:\n${imgs.join("\n")}`.trim();
  }
  if (notes.length > 3000) notes = notes.slice(0, 3000) + "\u2026";
  return {
    url: isSelf ? permalink : p.url,
    description: p.title || permalink,
    extended: notes,
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

const token = COOKIE ? null : await redditToken();
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
