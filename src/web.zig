const std = @import("std");
const httpz = @import("httpz");
const server = @import("server.zig");
const db_mod = @import("db.zig");
const suggest_mod = @import("suggest.zig");
const trackers = @import("trackers.zig");
const models = @import("models.zig");
const html = @import("html.zig");
const auth = @import("auth.zig");
const oidc = @import("oidc.zig");

const App = server.App;

const page_size: i64 = 50;
pub const default_font_size: i64 = 15;

pub fn registerRoutes(router: anytype) void {
    router.*.get("/", index, .{});
    router.*.get("/ui/list", listFragment, .{});
    router.*.get("/ui/edit/:id", editForm, .{});
    router.*.get("/ui/item/:id", itemFragment, .{});
    router.*.post("/ui/edit/:id", editSubmit, .{});
    router.*.post("/ui/delete/:id", deleteSubmit, .{});
    router.*.post("/ui/star/:id", starToggle, .{});
    router.*.post("/ui/read/:id", markRead, .{});
    router.*.get("/ui/archive/:id", archiveControl, .{});
    router.*.post("/ui/archive/:id", archiveControl, .{});
    router.*.get("/add", addPage, .{});
    router.*.post("/ui/add", addSubmit, .{});
    router.*.get("/setup", setupPage, .{});
    router.*.get("/login", loginPage, .{});
    router.*.get("/ui/tags", tagsJson, .{});
    router.*.get("/ui/suggest", suggestJson, .{});
    router.*.post("/ui/password", passwordSubmit, .{});
    router.*.post("/ui/token", tokenSubmit, .{});
    router.*.post("/ui/fontsize", fontSizeSubmit, .{});
    router.*.post("/ui/tag/rename", tagRename, .{});
    router.*.post("/ui/tag/delete", tagDelete, .{});
    router.*.get("/vinboard.shortcut", shortcutDownload, .{});
    router.*.post("/ui/share/:id", shareToggle, .{});
    router.*.get("/system", systemPage, .{});
    router.*.get("/signup", signupPage, .{});
    router.*.post("/ui/signup", signupSubmit, .{});
    router.*.get("/static/captcha.png", captchaPng, .{});
    router.*.post("/ui/login", loginSubmit, .{});
    router.*.post("/ui/logout", logoutSubmit, .{});
    router.*.get("/oidc/login", oidcLogin, .{});
    router.*.get("/oidc/callback", oidcCallback, .{});
    router.*.post("/ui/oidc", oidcConfigSubmit, .{});
    router.*.get("/static/style.css", styleCss, .{});
    // Glob fallback: serves /u:<handle> pages, 404 otherwise.
    router.*.get("/*", fallbackRoute, .{});
}

// Pinboard look: condensed from pinboard.in basic/skeleton/bookmarks stylesheets.
const css =
    \\body { color:#333; margin:0; font-size:15px; font-family:helvetica,sans-serif; word-wrap:break-word; text-align:center; }
    \\p { margin-top:2px; margin-bottom:12px; }
    \\a { text-decoration:none; color:#11a; }
    \\a:visited { color:#51a; }
    \\h1 { font-size:1.8em; font-weight:normal; margin-top:10px; }
    \\input, textarea { font-size:90%; border:1px solid #ddd; }
    \\#content { max-width:1050px; margin:0 auto; min-height:400px; padding-left:10px; text-align:left; }
    \\#banner { border-bottom:1px dotted #aaa; margin-bottom:0.7em; max-width:980px; padding-bottom:9px; text-align:left; }
    \\#logo { float:left; height:24px; }
    \\#pinboard_name { font-size:1.4em; color:#aaa; }
    \\#pinboard_name:hover { color:red; }
    \\#top_menu { margin-top:2px; float:right; }
    \\button { -webkit-appearance:none; appearance:none; background:#157efb; color:#fff; border:0; border-radius:14px; padding:4px 16px; font:inherit; font-weight:bold; line-height:1.4; cursor:pointer; }
    \\a.btn, a.btn:visited { display:inline-block; background:#157efb; color:#fff; border-radius:14px; padding:4px 16px; font-weight:bold; line-height:1.4; margin-right:6px; }
    \\button.linklike { -webkit-appearance:none; appearance:none; background:none; border:0; border-radius:0; padding:0; font:inherit; font-weight:normal; color:#11a; cursor:pointer; }
    \\#main_column { max-width:700px; float:left; width:100%; text-align:left; position:relative; }
    \\#bookmarks { margin-top:1em; margin-left:6px; }
    \\#right_bar { float:left; margin-left:10px; text-align:left; width:320px; }
    \\#nextprev { margin-bottom:1em; }
    \\a.next_prev { color:#777; }
    \\#filter_bar { max-width:980px; margin-top:6px; margin-bottom:0.5em; text-align:left; }
    \\#filter_bar a.uname, #filter_bar a.uname:visited { color:#a51; font-weight:bold; }
    \\a.filter, a.filter:visited { color:#11a; }
    \\a.filter.selected, a.filter.selected:visited { color:#333; font-weight:bold; }
    \\.bookmark { padding:3px; width:95%; float:left; margin-bottom:1.3em; }
    \\.bookmark_title { line-height:130%; font-size:110%; overflow-wrap:anywhere; }
    \\.unread { color:#a41; }
    \\a.url_link { font-size:90%; color:#11a; overflow-wrap:anywhere; }
    \\.lock { font-size:80%; opacity:0.7; }
    \\.description { line-height:120%; margin-top:2px; color:#555; }
    \\a.tag { color:#a51; line-height:190%; }
    \\a.edit, a.edit:visited { color:#aaa; }
    \\a.edit:hover { color:#44d; }
    \\a.delete, a.delete:visited { color:#aaa; }
    \\a.delete:hover { color:#44d; }
    \\.archived, .archived:visited { color:#aaa; }
    \\.star { color:#ccc; margin-left:-20px; font-size:1.3em; cursor:pointer; float:left; }
    \\.star span:hover { color:#22a; }
    \\.star .selected_star { color:#22a; }
    \\#right_bar input[type=search] { width:300px; margin-bottom:0.6em; padding:3px; border-radius:6px; }
    \\.search_btn { margin-bottom:1em; }
    \\#tag_cloud a.tag { margin-right:6px; }
    \\a.tc1 { font-size:1.5em; }
    \\a.tc2 { font-size:1.3em; }
    \\a.tc3 { font-size:1.15em; }
    \\a.tf, a.tf:visited { color:#b97; }
    \\.prev_saved { background:#fff8dc; border:1px solid #e8d9a0; border-radius:6px; padding:6px 10px; max-width:490px; color:#5a4718; }
    \\.prev_saved .when { color:inherit; font-size:inherit; }
    \\@media (prefers-color-scheme: dark) {
    \\  body { background:#1c1c1e; color:#ccc; }
    \\  a { color:#7aa2f7; }
    \\  a:visited { color:#a98af7; }
    \\  a.url_link { color:#7aa2f7; }
    \\  #pinboard_name { color:#888; }
    \\  #banner { border-color:#555; }
    \\  #filter_bar a.uname, #filter_bar a.uname:visited { color:#d19a66; }
    \\  a.filter, a.filter:visited { color:#7aa2f7; }
    \\  button.linklike { color:#7aa2f7; }
    \\  a.filter.selected, a.filter.selected:visited { color:#eee; }
    \\  a.tag { color:#d19a66; }
    \\  a.tf, a.tf:visited { color:#8a6f4d; }
    \\  .unread { color:#e06c75; }
    \\  .description { color:#aaa; }
    \\  .when { color:#888; }
    \\  .faint { color:#777; }
    \\  a.edit, a.edit:visited, a.delete, a.delete:visited, .archived, .archived:visited { color:#777; }
    \\  a.edit:hover, a.delete:hover { color:#7aa2f7; }
    \\  .star { color:#666; }
    \\  .star span:hover { color:#7aa2f7; }
    \\  .star .selected_star { color:#7aa2f7; }
    \\  a.next_prev { color:#999; }
    \\  input, textarea { background:#2a2a2c; color:#ccc; border-color:#444; }
    \\  .edit_form, .edit_form p { color:#999; }
    \\  .prev_saved { background:#2e2a1c; border-color:#544a2a; color:#e6d7a4; }
    \\}
    \\.when { font-size:90%; color:#777; }
    \\.faint { color:#aaa; }
    \\.edit_form { color:#888; }
    \\.edit_form p { line-height:1.5; margin-bottom:10px; color:#888; }
    \\.edit_form input[type=text], .edit_form input[type=password], .edit_form textarea { width:490px; max-width:95%; margin-bottom:3px; }
    \\.edit_form textarea[name=title] { resize:none; overflow:hidden; line-height:1.35; padding:2px 3px; }
    \\.edit_form input[type=checkbox] { width:17px; height:17px; vertical-align:-4px; margin-right:6px; }
    \\.edit_form label { display:inline-block; margin-right:20px; line-height:2; }
    \\.tag_sug { margin:2px 0 6px; }
    \\.stepper input[type=number] { width:56px; text-align:center; margin:0 4px; }
    \\.stepper button { padding:4px 12px; }
    \\.tag_sug a { margin-right:8px; }
    \\@media (max-width:640px) {
    \\  .edit_form input[type=text], .edit_form input[type=password], .edit_form textarea { width:100%; max-width:100%; font-size:16px; box-sizing:border-box; }
    \\  .search_btn { font-size:16px; }
    \\  #content { padding:0 8px; }
    \\  #right_bar { width:auto; }
    \\}
    \\#footer { margin-top:3em; color:#888; clear:both; }
;

// Fills an empty tags field from the decision model once the form is up.
// Whatever the visitor types wins: a suggestion that arrives late is dropped
// rather than overwriting them.
const suggest_script =
    \\<script>
    \\(()=>{
    \\  const f=document.querySelector('.edit_form'); if(!f)return;
    \\  // Named controls come from f.elements: a form's own .title property
    \\  // is the html attribute, not the field.
    \\  const c=f.elements, el=c.tags, url=c.url.value; if(!el||el.value||!url)return;
    \\  el.placeholder='suggesting\u2026';
    \\  const q=new URLSearchParams({url:url,title:c.title.value,notes:c.notes.value});
    \\  fetch('ui/suggest?'+q).then(r=>r.ok?r.json():null).then(d=>{
    \\    el.placeholder='';
    \\    if(d&&d.tags&&d.tags.length&&!el.value&&el!==document.activeElement)
    \\      el.value=d.tags.join(' ')+' ';
    \\  }).catch(()=>{el.placeholder='';});
    \\})();
    \\</script>
;

// Tag autocomplete for any input[name=tags]: suggests existing tags for the
// token under the cursor; click appends it.
const tag_js =
    \\<script>
    \\let _tags=null;
    \\function vbTags(){return _tags?Promise.resolve(_tags):fetch('ui/tags').then(r=>r.ok?r.json():[]).then(t=>(_tags=t,t));}
    \\function vbLocalTimes(root){
    \\  (root||document).querySelectorAll('.when[data-ts]').forEach(el=>{
    \\    const d=new Date(parseInt(el.dataset.ts,10)*1000);
    \\    const p=n=>String(n).padStart(2,'0');
    \\    el.textContent=d.getFullYear()+'.'+p(d.getMonth()+1)+'.'+p(d.getDate())+'\u00a0\u00a0'+p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());
    \\    delete el.dataset.ts;
    \\  });
    \\}
    \\function vbGrow(el){el.style.height='auto';el.style.height=el.scrollHeight+'px';}
    \\function vbGrowAll(root){(root||document).querySelectorAll('textarea[name=title]').forEach(vbGrow);}
    \\document.addEventListener('DOMContentLoaded',()=>{vbLocalTimes();vbGrowAll();});
    \\document.addEventListener('htmx:afterSwap',e=>{vbLocalTimes(e.target);vbGrowAll(e.target);});
    \\document.addEventListener('input',e=>{if(e.target.matches('textarea[name=title]'))vbGrow(e.target);});
    \\// A title is one line of text, so Enter submits instead of breaking it.
    \\document.addEventListener('keydown',e=>{
    \\  if(e.key==='Enter'&&e.target.matches('textarea[name=title]')){e.preventDefault();e.target.form.requestSubmit();}
    \\});
    \\document.addEventListener('input',e=>{
    \\  const el=e.target; if(el.name!=='tags')return;
    \\  vbTags().then(tags=>{
    \\    let box=el._sug;
    \\    if(!box){box=document.createElement('div');box.className='tag_sug';el.insertAdjacentElement('afterend',box);el._sug=box;}
    \\    box.innerHTML='';
    \\    const parts=el.value.split(' ');
    \\    const cur=parts[parts.length-1].toLowerCase();
    \\    if(!cur)return;
    \\    tags.filter(t=>t.toLowerCase().startsWith(cur)&&t.toLowerCase()!==cur).slice(0,10).forEach(t=>{
    \\      const b=document.createElement('a');b.href='#';b.className='tag';b.textContent=t;
    \\      b.onclick=ev=>{ev.preventDefault();parts[parts.length-1]=t;el.value=parts.join(' ')+' ';box.innerHTML='';el.focus();};
    \\      box.appendChild(b);
    \\    });
    \\  });
    \\});
    \\</script>
;

pub fn styleCss(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = httpz.ContentType.CSS;
    res.body = css;
}

fn esc(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    return html.escape(arena, s);
}

fn urlEncode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(a, c),
        else => try out.appendSlice(a, &[3]u8{ '%', hex[c >> 4], hex[c & 15] }),
    };
    return out.toOwnedSlice(a);
}

// Howard Hinnant's civil_from_days.
fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn fmtDate(a: std.mem.Allocator, unix: i64) ![]u8 {
    const c = civilFromDays(@divFloor(unix, 86400));
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u64, @intCast(c.y)), @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
    });
}

/// Pinboard's bookmark timestamp: "2026.08.01  22:57:39" (UTC).
fn fmtDateTime(a: std.mem.Allocator, unix: i64) ![]u8 {
    const c = civilFromDays(@divFloor(unix, 86400));
    const sec = @mod(unix, 86400);
    return std.fmt.allocPrint(a, "{d:0>4}.{d:0>2}.{d:0>2} &nbsp;{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(c.y)),               @as(u64, @intCast(c.m)),                @as(u64, @intCast(c.d)),
        @as(u64, @intCast(@divFloor(sec, 3600))), @as(u64, @intCast(@mod(@divFloor(sec, 60), 60))), @as(u64, @intCast(@mod(sec, 60))),
    });
}

const Filter = struct {
    q: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    toread: bool = false,
    starred: bool = false,
    shared: ?bool = null,
    untagged: bool = false,
    archived: bool = false,
    user_id: ?i64 = null,
    offset: i64 = 0,
};

fn parseFilter(req: *httpz.Request) !Filter {
    const qs = try req.query();
    var f = Filter{};
    if (qs.get("q")) |v| {
        if (v.len > 0) f.q = v;
    }
    if (qs.get("tag")) |v| {
        if (v.len > 0) f.tag = v;
    }
    if (qs.get("toread")) |v| f.toread = std.mem.eql(u8, v, "1");
    if (qs.get("starred")) |v| f.starred = std.mem.eql(u8, v, "1");
    if (qs.get("private")) |v| {
        if (std.mem.eql(u8, v, "1")) f.shared = false;
    }
    if (qs.get("public")) |v| {
        if (std.mem.eql(u8, v, "1")) f.shared = true;
    }
    if (qs.get("untagged")) |v| f.untagged = std.mem.eql(u8, v, "1");
    if (qs.get("archived")) |v| f.archived = std.mem.eql(u8, v, "1");
    if (qs.get("offset")) |v| f.offset = std.fmt.parseInt(i64, v, 10) catch 0;
    return f;
}

const Settings = struct { font_size: i64 = default_font_size, admin: bool = false };

/// Parsed user settings; defaults on any error. Caller holds the db lock.
fn loadSettings(app: *App, a: std.mem.Allocator, uid: i64) Settings {
    const raw = (db_mod.getSettings(app.db, a, uid) catch return .{}) orelse return .{};
    return std.json.parseFromSliceLeaky(Settings, a, raw, .{ .ignore_unknown_fields = true }) catch .{};
}

/// Set one settings key, preserving unknown keys. Caller holds the db lock.
fn saveSettingInt(app: *App, a: std.mem.Allocator, uid: i64, key: []const u8, value: i64) !void {
    const raw = (try db_mod.getSettings(app.db, a, uid)) orelse "{}";
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch
        std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{}) catch unreachable;
    if (parsed != .object) {
        parsed = std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{}) catch unreachable;
    }
    try parsed.object.put(a, key, .{ .integer = value });
    const out = try std.json.Stringify.valueAlloc(a, parsed, .{});
    try db_mod.setSettings(app.db, uid, out);
}

/// A bookmark only when it belongs to the user. Caller holds the db lock.
fn ownedBookmark(app: *App, a: std.mem.Allocator, id: i64, uid: i64) !?models.Bookmark {
    const bm = (try db_mod.getBookmark(app.db, a, id)) orelse return null;
    if (bm.user_id != uid) return null;
    return bm;
}

/// Logged-in user id from the vb_session cookie. Caller holds the db lock.
fn sessionUserId(app: *App, req: *httpz.Request) ?i64 {
    const cookie = req.header("cookie") orelse return null;
    const token = auth.cookieValue(cookie, "vb_session") orelse return null;
    return db_mod.sessionUser(app.db, token, db_mod.nowUnix()) catch null;
}

/// Query-string suffix ("&tag=...&toread=1") carrying the filter, minus offset.
fn filterParams(a: std.mem.Allocator, f: Filter) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (f.q) |q| {
        try out.appendSlice(a, "&q=");
        try out.appendSlice(a, try urlEncode(a, q));
    }
    if (f.tag) |t| {
        try out.appendSlice(a, "&tag=");
        try out.appendSlice(a, try urlEncode(a, t));
    }
    if (f.toread) try out.appendSlice(a, "&toread=1");
    if (f.starred) try out.appendSlice(a, "&starred=1");
    if (f.shared) |s| try out.appendSlice(a, if (s) "&public=1" else "&private=1");
    if (f.untagged) try out.appendSlice(a, "&untagged=1");
    if (f.archived) try out.appendSlice(a, "&archived=1");
    return out.toOwnedSlice(a);
}

/// One bookmark's inner display fragment (lives inside div.bookmark).
fn renderDisplay(app: *App, a: std.mem.Allocator, bm: models.Bookmark, editable: bool) ![]u8 {
    const base = app.base_path;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    const title = if (bm.title.len > 0) bm.title else bm.url;
    const title_cls: []const u8 = if (bm.toread) " unread" else "";
    const esc_url = try esc(a, bm.url);
    try out.appendSlice(a, "<div class=\"display\">");
    const lock: []const u8 = if (bm.shared)
        ""
    else if (editable)
        try std.fmt.allocPrint(a,
            \\ <a class="lock" href="#" title="private - click to make public" hx-post="{s}/ui/share/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">&#128274;</a>
        , .{ base, bm.id })
    else
        " <span class=\"lock\" title=\"private\">&#128274;</span>";
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\<a class="bookmark_title{s}" href="{s}">{s}</a>{s}
        \\<div><a class="url_link" href="{s}">{s}</a></div>
    , .{ title_cls, esc_url, try esc(a, title), lock, esc_url, esc_url }));

    if (bm.notes.len > 0) {
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\<div class="description">{s}</div>
        , .{try esc(a, bm.notes)}));
    }

    if (bm.tags.len > 0) {
        try out.appendSlice(a, "<div>");
        for (bm.tags) |t| {
            try out.appendSlice(a, try std.fmt.allocPrint(a,
                \\<a class="tag" href="{s}/?tag={s}">{s}</a>
            , .{ base, try urlEncode(a, t), try esc(a, t) }));
            try out.append(a, ' ');
        }
        try out.appendSlice(a, "</div>");
    }
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\<div><span class="when" data-ts="{d}">{s}</span>
    , .{ bm.created_at, try fmtDateTime(a, bm.created_at) }));
    if (editable) {
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\ &nbsp;
            \\<a class="edit" href="#" hx-get="{s}/ui/edit/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">edit</a> &nbsp;
            \\<a class="delete" href="#" hx-post="{s}/ui/delete/{d}" hx-confirm="Delete this bookmark?" hx-target="closest .bookmark" hx-swap="delete">delete</a>
        , .{ base, bm.id, base, bm.id }));
    }
    if (editable) {
        try out.appendSlice(a, " &nbsp; ");
        try out.appendSlice(a, try archiveLink(a, base, bm.id, try db_mod.archiveState(app.db, bm.id)));
    }
    if (editable and bm.toread) {
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\ &nbsp;&nbsp; <a class="mark_read" href="#" hx-post="{s}/ui/read/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">mark as read</a>
        , .{ base, bm.id }));
    }
    try out.appendSlice(a, "</div></div>");
    return out.toOwnedSlice(a);
}

/// The archive control of a bookmark: a link to its copy, a placeholder that
/// re-checks while the copy is being made, or a link that starts making one.
fn archiveLink(a: std.mem.Allocator, base: []const u8, id: i64, state: db_mod.ArchiveState) ![]u8 {
    return switch (state) {
        .done => std.fmt.allocPrint(a,
            \\<a class="archived" href="{s}/api/bookmarks/{d}/archive">archived</a>
        , .{ base, id }),
        .pending => std.fmt.allocPrint(a,
            \\<span class="archived" hx-get="{s}/ui/archive/{d}" hx-trigger="every 3s" hx-swap="outerHTML">archiving&hellip;</span>
        , .{ base, id }),
        .none, .failed => std.fmt.allocPrint(a,
            \\<a class="archived" href="#" title="{s}" hx-post="{s}/ui/archive/{d}" hx-swap="outerHTML">archive</a>
        , .{ if (state == .failed) "the last attempt failed - try again" else "save a copy of this page", base, id }),
    };
}

/// GET: the archive control as it stands.  POST: queue the page, then the
/// control.  Either way the answer replaces the control in place.
pub fn archiveControl(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    const bm = (ownedBookmark(app, a, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    if (req.method == .POST) db_mod.requeueArchive(app.db, bm.url) catch |e| return serverError(res, e);
    const state = db_mod.archiveState(app.db, id) catch |e| return serverError(res, e);
    res.content_type = httpz.ContentType.HTML;
    res.body = try archiveLink(a, app.base_path, id, state);
}

/// Star column + display: the innerHTML of div.bookmark (htmx swap target).
fn renderInner(app: *App, a: std.mem.Allocator, bm: models.Bookmark, editable: bool) ![]u8 {
    const star: []const u8 = if (editable) try std.fmt.allocPrint(a,
        \\<div class="star"><span class="{s}" title="{s}" hx-post="{s}/ui/star/{d}" hx-target="closest .bookmark" hx-swap="innerHTML" style="cursor:pointer">&#10029;</span></div>
    , .{
        @as([]const u8, if (bm.starred) "selected_star" else ""),
        @as([]const u8, if (bm.starred) "unstar" else "star"),
        app.base_path,
        bm.id,
    }) else "";
    return std.fmt.allocPrint(a,
        \\{s}{s}<div style="clear:both"></div>
    , .{ star, try renderDisplay(app, a, bm, editable) });
}

fn renderItem(app: *App, a: std.mem.Allocator, bm: models.Bookmark, editable: bool) ![]u8 {
    const cls: []const u8 = if (bm.shared) "bookmark" else "bookmark private";
    return std.fmt.allocPrint(a,
        \\<div class="{s}" id="bm-{d}">{s}</div>
    , .{ cls, bm.id, try renderInner(app, a, bm, editable) });
}

/// Bookmark list + earlier/later nav. Caller holds the db lock.
fn renderList(app: *App, a: std.mem.Allocator, f: Filter, public_only: bool) ![]u8 {
    const ids = blk: {
        if (f.q) |term| break :blk try db_mod.search(app.db, a, term, 100);
        break :blk try db_mod.listBookmarkIds(app.db, a, .{
            .tag = f.tag,
            .toread = if (f.toread) true else null,
            .starred = if (f.starred) true else null,
            .shared = f.shared,
            .untagged = f.untagged,
            .archived = f.archived,
            .limit = page_size,
            .offset = f.offset,
        });
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    // Pinboard shows the earlier/later nav above the list too.
    if (f.q == null and f.offset > 0) {
        const params = try filterParams(a, f);
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\<div id="bmarks_page_nav"><a class="next_prev" href="{s}/?offset={d}{s}">&laquo; later</a></div>
        , .{ app.base_path, @max(f.offset - page_size, 0), params }));
    }

    if (ids.len == 0) {
        try out.appendSlice(a, "<p class=\"faint\">no bookmarks</p>");
    } else {
        for (ids) |id| {
            const bm = (try db_mod.getBookmark(app.db, a, id)) orelse continue;
            if (public_only and !bm.shared) continue;
            // FTS results are unscoped; enforce the owner filter here too.
            if (f.user_id) |u| {
                if (bm.user_id != u) continue;
            }
            try out.appendSlice(a, try renderItem(app, a, bm, !public_only));
        }
    }

    // Search results are a single page; list pages get earlier/later nav.
    if (f.q == null) {
        const params = try filterParams(a, f);
        try out.appendSlice(a, "<div style=\"clear:both\"></div><div id=\"nextprev\">");
        if (f.offset > 0) {
            const later = @max(f.offset - page_size, 0);
            try out.appendSlice(a, try std.fmt.allocPrint(a,
                \\<a class="next_prev" href="{s}/?offset={d}{s}">&laquo; later</a>
            , .{ app.base_path, later, params }));
        }
        if (ids.len == page_size) {
            try out.appendSlice(a, try std.fmt.allocPrint(a,
                \\<a class="next_prev" href="{s}/?offset={d}{s}">earlier &raquo;</a>
            , .{ app.base_path, f.offset + page_size, params }));
        }
        try out.appendSlice(a, "</div>");
    }
    return out.toOwnedSlice(a);
}

/// Tags co-occurring with `tag` on one user's bookmarks. Caller holds the db lock.
fn renderRelatedTags(app: *App, a: std.mem.Allocator, tag: []const u8, user_id: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var st = try app.db.prepare(
        \\SELECT t2.tag, count(*) c FROM tag t1
        \\JOIN tag t2 ON t2.bookmark_id=t1.bookmark_id
        \\JOIN bookmark b ON b.id=t1.bookmark_id
        \\WHERE t1.tag=?1 AND t2.tag<>?1 AND b.user_id=?2
        \\GROUP BY t2.tag ORDER BY c DESC, t2.tag LIMIT 100;
    );
    defer st.finalize();
    st.bindText(1, tag);
    st.bindInt(2, user_id);
    try out.appendSlice(a, "<p><b>related tags</b></p><div id=\"tag_cloud\">");
    var n: usize = 0;
    while (try st.step()) : (n += 1) {
        const t = try a.dupe(u8, st.columnText(0));
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\<a class="tag" href="{s}/?tag={s}">{s}</a>
            \\
        , .{ app.base_path, try urlEncode(a, t), try esc(a, t) }));
    }
    try out.appendSlice(a, "</div>");
    if (n == 0) return try a.dupe(u8, "");
    return out.toOwnedSlice(a);
}

/// One user's tag cloud. Caller holds the db lock.
fn renderTagCloud(app: *App, a: std.mem.Allocator, user_id: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    // Alphabetical like Pinboard's cloud (the API keeps count-ordered tags).
    var st = try app.db.prepare(
        \\SELECT t.tag, count(*) FROM tag t JOIN bookmark b ON b.id=t.bookmark_id
        \\WHERE b.user_id=?1 GROUP BY t.tag ORDER BY t.tag COLLATE NOCASE;
    );
    defer st.finalize();
    st.bindInt(1, user_id);
    try out.appendSlice(a, "<div id=\"tag_cloud\">");
    while (try st.step()) {
        const tag = try a.dupe(u8, st.columnText(0));
        const n = st.columnInt(1);
        // Pinboard scales tag size with use and fades rare tags.
        const cls: []const u8 = if (n >= 150) " tc1" else if (n >= 80) " tc2" else if (n >= 40) " tc3" else if (n <= 3) " tf" else "";
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\<a class="tag{s}" href="{s}/?tag={s}">{s}</a>
            \\
        , .{ cls, app.base_path, try urlEncode(a, tag), try esc(a, tag) }));
    }
    try out.appendSlice(a, "</div>");
    return out.toOwnedSlice(a);
}

const pin_svg =
    \\<svg class="pin_logo" width="18" height="18" viewBox="0 0 24 24" style="vertical-align:-3px"><path fill="#6495ed" d="M16 2l6 6-1.5 1.5-1-.5-4 4 .5 3-1.5 1.5-4-4-6 6-1-1 6-6-4-4L7 7l3 .5 4-4-.5-1z"/></svg>
;

const FilterKind = enum { all, private, public, unread, untagged, starred, archived };

fn activeFilter(f: Filter) FilterKind {
    if (f.shared) |s| return if (s) .public else .private;
    if (f.toread) return .unread;
    if (f.untagged) return .untagged;
    if (f.starred) return .starred;
    if (f.archived) return .archived;
    return .all;
}

fn filterLink(a: std.mem.Allocator, base: []const u8, query: []const u8, label: []const u8, selected: bool) ![]u8 {
    const cls: []const u8 = if (selected) "filter selected" else "filter";
    return std.fmt.allocPrint(a,
        \\<a class="{s}" href="{s}/{s}">{s}</a>
    , .{ cls, base, query, label });
}

/// "<user> [+ tag] <count>" plus optional filter links, as one bar div.
fn renderFilterBar(a: std.mem.Allocator, base: []const u8, handle: []const u8, f: Filter, total: i64, show_filters: bool) ![]u8 {
    const active = activeFilter(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\<div id="filter_bar">
        \\<a class="uname" href="{s}/u:{s}">{s}</a>
    , .{ base, try urlEncode(a, handle), try esc(a, handle) }));
    if (f.tag) |t| {
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\ + <a class="tag" href="{s}/?tag={s}">{s}</a>
        , .{ base, try urlEncode(a, t), try esc(a, t) }));
    }
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\ <span class="faint">{d}</span>
    , .{total}));
    if (show_filters) {
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\ &nbsp;&nbsp;
            \\{s} &#8231;
            \\{s} &#8231;
            \\{s} &#8231;
            \\{s} &#8231;
            \\{s} &#8231;
            \\{s} &#8231;
            \\{s}
        , .{
            try filterLink(a, base, "", "all", active == .all),
            try filterLink(a, base, "?private=1", "private", active == .private),
            try filterLink(a, base, "?public=1", "public", active == .public),
            try filterLink(a, base, "?toread=1", "unread", active == .unread),
            try filterLink(a, base, "?untagged=1", "untagged", active == .untagged),
            try filterLink(a, base, "?starred=1", "starred", active == .starred),
            try filterLink(a, base, "?archived=1", "archived", active == .archived),
        }));
    }
    try out.appendSlice(a, "</div>");
    return out.toOwnedSlice(a);
}

/// filter_bar may be empty (no bar).
fn pageShell(a: std.mem.Allocator, base: []const u8, main_html: []const u8, right_html: []const u8, search_q: []const u8, filter_bar: []const u8, logged_in: bool, show_search: bool, st: Settings) ![]u8 {

    const search_form = if (show_search) try std.fmt.allocPrint(a,
        \\<form action="{s}/" method="get"><input type="search" name="q" placeholder="" value="{s}"
        \\  hx-get="{s}/ui/list" hx-trigger="keyup changed delay:300ms" hx-target="#bookmarks">
        \\<br><button class="search_btn" type="submit">search</button></form>
    , .{ base, search_q, base }) else "";

    const sys_link: []const u8 = if (st.admin) try std.fmt.allocPrint(a,
        \\<a href="{s}/system">system</a> &#8231;
    , .{base}) else "";
    const menu = if (logged_in) try std.fmt.allocPrint(a,
        \\{s}
        \\<a href="{s}/add">add url</a> &#8231;
        \\<a href="{s}/setup">setup</a> &#8231;
        \\<form style="display:inline" method="post" action="{s}/ui/logout"><button class="linklike" type="submit">log out</button></form>
    , .{ sys_link, base, base, base }) else try std.fmt.allocPrint(a,
        \\<a href="{s}/login">log in</a>
    , .{base});

    return std.fmt.allocPrint(a,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<meta name="color-scheme" content="light dark">
        \\<title>vinboard</title>
        \\<link rel="stylesheet" href="{s}/static/style.css">
        \\<script src="https://unpkg.com/htmx.org@2.0.3"></script>
        \\</head>
        \\<body style="font-size:{d}px">
        \\<div id="content">
        \\<div id="banner">
        \\<div id="logo">{s} <a id="pinboard_name" href="{s}/">vinboard</a></div>
        \\<div id="top_menu">{s}</div>
        \\<div style="clear:both"></div>
        \\</div>
        \\{s}
        \\<div id="main_column"><div id="bookmarks">{s}</div></div>
        \\<div id="right_bar">{s}{s}</div>
        \\<div id="footer"></div>
        \\</div>
        \\{s}
        \\</body>
        \\</html>
    , .{ base, st.font_size, pin_svg, base, menu, filter_bar, main_html, search_form, right_html, tag_js });
}

pub fn index(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    var f = try parseFilter(req);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);

    const uid = sessionUserId(app, req);
    const logged_in = uid != null;
    const st = if (uid) |u| loadSettings(app, a, u) else Settings{};
    if (logged_in) f.user_id = uid.? else f.shared = true; // own view vs public-only

    const list_html = renderList(app, a, f, !logged_in) catch |e| return serverError(res, e);
    // Tag cloud reveals private data; logged-out gets the list only.
    const cloud = if (!logged_in) "" else if (f.tag) |t| blk: {
        const related = renderRelatedTags(app, a, t, uid.?) catch |e| return serverError(res, e);
        break :blk try std.fmt.allocPrint(a,
            \\{s}
            \\<p style="margin-top:1em"><b>rename tag</b></p>
            \\<form method="post" action="{s}/ui/tag/rename">
            \\<input type="hidden" name="from" value="{s}">
            \\<input type="text" name="to" value="{s}" required>
            \\<button type="submit">rename</button>
            \\</form>
            \\<form method="post" action="{s}/ui/tag/delete" onsubmit="return confirm('"'"'Remove this tag from all bookmarks?'"'"')" style="margin-top:6px">
            \\<input type="hidden" name="from" value="{s}">
            \\<button type="submit">delete tag</button>
            \\</form>
        , .{ related, app.base_path, try esc(a, t), try esc(a, t), app.base_path, try esc(a, t) });
    } else renderTagCloud(app, a, uid.?) catch |e| return serverError(res, e);
    const bar = if (logged_in) blk: {
        const handle = (db_mod.getUserHandle(app.db, a, uid.?) catch |e| return serverError(res, e)) orelse "?";
        const total = db_mod.countFiltered(app.db, a, listFilterOf(f)) catch |e| return serverError(res, e);
        break :blk try renderFilterBar(a, app.base_path, handle, f, total, true);
    } else "";

    const search_q = if (f.q) |q| try esc(a, q) else "";
    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, list_html, cloud, search_q, bar, logged_in, true, st);
}

fn listFilterWithPage(f: Filter) db_mod.ListFilter {
    var lf = listFilterOf(f);
    lf.limit = page_size;
    lf.offset = f.offset;
    return lf;
}

/// db-layer filter matching what renderList queries.
fn listFilterOf(f: Filter) db_mod.ListFilter {
    return .{
        .tag = f.tag,
        .toread = if (f.toread) true else null,
        .starred = if (f.starred) true else null,
        .shared = f.shared,
        .untagged = f.untagged,
        .archived = f.archived,
        .user_id = f.user_id,
    };
}

/// /u:<handle> - a user's page; public view for visitors, full for the owner.
fn fallbackRoute(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    var path = req.url.path;
    if (app.base_path.len > 0 and std.mem.startsWith(u8, path, app.base_path)) path = path[app.base_path.len..];
    if (!std.mem.startsWith(u8, path, "/u:")) return notFound(res);
    const handle = path[3..];

    var f = try parseFilter(req);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);

    const user = (db_mod.getUserByHandle(app.db, a, handle) catch |e| return serverError(res, e)) orelse return notFound(res);
    const uid = sessionUserId(app, req);
    const st = if (uid) |u| loadSettings(app, a, u) else Settings{};
    const own = uid != null and uid.? == user.id;
    f.user_id = user.id;
    if (!own) f.shared = true;

    const list_html = renderList(app, a, f, !own) catch |e| return serverError(res, e);
    const cloud = if (!own) "" else if (f.tag) |t|
        renderRelatedTags(app, a, t, user.id) catch |e| return serverError(res, e)
    else
        renderTagCloud(app, a, user.id) catch |e| return serverError(res, e);
    const total = db_mod.countFiltered(app.db, a, listFilterOf(f)) catch |e| return serverError(res, e);
    const bar = try renderFilterBar(a, app.base_path, user.handle, f, total, own);

    const search_q = if (f.q) |q| try esc(a, q) else "";
    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, list_html, cloud, search_q, bar, uid != null, true, st);
}

pub fn listFragment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    var f = try parseFilter(req);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const frag_uid = sessionUserId(app, req);
    if (frag_uid) |u| f.user_id = u else f.shared = true;
    const body = renderList(app, res.arena, f, frag_uid == null) catch |e| return serverError(res, e);
    res.content_type = httpz.ContentType.HTML;
    res.body = body;
}

pub fn itemFragment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    const bm = (ownedBookmark(app, res.arena, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    res.content_type = httpz.ContentType.HTML;
    res.body = try renderInner(app, res.arena, bm, true);
}

pub fn editForm(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    const bm = (ownedBookmark(app, a, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);

    var tags_str: std.ArrayList(u8) = .empty;
    for (bm.tags, 0..) |t, i| {
        if (i > 0) try tags_str.append(a, ' ');
        try tags_str.appendSlice(a, t);
    }

    res.content_type = httpz.ContentType.HTML;
    res.body = try std.fmt.allocPrint(a,
        \\<form class="edit_form" hx-post="{s}/ui/edit/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">
        \\<p>url<br><input type="text" name="url" value="{s}"></p>
        \\<p>title<br><textarea name="title" rows="1">{s}</textarea></p>
        \\<p>description<br><textarea name="notes" rows="3">{s}</textarea></p>
        \\<p>tags<br><input type="text" name="tags" value="{s}"></p>
        \\<p><label><input type="checkbox" name="private"{s}> private</label>
        \\   <label><input type="checkbox" name="toread"{s}> read later</label></p>
        \\<p><button type="submit">save</button>
        \\   <a class="edit" href="#" hx-get="{s}/ui/item/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">cancel</a></p>
        \\</form>
    , .{
        app.base_path,        id,
        try esc(a, bm.url),   try esc(a, bm.title),
        try esc(a, bm.notes), try esc(a, tags_str.items),
        checked(!bm.shared),  checked(bm.toread),
        app.base_path,        id,
    });
}

fn checked(on: bool) []const u8 {
    return if (on) " checked" else "";
}

/// A title is a single line; a pasted one may not be. Newlines become
/// spaces so the stored title matches what the field shows.
fn oneLine(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\r\n") == null) return s;
    const out = try a.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\r' or c.* == '\n') c.* = ' ';
    }
    return out;
}

/// The saved value, or the incoming one where nothing was saved.
fn pick(saved: []const u8, incoming: []const u8) []const u8 {
    return if (saved.len > 0) saved else incoming;
}

fn joinTags(a: std.mem.Allocator, tags: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (tags, 0..) |t, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, t);
    }
    return out.toOwnedSlice(a);
}

fn splitTags(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |t| try list.append(a, t);
    return list.toOwnedSlice(a);
}

pub fn editSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    const fd = try req.formData();

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    _ = (ownedBookmark(app, a, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    const new_url = try trackers.clean(a, fd.get("url") orelse "");
    db_mod.editBookmark(app.db, a, id, .{
        .url = if (new_url.len > 0) new_url else null,
        .title = try oneLine(a, fd.get("title") orelse ""),
        .notes = fd.get("notes") orelse "",
        .tags = try splitTags(a, fd.get("tags") orelse ""),
        .shared = fd.get("private") == null,
        .toread = fd.get("toread") != null,
    }, db_mod.nowUnix()) catch |e| return serverError(res, e);

    const bm = (db_mod.getBookmark(app.db, a, id) catch |e| return serverError(res, e)) orelse return notFound(res);
    res.content_type = httpz.ContentType.HTML;
    res.body = try renderInner(app, a, bm, true);
}

pub fn starToggle(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    const bm = (ownedBookmark(app, a, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    db_mod.updateBookmark(app.db, id, .{ .starred = !bm.starred }, db_mod.nowUnix()) catch |e| return serverError(res, e);
    const updated = (db_mod.getBookmark(app.db, a, id) catch |e| return serverError(res, e)) orelse return notFound(res);
    res.content_type = httpz.ContentType.HTML;
    res.body = try renderInner(app, a, updated, true);
}

pub fn markRead(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    _ = (ownedBookmark(app, a, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    db_mod.updateBookmark(app.db, id, .{ .toread = false }, db_mod.nowUnix()) catch |e| return serverError(res, e);
    const bm = (db_mod.getBookmark(app.db, a, id) catch |e| return serverError(res, e)) orelse return notFound(res);
    res.content_type = httpz.ContentType.HTML;
    res.body = try renderInner(app, a, bm, true);
}

pub fn deleteSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    _ = (ownedBookmark(app, res.arena, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    db_mod.deleteBookmark(app.db, id) catch |e| return serverError(res, e);
    res.status = 200;
    res.body = "";
}

pub fn addPage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const qs = try req.query();
    const url = try trackers.clean(a, qs.get("url") orelse "");
    const popup = qs.get("popup") != null;

    var st = Settings{};
    // The bookmark this url already has, if any: the form opens on top of
    // it rather than on an empty slate.
    var prev: ?models.Bookmark = null;
    var uid: ?i64 = null;
    {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        const maybe_uid = sessionUserId(app, req);
        uid = maybe_uid;
        if (maybe_uid) |u| {
            st = loadSettings(app, a, u);
            if (url.len > 0) {
                if (db_mod.findIdByUrlFor(app.db, url, u) catch |e| return serverError(res, e)) |id| {
                    prev = db_mod.getBookmark(app.db, a, id) catch |e| return serverError(res, e);
                }
            }
        }
        if (maybe_uid == null) {
            // Bookmarklet popup lands here logged-out; bounce through the
            // login page and come back with the query intact.
            var path = req.url.path;
            if (app.base_path.len > 0 and std.mem.startsWith(u8, path, app.base_path)) path = path[app.base_path.len..];
            const next = if (req.url.query.len > 0)
                try std.fmt.allocPrint(a, "{s}{s}?{s}", .{ app.base_path, path, req.url.query })
            else
                try std.fmt.allocPrint(a, "{s}{s}", .{ app.base_path, path });
            res.status = 302;
            res.header("Location", try std.fmt.allocPrint(a, "{s}/login?next={s}", .{ app.base_path, try urlEncode(a, next) }));
            return;
        }
    }
    // What was saved before wins; the incoming values fill whatever it
    // left empty, so a re-add never drops what is already there and never
    // discards what the caller brought.
    const title = pick(if (prev) |b| b.title else "", qs.get("title") orelse "");
    const notes = pick(if (prev) |b| b.notes else "", qs.get("notes") orelse "");
    const tags = if (prev) |b| try joinTags(a, b.tags) else "";
    // A url saved before keeps its tags. Anything new has them fetched once
    // the form is on screen, because a decision takes about a second and the
    // popup should not wait for it.
    const suggest_js = if (prev == null and url.len > 0 and app.suggest.endpoint.len > 0)
        suggest_script
    else
        "";

    const callout = if (prev) |b| try std.fmt.allocPrint(a,
        \\<p class="prev_saved">previously saved on
        \\<span class="when" data-ts="{d}">{s}</span></p>
    , .{ b.created_at, try fmtDateTime(a, b.created_at) }) else "";

    const form = try std.fmt.allocPrint(a,
        \\<h1>add bookmark</h1>
        \\{s}
        \\<form class="edit_form" method="post" action="{s}/ui/add">
        \\<input type="hidden" name="popup" value="{s}">
        \\<p>url<br><input type="text" name="url" value="{s}" required></p>
        \\<p>title<br><textarea name="title" rows="1">{s}</textarea></p>
        \\<p>description<br><textarea name="notes" rows="3">{s}</textarea></p>
        \\<p>tags<br><input type="text" name="tags" value="{s}"></p>
        \\<p><label><input type="checkbox" name="private"{s}> private</label>
        \\   <label><input type="checkbox" name="toread"{s}> read later</label></p>
        \\<p><button type="submit">add</button></p>
        \\</form>
        \\{s}
    , .{
        callout,
        app.base_path,
        if (popup) "1" else "",
        try esc(a, url),
        try esc(a, title),
        try esc(a, notes),
        try esc(a, tags),
        checked(if (prev) |b| !b.shared else true),
        checked(if (prev) |b| b.toread else false),
        suggest_js,
    });

    res.content_type = httpz.ContentType.HTML;
    if (popup) {
        // Bookmarklet popup: bare page, no banner or sidebar.
        res.body = try std.fmt.allocPrint(a,
            \\<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
            \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\<meta name="color-scheme" content="light dark">
            \\<title>add to vinboard</title>
            \\<link rel="stylesheet" href="{s}/static/style.css"></head>
            \\<body style="font-size:{d}px"><div id="content">{s}</div>{s}</body></html>
        , .{ app.base_path, st.font_size, form, tag_js });
    } else {
        res.body = try pageShell(a, app.base_path, form, "", "", "", true, false, st);
    }
}

pub fn addSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const url = try trackers.clean(a, fd.get("url") orelse return badRequest(res));
    if (url.len == 0) return badRequest(res);
    const title = try oneLine(a, fd.get("title") orelse "");
    const notes = fd.get("notes") orelse "";
    var tags = try splitTags(a, fd.get("tags") orelse "");
    // The form can be submitted with the tags field cleared, so ask the
    // model before the write rather than leave the bookmark untagged.
    if (tags.len == 0) {
        app.db_mutex.lockUncancelable(app.io);
        const uid = sessionUserId(app, req);
        app.db_mutex.unlock(app.io);
        if (uid) |u| tags = suggest_mod.forBookmark(a, app.io, app.suggest, app.db, app.db_mutex, u, title, url, notes);
    }
    const patch = db_mod.Patch{
        .title = title,
        .notes = notes,
        .tags = tags,
        .shared = fd.get("private") == null,
        .toread = fd.get("toread") != null,
    };

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    const now = db_mod.nowUnix();
    // Re-adding an existing url updates it, matching Pinboard.
    if (db_mod.findIdByUrlFor(app.db, url, owner_uid) catch |e| return serverError(res, e)) |id| {
        db_mod.editBookmark(app.db, a, id, patch, now) catch |e| return serverError(res, e);
    } else {
        const id = db_mod.insertBookmark(app.db, .{
            .url = url,
            .title = patch.title.?,
            .notes = patch.notes.?,
            .tags = patch.tags.?,
            .shared = patch.shared.?,
            .toread = patch.toread.?,
        }, now, owner_uid) catch |e| return serverError(res, e);
        _ = id;
        db_mod.enqueueArchive(app.db, url) catch {};
    }

    if (fd.get("popup")) |p| {
        if (p.len > 0) {
            res.content_type = httpz.ContentType.HTML;
            res.body = "<script>window.close()</script>saved.";
            return;
        }
    }
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/", .{app.base_path}));
}

pub fn setupPage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const session_uid = blk: {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        break :blk sessionUserId(app, req);
    };
    const logged_in = session_uid != null;
    const st = blk: {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        break :blk if (session_uid) |u| loadSettings(app, a, u) else Settings{};
    };
    const qs = try req.query();
    const pw_notice: []const u8 = if (qs.get("pwok") != null) "<p><b>password changed.</b></p>" else "";
    const host = req.header("host") orelse "localhost:4670";
    const scheme: []const u8 = if (std.mem.startsWith(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.")) "http" else "https";
    const add_url = try std.fmt.allocPrint(a, "{s}://{s}{s}/add", .{ scheme, host, app.base_path });

    const bookmarklet = try std.fmt.allocPrint(a,
        \\javascript:q=location.href;p=document.title;void(open('{s}?popup=1&url='+encodeURIComponent(q)+'&title='+encodeURIComponent(p),'vinboard','toolbar=no,width=700,height=400'));
    , .{add_url});

    const pw_form: []const u8 = if (logged_in) try std.fmt.allocPrint(a,
        \\<h2>change password</h2>
        \\{s}
        \\<form class="edit_form" method="post" action="{s}/ui/password">
        \\<p>current password<br><input type="password" name="current" required></p>
        \\<p>new password<br><input type="password" name="new" required minlength="8"></p>
        \\<p>repeat new password<br><input type="password" name="repeat" required minlength="8"></p>
        \\<p><button class="search_btn" type="submit">change password</button></p>
        \\</form>
    , .{ pw_notice, app.base_path }) else "";

    const token_section: []const u8 = if (session_uid) |uid| blk: {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        const handle = (db_mod.getUserHandle(app.db, a, uid) catch |e| return serverError(res, e)) orelse "?";
        const token = (db_mod.getApiToken(app.db, a, uid) catch |e| return serverError(res, e)) orelse "";
        const shown = if (token.len > 0)
            try std.fmt.allocPrint(a,
                \\<p><code>{s}:{s}</code></p>
            , .{ try esc(a, handle), try esc(a, token) })
        else
            "<p class=\"faint\">no token yet</p>";
        break :blk try std.fmt.allocPrint(a,
            \\<h2>api token</h2>
            \\{s}
            \\<p class="faint">Use it as a bearer token: Authorization: Bearer {s}:TOKEN</p>
            \\<form method="post" action="{s}/ui/token"><button class="search_btn" type="submit">generate new token</button></form>
        , .{ shown, try esc(a, handle), app.base_path });
    } else "";

    const display_section: []const u8 = if (logged_in) try std.fmt.allocPrint(a,
        \\<h2>display</h2>
        \\<form class="edit_form" method="post" action="{s}/ui/fontsize">
        \\<p>font size (px)</p>
        \\<p class="stepper">
        \\<button type="button" onclick="fsStep(-1)">&minus;</button>
        \\<input type="number" name="size" id="fs_input" min="11" max="24" value="{d}">
        \\<button type="button" onclick="fsStep(1)">+</button>
        \\&nbsp;<button type="submit">save</button></p>
        \\</form>
        \\<script>function fsStep(d){{const i=document.getElementById('fs_input');
        \\i.value=Math.min(24,Math.max(11,(parseInt(i.value)||15)+d));
        \\document.body.style.fontSize=i.value+'px';}}</script>
    , .{ app.base_path, st.font_size }) else "";

    const hn_section: []const u8 = if (session_uid) |uid| blk: {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        const handle = (db_mod.getUserHandle(app.db, a, uid) catch |e| return serverError(res, e)) orelse "?";
        const token = (db_mod.getApiToken(app.db, a, uid) catch |e| return serverError(res, e)) orelse "";
        if (token.len == 0) break :blk "";
        const enc_handle = try urlEncode(a, handle);
        const enc_token = try urlEncode(a, token);
        break :blk try std.fmt.allocPrint(a,
            \\<h2>HN Legible</h2>
            \\<p class="faint">Configures the <a href="https://hn.ptpf29qr6x.workers.dev" target="_blank">HN Legible frontend</a> to sync favorites into vinboard.</p>
            \\<p>
            \\<a class="btn" href="https://hn.ptpf29qr6x.workers.dev/setup?token={s}%3A{s}&amp;host=vinboard" target="_blank">setup HN Legible (workers)</a>
            \\<a class="btn" href="https://uiuo.nl/hn/#setup?token={s}%3A{s}&amp;workers=cors.ptpf29qr6x.workers.dev&amp;host=vinboard" target="_blank">setup HN Legible (js)</a>
            \\</p>
        , .{ enc_handle, enc_token, enc_handle, enc_token });
    } else "";

    const shortcut_section: []const u8 = if (logged_in) try std.fmt.allocPrint(a,
        \\<h2>shortcut</h2>
        \\<p class="faint">iOS/macOS share-sheet shortcut with your current api token baked in; posts the shared page to vinboard.</p>
        \\<form method="get" action="{s}/vinboard.shortcut"><button type="submit">download shortcut</button></form>
    , .{app.base_path}) else "";

    const main_html = try std.fmt.allocPrint(a,
        \\<h1>setup</h1>
        \\<h2>bookmarklet</h2>
        \\<p>Drag this link to your bookmarks bar:</p>
        \\<p><a href="{s}">add to vinboard</a></p>
        \\<p class="faint">It opens a popup with the current page's url and title prefilled.</p>
        \\{s}
        \\{s}
        \\{s}
        \\{s}
        \\{s}
    , .{ try esc(a, bookmarklet), shortcut_section, hn_section, display_section, token_section, pw_form });

    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, main_html, "", "", "", logged_in, false, st);
}

pub fn passwordSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const current = fd.get("current") orelse return badRequest(res);
    const new_pw = fd.get("new") orelse return badRequest(res);
    const repeat = fd.get("repeat") orelse return badRequest(res);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = sessionUserId(app, req) orelse return loginRequired(res);
    const handle = (db_mod.getUserHandle(app.db, a, uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    const user = (db_mod.getUserByHandle(app.db, a, handle) catch |e| return serverError(res, e)) orelse return notFound(res);

    if (!auth.verifyPassword(user.password_hash, current)) return passwordError(res, "current password is wrong");
    if (new_pw.len < 8) return passwordError(res, "new password must be at least 8 characters");
    if (!std.mem.eql(u8, new_pw, repeat)) return passwordError(res, "new passwords do not match");

    var buf: [auth.hash_buf_len]u8 = undefined;
    const hash = auth.hashPassword(new_pw, &buf, app.io) catch |e| return serverError(res, e);
    db_mod.setUserPassword(app.db, handle, hash) catch |e| return serverError(res, e);

    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/setup?pwok=1", .{app.base_path}));
}

/// Signed share-sheet shortcut with the caller's api token baked in.
pub fn shortcutDownload(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    var cred: []const u8 = "";
    {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        const uid = sessionUserId(app, req) orelse return loginRequired(res);
        const handle = (db_mod.getUserHandle(app.db, a, uid) catch |e| return serverError(res, e)) orelse return notFound(res);
        const token = (db_mod.getApiToken(app.db, a, uid) catch |e| return serverError(res, e)) orelse "";
        if (token.len == 0) {
            res.status = 400;
            res.content_type = httpz.ContentType.HTML;
            res.body = "<p>generate an api token first. <a href=\"setup\">back</a></p>";
            return;
        }
        cred = try std.fmt.allocPrint(a, "{s}:{s}", .{ handle, token });
    }
    const xml = shortcutXml(a, cred) catch |e| return serverError(res, e);
    const signed = signShortcut(app, a, xml, app.shortcut_out) catch |e| return serverError(res, e);
    if (app.shortcut_out.len > 0) {
        // Freshly written for the static server; a redirect there serves it
        // with no Content-Type at all, which is what makes iOS Safari offer
        // "Open in Shortcuts" instead of downloading.
        res.status = 302;
        res.header("Location", "/vinboard.shortcut");
        return;
    }
    res.status = 200;
    res.body = signed;
}

const shortcut_template = @embedFile("shortcut-template.xml");

/// The unsigned shortcut plist with credential CRED baked in.
fn shortcutXml(a: std.mem.Allocator, cred: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, shortcut_template, "__VINBOARD_AUTH__", try esc(a, cred));
}

/// Sign the shortcut plist XML.  With OUT set, the signed shortcut replaces
/// the file at OUT atomically and the result is empty; otherwise the signed
/// bytes are returned.
fn signShortcut(app: *App, a: std.mem.Allocator, xml: []const u8, out: []const u8) ![]u8 {
    const io = app.io;
    const cwd = std.Io.Dir.cwd();
    var buf: [20]u8 = undefined;
    const tmp = try std.fmt.allocPrint(a, "/tmp/vinboard-shortcut-{s}", .{auth.newApiToken(&buf, io)});
    try cwd.createDirPath(io, tmp);
    defer cwd.deleteTree(io, tmp) catch {};
    const in_path = try std.fmt.allocPrint(a, "{s}/in.shortcut", .{tmp});
    try cwd.writeFile(io, .{ .sub_path = in_path, .data = xml });
    // Signed next to OUT, so the final rename stays on one filesystem.
    const out_path = if (out.len > 0)
        try std.fmt.allocPrint(a, "{s}.{s}.tmp", .{ out, buf })
    else
        try std.fmt.allocPrint(a, "{s}/out.shortcut", .{tmp});
    const result = try std.process.run(app.gpa, io, .{
        .argv = &.{ "shortcuts", "sign", "-m", "anyone", "-i", in_path, "-o", out_path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    app.gpa.free(result.stdout);
    app.gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        if (out.len > 0) cwd.deleteFile(io, out_path) catch {};
        return error.ShortcutSignFailed;
    }
    if (out.len > 0) {
        try cwd.setFilePermissions(io, out_path, .fromMode(0o644), .{});
        try cwd.rename(out_path, cwd, out, io);
        return &.{};
    }
    const signed = try cwd.readFileAlloc(io, out_path, a, .limited(4 * 1024 * 1024));
    if (signed.len == 0) return error.ShortcutSignFailed;
    return signed;
}

test "shortcut xml carries the escaped credential" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const xml = try shortcutXml(arena.allocator(), "me&co:ABC123");
    try std.testing.expect(std.mem.indexOf(u8, xml, "__VINBOARD_AUTH__") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "Bearer me&amp;co:ABC123") != null);
}

test "every shortcut action carries a uuid" {
    // Shortcuts keys its saved permission grants by action uuid; an action
    // without one gets a fresh uuid per run and never matches its grant.
    const actions = std.mem.count(u8, shortcut_template, "<key>WFWorkflowActionIdentifier</key>");
    const uuids = std.mem.count(u8, shortcut_template, "<key>UUID</key>");
    try std.testing.expect(actions > 0);
    try std.testing.expectEqual(actions, uuids);
}

pub fn tokenSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = sessionUserId(app, req) orelse return loginRequired(res);
    var buf: [20]u8 = undefined;
    const token = auth.newApiToken(&buf, app.io);
    db_mod.setApiToken(app.db, uid, token) catch |e| return serverError(res, e);
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/setup", .{app.base_path}));
}

/// Rename a tag across the user's bookmarks; merges into an existing tag.
fn countArchive(app: *App, status: []const u8) !i64 {
    var q = try app.db.prepare("SELECT count(*) FROM archive WHERE status=?;");
    defer q.finalize();
    q.bindText(1, status);
    _ = try q.step();
    return q.columnInt(0);
}

pub fn tagRename(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const from = std.mem.trim(u8, fd.get("from") orelse return badRequest(res), " ");
    const to = std.mem.trim(u8, fd.get("to") orelse return badRequest(res), " ");
    if (from.len == 0 or to.len == 0 or std.mem.indexOfScalar(u8, to, ' ') != null) return badRequest(res);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = sessionUserId(app, req) orelse return loginRequired(res);

    if (!std.mem.eql(u8, from, to)) {
        var ids: std.ArrayList(i64) = .empty;
        {
            var q = app.db.prepare(
                \\SELECT t.bookmark_id FROM tag t JOIN bookmark b ON b.id=t.bookmark_id
                \\WHERE t.tag=?1 AND b.user_id=?2;
            ) catch |e| return serverError(res, e);
            defer q.finalize();
            q.bindText(1, from);
            q.bindInt(2, uid);
            while (q.step() catch |e| return serverError(res, e)) try ids.append(a, q.columnInt(0));
        }
        for (ids.items) |bid| {
            var ins = app.db.prepare("INSERT OR IGNORE INTO tag(bookmark_id,tag) VALUES (?,?);") catch |e| return serverError(res, e);
            ins.bindInt(1, bid);
            ins.bindText(2, to);
            _ = ins.step() catch |e| return serverError(res, e);
            ins.finalize();
            var del = app.db.prepare("DELETE FROM tag WHERE bookmark_id=? AND tag=?;") catch |e| return serverError(res, e);
            del.bindInt(1, bid);
            del.bindText(2, from);
            _ = del.step() catch |e| return serverError(res, e);
            del.finalize();
        }
        // Tags live in the fts index too.
        for (ids.items) |bid| db_mod.reindexBookmark(app.db, bid) catch |e| return serverError(res, e);
    }

    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/?tag={s}", .{ app.base_path, try urlEncode(a, to) }));
}

/// Remove a tag from all of the user's bookmarks.
pub fn tagDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const from = std.mem.trim(u8, fd.get("from") orelse return badRequest(res), " ");
    if (from.len == 0) return badRequest(res);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = sessionUserId(app, req) orelse return loginRequired(res);

    var ids: std.ArrayList(i64) = .empty;
    {
        var q = app.db.prepare(
            \\SELECT t.bookmark_id FROM tag t JOIN bookmark b ON b.id=t.bookmark_id
            \\WHERE t.tag=?1 AND b.user_id=?2;
        ) catch |e| return serverError(res, e);
        defer q.finalize();
        q.bindText(1, from);
        q.bindInt(2, uid);
        while (q.step() catch |e| return serverError(res, e)) try ids.append(a, q.columnInt(0));
    }
    for (ids.items) |bid| {
        var del = app.db.prepare("DELETE FROM tag WHERE bookmark_id=? AND tag=?;") catch |e| return serverError(res, e);
        del.bindInt(1, bid);
        del.bindText(2, from);
        _ = del.step() catch |e| return serverError(res, e);
        del.finalize();
        db_mod.reindexBookmark(app.db, bid) catch |e| return serverError(res, e);
    }

    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/", .{app.base_path}));
}

pub fn fontSizeSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const size_s = fd.get("size") orelse return badRequest(res);
    const size = std.fmt.parseInt(i64, size_s, 10) catch return badRequest(res);
    if (size < 11 or size > 24) return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = sessionUserId(app, req) orelse return loginRequired(res);
    saveSettingInt(app, a, uid, "font_size", size) catch |e| return serverError(res, e);
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/setup", .{app.base_path}));
}

fn passwordError(res: *httpz.Response, msg: []const u8) !void {
    res.status = 400;
    res.content_type = httpz.ContentType.HTML;
    res.body = try std.fmt.allocPrint(res.arena, "<p>{s}. <a href=\"setup\">back</a></p>", .{msg});
}

/// Tag names (alphabetical) for autocomplete; session-only.
pub fn tagsJson(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const tags_uid = sessionUserId(app, req) orelse return loginRequired(res);
    var st = app.db.prepare(
        \\SELECT DISTINCT t.tag FROM tag t JOIN bookmark b ON b.id=t.bookmark_id
        \\WHERE b.user_id=?1 ORDER BY t.tag COLLATE NOCASE;
    ) catch |e| return serverError(res, e);
    defer st.finalize();
    st.bindInt(1, tags_uid);
    var arr: std.ArrayList([]const u8) = .empty;
    while (st.step() catch |e| return serverError(res, e)) {
        try arr.append(a, try a.dupe(u8, st.columnText(0)));
    }
    res.status = 200;
    try res.json(arr.items, .{});
}

/// Tags the model suggests for a url the visitor is about to save. Answers
/// with an empty list rather than an error, so a form never breaks over it.
pub fn suggestJson(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const qs = try req.query();
    const url = try trackers.clean(a, qs.get("url") orelse "");

    app.db_mutex.lockUncancelable(app.io);
    const uid = sessionUserId(app, req);
    app.db_mutex.unlock(app.io);

    const tags: []const []const u8 = if (uid != null and url.len > 0)
        suggest_mod.forBookmark(a, app.io, app.suggest, app.db, app.db_mutex, uid.?, qs.get("title") orelse "", url, qs.get("notes") orelse "")
    else
        &.{};
    try res.json(.{ .tags = tags }, .{});
}

fn loginRequired(res: *httpz.Response) !void {
    res.status = 401;
    res.body = "login required";
}

pub fn loginPage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const qs = try req.query();
    const next = qs.get("next") orelse "";
    const cfg = blk: {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        break :blk loadOidcConfig(app, a);
    };
    var form: std.ArrayList(u8) = .empty;
    try form.appendSlice(a, "<h1>log in</h1>\n");
    if (cfg.enabled()) {
        try form.appendSlice(a, try std.fmt.allocPrint(a,
            \\<p><a href="{s}/oidc/login"><button type="button">log in with sso</button></a></p>
            \\
        , .{app.base_path}));
    }
    if (cfg.builtinAllowed()) {
        try form.appendSlice(a, try std.fmt.allocPrint(a,
            \\<form class="edit_form" method="post" action="{s}/ui/login">
            \\<input type="hidden" name="next" value="{s}">
            \\<p>username<br><input type="text" name="handle" required></p>
            \\<p>password<br><input type="password" name="password" required></p>
            \\<p><button class="search_btn" type="submit">log in</button></p>
            \\</form>
            \\<p class="faint">no account? <a href="{s}/signup">sign up</a></p>
        , .{ app.base_path, try esc(a, next), app.base_path }));
    }
    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, form.items, "", "", "", false, false, .{});
}

/// OIDC settings from sysconf; arena-allocated strings.  Caller holds
/// the db lock.
fn loadOidcConfig(app: *App, a: std.mem.Allocator) oidc.Config {
    var cfg = oidc.Config{};
    if (db_mod.getSysconf(app.db, a, "oidc_mode") catch null) |v| cfg.mode = v;
    if (db_mod.getSysconf(app.db, a, "oidc_issuer") catch null) |v| cfg.issuer = v;
    if (db_mod.getSysconf(app.db, a, "oidc_client_id") catch null) |v| cfg.client_id = v;
    if (db_mod.getSysconf(app.db, a, "oidc_client_secret") catch null) |v| cfg.client_secret = v;
    if (db_mod.getSysconf(app.db, a, "oidc_redirect_uri") catch null) |v| cfg.redirect_uri = v;
    return cfg;
}

/// Redirect to the identity provider with a fresh state cookie.
pub fn oidcLogin(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const cfg = blk: {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        break :blk loadOidcConfig(app, a);
    };
    if (!cfg.enabled()) return notFound(res);
    var state_buf: [64]u8 = undefined;
    const state = auth.newSessionToken(&state_buf, app.io);
    const cookie_path = if (app.base_path.len > 0) app.base_path else "/";
    res.header("Set-Cookie", try std.fmt.allocPrint(a, "vb_oidc_state={s}; Path={s}; HttpOnly; SameSite=Lax; Max-Age=600", .{ state, cookie_path }));
    res.status = 302;
    res.header("Location", try oidc.authUrl(a, cfg, state));
}

/// Provider redirects back here; exchange the code, map claims to a
/// local user, start a session.
pub fn oidcCallback(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const qs = try req.query();
    const code = qs.get("code") orelse return badRequest(res);
    const state = qs.get("state") orelse return badRequest(res);
    const cookie = req.header("cookie") orelse return badRequest(res);
    const want = auth.cookieValue(cookie, "vb_oidc_state") orelse return badRequest(res);
    if (!std.mem.eql(u8, state, want)) return badRequest(res);

    const cfg = blk: {
        app.db_mutex.lockUncancelable(app.io);
        defer app.db_mutex.unlock(app.io);
        break :blk loadOidcConfig(app, a);
    };
    if (!cfg.enabled()) return notFound(res);

    // Network round-trip to the issuer; deliberately outside the db lock.
    const claims = oidc.exchangeCode(a, app.io, cfg, code) catch {
        res.status = 502;
        res.content_type = httpz.ContentType.HTML;
        res.body = "<p>sso sign-in failed. <a href=\"login\">try again</a></p>";
        return;
    };

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = oidcUserId(app, a, claims) catch |e| return serverError(res, e);

    var tok_buf: [64]u8 = undefined;
    const token = auth.newSessionToken(&tok_buf, app.io);
    db_mod.createSession(app.db, token, uid, db_mod.nowUnix() + 90 * 86400) catch |e| return serverError(res, e);
    const cookie_path = if (app.base_path.len > 0) app.base_path else "/";
    res.header("Set-Cookie", try std.fmt.allocPrint(a, "vb_session={s}; Path={s}; HttpOnly; SameSite=Lax; Max-Age=7776000", .{ token, cookie_path }));
    res.header("Set-Cookie", try std.fmt.allocPrint(a, "vb_oidc_state=; Path={s}; HttpOnly; SameSite=Lax; Max-Age=0", .{cookie_path}));
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/", .{app.base_path}));
}

/// Local user for OIDC claims: match by subject, else link an existing
/// user with the claimed handle, else create one.  Caller holds the db
/// lock.
fn oidcUserId(app: *App, a: std.mem.Allocator, claims: oidc.Claims) !i64 {
    if (try db_mod.userIdByOidcSub(app.db, claims.sub)) |uid| return uid;
    var buf: [32]u8 = undefined;
    const handle = oidc.proposeHandle(claims, &buf);
    if (try db_mod.getUserByHandle(app.db, a, handle)) |existing| {
        try db_mod.setUserOidcSub(app.db, existing.id, claims.sub);
        return existing.id;
    }
    const uid = (try db_mod.createUser(app.db, handle, "", db_mod.nowUnix())) orelse return error.UserCreateFailed;
    try db_mod.setUserOidcSub(app.db, uid, claims.sub);
    return uid;
}

/// Admin-only: save OIDC settings from the /system form.
pub fn oidcConfigSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = sessionUserId(app, req) orelse return loginRequired(res);
    if (!loadSettings(app, a, uid).admin) return notFound(res);

    const mode = fd.get("mode") orelse "builtin";
    if (!std.mem.eql(u8, mode, "builtin") and !std.mem.eql(u8, mode, "oidc") and !std.mem.eql(u8, mode, "both"))
        return badRequest(res);
    db_mod.setSysconf(app.db, "oidc_mode", mode) catch |e| return serverError(res, e);
    db_mod.setSysconf(app.db, "oidc_issuer", std.mem.trimEnd(u8, fd.get("issuer") orelse "", "/")) catch |e| return serverError(res, e);
    db_mod.setSysconf(app.db, "oidc_client_id", fd.get("client_id") orelse "") catch |e| return serverError(res, e);
    // Empty secret keeps the stored one, so the form can omit it.
    if (fd.get("client_secret")) |secret| {
        if (secret.len > 0) db_mod.setSysconf(app.db, "oidc_client_secret", secret) catch |e| return serverError(res, e);
    }
    db_mod.setSysconf(app.db, "oidc_redirect_uri", fd.get("redirect_uri") orelse "") catch |e| return serverError(res, e);
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/system", .{app.base_path}));
}

pub fn loginSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const handle = fd.get("handle") orelse return badRequest(res);
    const password = fd.get("password") orelse return badRequest(res);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    if (!loadOidcConfig(app, a).builtinAllowed()) return loginFailed(res);
    const user = (db_mod.getUserByHandle(app.db, a, handle) catch |e| return serverError(res, e)) orelse return loginFailed(res);
    if (!auth.verifyPassword(user.password_hash, password)) return loginFailed(res);

    var tok_buf: [64]u8 = undefined;
    const token = auth.newSessionToken(&tok_buf, app.io);
    const now = db_mod.nowUnix();
    db_mod.createSession(app.db, token, user.id, now + 90 * 86400) catch |e| return serverError(res, e);

    const cookie_path = if (app.base_path.len > 0) app.base_path else "/";
    res.header("Set-Cookie", try std.fmt.allocPrint(a, "vb_session={s}; Path={s}; HttpOnly; SameSite=Lax; Max-Age=7776000", .{ token, cookie_path }));
    res.status = 302;
    // Only same-site destinations; anything else falls back to the front page.
    const next = fd.get("next") orelse "";
    if (next.len > 1 and next[0] == '/' and next[1] != '/') {
        res.header("Location", try a.dupe(u8, next));
    } else {
        res.header("Location", try std.fmt.allocPrint(a, "{s}/", .{app.base_path}));
    }
}

fn loginFailed(res: *httpz.Response) !void {
    res.status = 401;
    res.content_type = httpz.ContentType.HTML;
    res.body = "<p>wrong username or password. <a href=\"login\">try again</a></p>";
}

pub fn logoutSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    if (req.header("cookie")) |cookie| {
        if (auth.cookieValue(cookie, "vb_session")) |token| {
            app.db_mutex.lockUncancelable(app.io);
            defer app.db_mutex.unlock(app.io);
            db_mod.deleteSession(app.db, token) catch {};
        }
    }
    const cookie_path = if (app.base_path.len > 0) app.base_path else "/";
    res.header("Set-Cookie", try std.fmt.allocPrint(a, "vb_session=; Path={s}; HttpOnly; SameSite=Lax; Max-Age=0", .{cookie_path}));
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/", .{app.base_path}));
}

/// Make a private bookmark public (click on the lock).
pub fn shareToggle(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const owner_uid = sessionUserId(app, req) orelse return loginRequired(res);
    _ = (ownedBookmark(app, a, id, owner_uid) catch |e| return serverError(res, e)) orelse return notFound(res);
    db_mod.updateBookmark(app.db, id, .{ .shared = true }, db_mod.nowUnix()) catch |e| return serverError(res, e);
    const bm = (db_mod.getBookmark(app.db, a, id) catch |e| return serverError(res, e)) orelse return notFound(res);
    res.content_type = httpz.ContentType.HTML;
    res.body = try renderInner(app, a, bm, true);
}

/// Admin-only overview: users, archive queue, db size, bookmark count.
pub fn systemPage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const uid = sessionUserId(app, req) orelse return loginRequired(res);
    const st = loadSettings(app, a, uid);
    if (!st.admin) return notFound(res);

    var users_html: std.ArrayList(u8) = .empty;
    var n_users: i64 = 0;
    {
        var q = app.db.prepare("SELECT handle FROM user ORDER BY handle;") catch |e| return serverError(res, e);
        defer q.finalize();
        while (q.step() catch |e| return serverError(res, e)) : (n_users += 1) {
            const h = try a.dupe(u8, q.columnText(0));
            try users_html.appendSlice(a, try std.fmt.allocPrint(a,
                \\<a href="{s}/u:{s}">{s}</a>
            , .{ app.base_path, try urlEncode(a, h), try esc(a, h) }));
            try users_html.append(a, ' ');
        }
    }
    const pending = countArchive(app, "pending") catch |e| return serverError(res, e);
    const dead = countArchive(app, "dead") catch |e| return serverError(res, e);
    const n_bookmarks = db_mod.countFiltered(app.db, a, .{}) catch |e| return serverError(res, e);
    const db_bytes = blk: {
        var q = app.db.prepare("SELECT (SELECT * FROM pragma_page_count())*(SELECT * FROM pragma_page_size());") catch |e| return serverError(res, e);
        defer q.finalize();
        _ = q.step() catch |e| return serverError(res, e);
        break :blk q.columnInt(0);
    };

    const cfg = loadOidcConfig(app, a);
    const main_html = try std.fmt.allocPrint(a,
        \\<h1>system</h1>
        \\<p><b>{d}</b> users: {s}</p>
        \\<p><b>{d}</b> bookmarks</p>
        \\<p><b>{d}</b> items in the archiving queue</p>
        \\<p><b>{d}</b> dead links</p>
        \\<p>db size <b>{d:.1}</b> MB</p>
        \\<h1>authorization</h1>
        \\<form class="edit_form" method="post" action="{s}/ui/oidc">
        \\<p>mode<br>
        \\<label><input type="radio" name="mode" value="builtin" {s}> builtin</label>
        \\<label><input type="radio" name="mode" value="oidc" {s}> sso</label>
        \\<label><input type="radio" name="mode" value="both" {s}> both</label></p>
        \\<p>issuer (e.g. https://auth.example.com/oidc)<br><input type="text" name="issuer" value="{s}"></p>
        \\<p>client id<br><input type="text" name="client_id" value="{s}"></p>
        \\<p>client secret (leave empty to keep)<br><input type="password" name="client_secret" value=""></p>
        \\<p>redirect uri (this instance's public /oidc/callback)<br><input type="text" name="redirect_uri" value="{s}"></p>
        \\<p><button type="submit">save</button></p>
        \\</form>
        \\<p class="faint">sso users are matched by subject, then linked by username; new users are created otherwise.</p>
    , .{
        n_users,
        users_html.items,
        n_bookmarks,
        pending,
        dead,
        @as(f64, @floatFromInt(db_bytes)) / (1024.0 * 1024.0),
        app.base_path,
        if (std.mem.eql(u8, cfg.mode, "builtin")) "checked" else "",
        if (std.mem.eql(u8, cfg.mode, "oidc")) "checked" else "",
        if (std.mem.eql(u8, cfg.mode, "both")) "checked" else "",
        try esc(a, cfg.issuer),
        try esc(a, cfg.client_id),
        try esc(a, cfg.redirect_uri),
    });

    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, main_html, "", "", "", true, false, st);
}

const captcha_answer = "LETMEIN";
const captcha_png = @embedFile("captcha.png");

pub fn captchaPng(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = httpz.ContentType.PNG;
    res.body = captcha_png;
}

pub fn signupPage(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const form = try std.fmt.allocPrint(a,
        \\<h1>sign up</h1>
        \\<form class="edit_form" method="post" action="{s}/ui/signup">
        \\<p>username<br><input type="text" name="handle" required pattern="[a-z0-9_-]+" title="lowercase letters, digits, - and _"></p>
        \\<p>password<br><input type="password" name="password" required minlength="8"></p>
        \\<p>enter the text from the picture<br>
        \\<img src="{s}/static/captcha.png" alt="captcha" style="max-width:280px"><br>
        \\<input type="text" name="captcha" required autocomplete="off"></p>
        \\<p><button type="submit">sign up</button></p>
        \\</form>
    , .{ app.base_path, app.base_path });
    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, form, "", "", "", false, false, .{});
}

pub fn signupSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const handle = fd.get("handle") orelse return badRequest(res);
    const password = fd.get("password") orelse return badRequest(res);
    const captcha = fd.get("captcha") orelse return badRequest(res);

    if (!captchaMatches(captcha)) return signupError(res, "the text from the picture does not match");
    if (handle.len == 0 or handle.len > 32 or !validHandle(handle)) return signupError(res, "invalid username");
    if (password.len < 8) return signupError(res, "password must be at least 8 characters");

    var buf: [auth.hash_buf_len]u8 = undefined;
    const hash = auth.hashPassword(password, &buf, app.io) catch |e| return serverError(res, e);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    if ((db_mod.getUserByHandle(app.db, a, handle) catch |e| return serverError(res, e)) != null)
        return signupError(res, "username is taken");
    const uid = (db_mod.createUser(app.db, handle, hash, db_mod.nowUnix()) catch |e| return serverError(res, e)) orelse
        return signupError(res, "username is taken");

    var tok_buf: [64]u8 = undefined;
    const token = auth.newSessionToken(&tok_buf, app.io);
    db_mod.createSession(app.db, token, uid, db_mod.nowUnix() + 90 * 86400) catch |e| return serverError(res, e);
    const cookie_path = if (app.base_path.len > 0) app.base_path else "/";
    res.header("Set-Cookie", try std.fmt.allocPrint(a, "vb_session={s}; Path={s}; HttpOnly; SameSite=Lax; Max-Age=7776000", .{ token, cookie_path }));
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/", .{app.base_path}));
}

fn captchaMatches(input: []const u8) bool {
    var cleaned_buf: [64]u8 = undefined;
    var n: usize = 0;
    for (input) |c| {
        if (c == ' ' or c == '\t') continue;
        if (n >= cleaned_buf.len) return false;
        cleaned_buf[n] = std.ascii.toUpper(c);
        n += 1;
    }
    return std.mem.eql(u8, cleaned_buf[0..n], captcha_answer);
}

fn validHandle(h: []const u8) bool {
    for (h) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn signupError(res: *httpz.Response, msg: []const u8) !void {
    res.status = 400;
    res.content_type = httpz.ContentType.HTML;
    res.body = try std.fmt.allocPrint(res.arena, "<p>{s}. <a href=\"signup\">try again</a></p>", .{msg});
}

fn idParam(req: *httpz.Request) ?i64 {
    const s = req.param("id") orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn badRequest(res: *httpz.Response) !void {
    res.status = 400;
    res.body = "bad request";
}

fn notFound(res: *httpz.Response) !void {
    res.status = 404;
    res.body = "not found";
}

fn serverError(res: *httpz.Response, e: anyerror) !void {
    res.status = 500;
    try res.json(.{ .@"error" = @errorName(e) }, .{});
}

test "oneLine folds a pasted multi-line title" {
    const a = std.testing.allocator;
    const same = try oneLine(a, "already one line");
    try std.testing.expectEqualStrings("already one line", same);

    const folded = try oneLine(a, "two\r\nlines");
    defer a.free(folded);
    try std.testing.expectEqualStrings("two  lines", folded);
}

test "the add form prefers a saved value and falls back to the incoming one" {
    try std.testing.expectEqualStrings("saved", pick("saved", "incoming"));
    try std.testing.expectEqualStrings("incoming", pick("", "incoming"));
    try std.testing.expectEqualStrings("", pick("", ""));
}

test "joinTags" {
    const a = std.testing.allocator;
    var two = [_][]const u8{ "zig", "sqlite" };
    const s = try joinTags(a, &two);
    defer a.free(s);
    try std.testing.expectEqualStrings("zig sqlite", s);

    const none = try joinTags(a, &.{});
    defer a.free(none);
    try std.testing.expectEqualStrings("", none);
}

test "urlEncode escapes reserved chars" {
    const a = std.testing.allocator;
    const e = try urlEncode(a, "a b/c");
    defer a.free(e);
    try std.testing.expectEqualStrings("a%20b%2Fc", e);
}

test "fmtDate" {
    const a = std.testing.allocator;
    const s = try fmtDate(a, 1754121600);
    defer a.free(s);
    try std.testing.expectEqualStrings("2025-08-02", s);
}

test "civilFromDays epoch" {
    const c = civilFromDays(0);
    try std.testing.expectEqual(@as(i64, 1970), c.y);
    try std.testing.expectEqual(@as(i64, 1), c.m);
    try std.testing.expectEqual(@as(i64, 1), c.d);
}
