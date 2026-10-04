const std = @import("std");

const httplib = @import("httplib");
const mustache = @import("mustache");
const sqlite3 = @import("sqlite3");
const peachfuzz = @import("peachfuzz");

const homeTmpl = @embedFile("tmpl/home.html");
const contentTmpl = @embedFile("tmpl/content.html");
const dashboardAreaTmpl = @embedFile("tmpl/dashboard-area.html");
const dashboardReportTmpl = @embedFile("tmpl/dashboard-report.html");
const pageFolderTmpl = @embedFile("tmpl/pagefolder.html");
const pageLinkTmpl = @embedFile("tmpl/pagelink.html");

pub const dbPath: [:0]const u8 = "data/peachfuzz.db";

pub const Page = struct {
    title: [:0]const u8,
    content: [:0]const u8,
};

const PageFolder = struct {
    key: i64,
    name: [:0]const u8,
    description: [:0]const u8,
    parent: ?i64,
    rendered: bool = false,
};

const PageLink = struct {
    name: [:0]const u8,
    title: [:0]const u8,
    description: [:0]const u8,
    folder: ?i64,
    rendered: bool = false,
};

fn fillAvatarInitials(name: []const u8, buf: *[2]u8) usize {
    var n: usize = 0;
    var token_start = true;
    var first_token_second: ?u8 = null;

    for (name) |c| {
        if (c == '.' or c == '-' or c == '_' or c == ' ') {
            token_start = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c)) continue;
        const upper = std.ascii.toUpper(c);
        if (token_start) {
            if (n < 2) {
                buf[n] = upper;
                n += 1;
            }
            token_start = false;
        } else if (n == 1 and first_token_second == null) {
            first_token_second = upper;
        }
        if (n == 2) break;
    }

    if (n == 1) {
        if (first_token_second) |second| {
            buf[1] = second;
            n = 2;
        }
    }
    return n;
}

fn avatarInitials(allocator: std.mem.Allocator, username: []const u8) [:0]const u8 {
    var buf: [2]u8 = undefined;
    var n = fillAvatarInitials(username, &buf);
    if (n == 0) n = fillAvatarInitials(peachfuzz.conf.settings.appname, &buf);
    if (n == 0) return "";
    return allocator.dupeZ(u8, buf[0..n]) catch "";
}

pub const CurrentUser = peachfuzz.handling.auth.session.User;

pub fn currentUser(allocator: std.mem.Allocator, req: httplib.Request) ?CurrentUser {
    const token = req.cookie("session") orelse return null;
    const token_z = allocator.dupeZ(u8, token) catch return null;

    var db = sqlite3.initRO(dbPath) catch return null;
    defer db.deinit();

    return peachfuzz.handling.auth.session.currentUser(allocator, &db, token_z) catch null;
}

fn appendPageLink(allocator: std.mem.Allocator, link: *PageLink, tmpl: *mustache.Mustache, html: *std.ArrayList(u8)) void {
    if (link.rendered) return;
    link.rendered = true;

    var data = mustache.Data.init(allocator);
    defer data.deinit();
    data.setString("name", link.name);
    data.setString("title", link.title);
    data.setString("description", link.description);
    const search = std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ link.title, link.description }, 0) catch @panic("OOM");
    data.setString("search", search);

    const rendered = tmpl.Render(data);
    defer allocator.free(rendered);
    html.appendSlice(allocator, rendered) catch @panic("OOM");
}

fn appendPageFolder(
    allocator: std.mem.Allocator,
    folder_index: usize,
    folders: []PageFolder,
    links: []PageLink,
    folder_tmpl: *mustache.Mustache,
    link_tmpl: *mustache.Mustache,
    html: *std.ArrayList(u8),
) void {
    if (folders[folder_index].rendered) return;
    folders[folder_index].rendered = true;
    const folder = folders[folder_index];

    var children: std.ArrayList(u8) = .empty;
    for (folders, 0..) |candidate, index| {
        if (candidate.parent == folder.key) {
            appendPageFolder(allocator, index, folders, links, folder_tmpl, link_tmpl, &children);
        }
    }
    for (links) |*link| {
        if (link.folder == folder.key) appendPageLink(allocator, link, link_tmpl, &children);
    }

    const children_z = children.toOwnedSliceSentinel(allocator, 0) catch @panic("OOM");
    defer allocator.free(children_z);

    var data = mustache.Data.init(allocator);
    defer data.deinit();
    const key = std.fmt.allocPrintSentinel(allocator, "{d}", .{folder.key}, 0) catch @panic("OOM");
    defer allocator.free(key);
    data.setString("key", key);
    data.setString("name", folder.name);
    data.setString("description", folder.description);
    const search = std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ folder.name, folder.description }, 0) catch @panic("OOM");
    data.setString("search", search);
    data.setString("children", children_z);

    const rendered = folder_tmpl.Render(data);
    defer allocator.free(rendered);
    html.appendSlice(allocator, rendered) catch @panic("OOM");
}

fn renderPageTree(allocator: std.mem.Allocator) [:0]const u8 {
    var db = sqlite3.initRO(dbPath) catch return "";
    defer db.deinit();

    var folders: std.ArrayList(PageFolder) = .empty;
    defer folders.deinit(allocator);
    {
        var stmt = db.stmt("SELECT key, name, description, parent, parent IS NULL FROM pages_folder ORDER BY name, key") catch return "";
        defer stmt.deinit();

        while (true) {
            const step = stmt.step() catch return "";
            if (step == .done) break;

            folders.append(allocator, .{
                .key = stmt.columnInt(0),
                .name = allocator.dupeZ(u8, stmt.columnText(1)) catch @panic("OOM"),
                .description = allocator.dupeZ(u8, stmt.columnText(2)) catch @panic("OOM"),
                .parent = if (stmt.columnInt(4) != 0) null else stmt.columnInt(3),
            }) catch @panic("OOM");
        }
    }

    var links: std.ArrayList(PageLink) = .empty;
    defer links.deinit(allocator);
    {
        var stmt = db.stmt("SELECT name, title, description, folder, folder IS NULL FROM pages_view ORDER BY title, name") catch return "";
        defer stmt.deinit();

        while (true) {
            const step = stmt.step() catch return "";
            if (step == .done) break;

            links.append(allocator, .{
                .name = allocator.dupeZ(u8, stmt.columnText(0)) catch @panic("OOM"),
                .title = allocator.dupeZ(u8, stmt.columnText(1)) catch @panic("OOM"),
                .description = allocator.dupeZ(u8, stmt.columnText(2)) catch @panic("OOM"),
                .folder = if (stmt.columnInt(4) != 0) null else stmt.columnInt(3),
            }) catch @panic("OOM");
        }
    }

    var folder_tmpl = mustache.Mustache.init(allocator, pageFolderTmpl);
    defer folder_tmpl.deinit();
    var link_tmpl = mustache.Mustache.init(allocator, pageLinkTmpl);
    defer link_tmpl.deinit();

    var html: std.ArrayList(u8) = .empty;
    for (folders.items, 0..) |folder, index| {
        if (folder.parent == null) {
            appendPageFolder(allocator, index, folders.items, links.items, &folder_tmpl, &link_tmpl, &html);
        }
    }
    for (links.items) |*link| {
        if (link.folder == null) appendPageLink(allocator, link, &link_tmpl, &html);
    }
    for (folders.items, 0..) |folder, index| {
        if (!folder.rendered) {
            appendPageFolder(allocator, index, folders.items, links.items, &folder_tmpl, &link_tmpl, &html);
        }
    }
    for (links.items) |*link| appendPageLink(allocator, link, &link_tmpl, &html);

    return html.toOwnedSliceSentinel(allocator, 0) catch "";
}

fn renderDashboardAreas(allocator: std.mem.Allocator, db: *sqlite3.Sqlite3) [:0]const u8 {
    var tmpl = mustache.Mustache.init(allocator, dashboardAreaTmpl);
    defer tmpl.deinit();

    var stmt = db.stmt(
        \\WITH RECURSIVE folder_tree(root_key, root_name, root_description, folder_key) AS (
        \\  SELECT key, name, COALESCE(description, ''), key
        \\  FROM pages_folder
        \\  WHERE parent IS NULL
        \\  UNION ALL
        \\  SELECT ft.root_key, ft.root_name, ft.root_description, child.key
        \\  FROM folder_tree ft
        \\  JOIN pages_folder child ON child.parent = ft.folder_key
        \\)
        \\SELECT root_name,
        \\       CASE WHEN COUNT(DISTINCT root_key) > 1
        \\            THEN 'Reportes agrupados de esta área.'
        \\            ELSE MAX(root_description)
        \\       END,
        \\       COUNT(page.name),
        \\       lower(root_name) = 'experimental'
        \\FROM folder_tree
        \\LEFT JOIN pages_view page ON page.folder = folder_tree.folder_key
        \\GROUP BY root_name
        \\ORDER BY lower(root_name) = 'experimental', root_name COLLATE NOCASE
    ) catch return "";
    defer stmt.deinit();

    var html: std.ArrayList(u8) = .empty;
    while (true) {
        const step = stmt.step() catch return "";
        if (step == .done) break;

        var data = mustache.Data.init(allocator);
        defer data.deinit();
        const name = allocator.dupeZ(u8, stmt.columnText(0)) catch @panic("OOM");
        const description = allocator.dupeZ(u8, stmt.columnText(1)) catch @panic("OOM");
        const count = std.fmt.allocPrintSentinel(allocator, "{d}", .{stmt.columnInt(2)}, 0) catch @panic("OOM");
        data.setString("name", name);
        data.setString("description", description);
        data.setString("count", count);
        data.setBool("is_experimental", stmt.columnInt(3) != 0);

        const rendered = tmpl.Render(data);
        defer allocator.free(rendered);
        html.appendSlice(allocator, rendered) catch @panic("OOM");
    }

    return html.toOwnedSliceSentinel(allocator, 0) catch "";
}

fn renderDashboardReports(allocator: std.mem.Allocator, db: *sqlite3.Sqlite3) [:0]const u8 {
    var tmpl = mustache.Mustache.init(allocator, dashboardReportTmpl);
    defer tmpl.deinit();

    var stmt = db.stmt(
        \\WITH RECURSIVE folder_paths(key, path, root_name, is_experimental) AS (
        \\  SELECT key, name, name, lower(name) = 'experimental'
        \\  FROM pages_folder
        \\  WHERE parent IS NULL
        \\  UNION ALL
        \\  SELECT child.key,
        \\         folder_paths.path || ' › ' || child.name,
        \\         folder_paths.root_name,
        \\         folder_paths.is_experimental
        \\  FROM folder_paths
        \\  JOIN pages_folder child ON child.parent = folder_paths.key
        \\)
        \\SELECT page.name,
        \\       page.title,
        \\       COALESCE(page.description, ''),
        \\       COALESCE(folder_paths.path, 'Sin área'),
        \\       COALESCE(folder_paths.root_name, 'Sin área'),
        \\       COALESCE(folder_paths.is_experimental, 0)
        \\FROM pages_view page
        \\LEFT JOIN folder_paths ON folder_paths.key = page.folder
        \\ORDER BY COALESCE(folder_paths.is_experimental, 0),
        \\         COALESCE(folder_paths.path, ''),
        \\         page.title COLLATE NOCASE
    ) catch return "";
    defer stmt.deinit();

    var html: std.ArrayList(u8) = .empty;
    while (true) {
        const step = stmt.step() catch return "";
        if (step == .done) break;

        var data = mustache.Data.init(allocator);
        defer data.deinit();
        const name = allocator.dupeZ(u8, stmt.columnText(0)) catch @panic("OOM");
        const title = allocator.dupeZ(u8, stmt.columnText(1)) catch @panic("OOM");
        const description = allocator.dupeZ(u8, stmt.columnText(2)) catch @panic("OOM");
        const path = allocator.dupeZ(u8, stmt.columnText(3)) catch @panic("OOM");
        const root_name = allocator.dupeZ(u8, stmt.columnText(4)) catch @panic("OOM");
        const search = std.fmt.allocPrintSentinel(allocator, "{s} {s} {s}", .{ title, description, path }, 0) catch @panic("OOM");
        data.setString("name", name);
        data.setString("title", title);
        data.setString("description", description);
        data.setString("path", path);
        data.setString("root_name", root_name);
        data.setString("search", search);
        data.setBool("is_experimental", stmt.columnInt(5) != 0);

        const rendered = tmpl.Render(data);
        defer allocator.free(rendered);
        html.appendSlice(allocator, rendered) catch @panic("OOM");
    }

    return html.toOwnedSliceSentinel(allocator, 0) catch "";
}

fn renderDashboardData(allocator: std.mem.Allocator) struct {
    areas: [:0]const u8,
    reports: [:0]const u8,
} {
    var db = sqlite3.initRO(dbPath) catch return .{ .areas = "", .reports = "" };
    defer db.deinit();

    return .{
        .areas = renderDashboardAreas(allocator, &db),
        .reports = renderDashboardReports(allocator, &db),
    };
}

pub fn renderAnalystContent(allocator: std.mem.Allocator, page: ?Page) [:0]u8 {
    const dashboard = if (page == null) renderDashboardData(allocator) else null;

    var content = mustache.Mustache.init(allocator, contentTmpl);
    defer content.deinit();

    var data = mustache.Data.init(allocator);
    defer data.deinit();
    data.setString("app_name", peachfuzz.conf.settings.appname);
    data.setString("area_cards", if (dashboard) |value| value.areas else "");
    data.setString("report_rows", if (dashboard) |value| value.reports else "");
    data.setBool("is_page", page != null);
    data.setString("page_title", if (page) |p| p.title else "");
    data.setString("page_content", if (page) |p| p.content else "");

    return content.Render(data);
}

pub fn renderAnalyst(allocator: std.mem.Allocator, page: ?Page, user: ?CurrentUser) [:0]u8 {
    var shell = mustache.Mustache.init(allocator, homeTmpl);
    defer shell.deinit();

    var data = mustache.Data.init(allocator);
    defer data.deinit();
    data.setString("app_name", peachfuzz.conf.settings.appname);
    data.setString("main_content", renderAnalystContent(allocator, page));
    data.setString("page_tree", renderPageTree(allocator));
    data.setBool("is_page", page != null);
    data.setBool("is_authenticated", user != null);
    data.setString("username", if (user) |u| u.username else "");
    data.setString("avatar_initials", avatarInitials(allocator, if (user) |u| u.username else peachfuzz.conf.settings.appname));
    const role_label: [:0]const u8 = if (user) |u|
        (allocator.dupeZ(u8, peachfuzz.handling.auth.accessly.roleLabel(u.role)) catch "")
    else
        "";
    data.setString("role", role_label);

    return shell.Render(data);
}

pub fn isHtmx(req: httplib.Request) bool {
    const value = req.header("HX-Request") orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true");
}

pub fn respondAnalyst(
    allocator: std.mem.Allocator,
    req: httplib.Request,
    res: httplib.Response,
    page: ?Page,
    user: ?CurrentUser,
) void {
    res.set_header("Vary", "HX-Request");
    const rendered = if (isHtmx(req))
        renderAnalystContent(allocator, page)
    else
        renderAnalyst(allocator, page, user);
    res.set_content(rendered, "text/html");
}

pub fn redirectToSignIn(req: httplib.Request, res: httplib.Response) void {
    res.set_header("Vary", "HX-Request");
    if (isHtmx(req)) {
        res.set_header("HX-Redirect", "/peachfuzz/auth/signin");
        res.set_content("", "text/html");
    } else {
        res.set_redirect("/peachfuzz/auth/signin");
    }
}
