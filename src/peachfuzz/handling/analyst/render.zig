const std = @import("std");

const httplib = @import("httplib");
const mustache = @import("mustache");
const sqlite3 = @import("sqlite3");
const peachfuzz = @import("peachfuzz");

const homeTmpl = @embedFile("tmpl/home.html");
const cardTmpl = @embedFile("tmpl/card.html");
const pageFolderTmpl = @embedFile("tmpl/pagefolder.html");
const pageLinkTmpl = @embedFile("tmpl/pagelink.html");

pub const dbPath: [:0]const u8 = "data/peachfuzz.db";

pub const Page = struct {
    title: [:0]const u8,
    content: [:0]const u8,
};

const Card = struct {
    title: [:0]const u8,
    description: [:0]const u8,
    icon: [:0]const u8,
    caption: [:0]const u8,
    link: [:0]const u8,
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

const cards = [_]Card{
    .{
        .title = "Overview",
        .description = "Current workspace status and recent activity.",
        .icon = "fa-solid fa-gauge-high",
        .caption = "Open",
        .link = "/peachfuzz/analyst",
    },
    .{
        .title = "Signals",
        .description = "Focused views for active checks and events.",
        .icon = "fa-solid fa-wave-square",
        .caption = "Review",
        .link = "/peachfuzz/analyst",
    },
    .{
        .title = "Records",
        .description = "Saved runs, notes, and local data.",
        .icon = "fa-solid fa-box-archive",
        .caption = "Browse",
        .link = "/peachfuzz/analyst",
    },
};

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
    data.setString("name", folder.name);
    data.setString("description", folder.description);
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

pub fn renderAnalyst(allocator: std.mem.Allocator, page: ?Page, user: ?CurrentUser) [:0]u8 {
    var card = mustache.Mustache.init(allocator, cardTmpl);
    defer card.deinit();

    var cardsHtml: std.ArrayList(u8) = .empty;
    for (cards) |item| {
        var data = mustache.Data.init(allocator);
        defer data.deinit();
        data.setString("title", item.title);
        data.setString("description", item.description);
        data.setString("icon", item.icon);
        data.setString("caption", item.caption);
        data.setString("link", item.link);

        const rendered = card.Render(data);
        cardsHtml.appendSlice(allocator, rendered) catch @panic("OOM");
    }

    var shell = mustache.Mustache.init(allocator, homeTmpl);
    defer shell.deinit();

    var data = mustache.Data.init(allocator);
    defer data.deinit();
    const cardsZ = allocator.dupeZ(u8, cardsHtml.items) catch @panic("OOM");
    data.setString("cards", cardsZ);
    data.setString("page_tree", renderPageTree(allocator));
    data.setBool("is_page", page != null);
    data.setString("page_title", if (page) |p| p.title else "");
    data.setString("page_content", if (page) |p| p.content else "");
    data.setBool("is_authenticated", user != null);
    data.setString("username", if (user) |u| u.username else "");
    const role_label: [:0]const u8 = if (user) |u|
        (allocator.dupeZ(u8, peachfuzz.handling.auth.accessly.roleLabel(u.role)) catch "")
    else
        "";
    data.setString("role", role_label);

    return shell.Render(data);
}
