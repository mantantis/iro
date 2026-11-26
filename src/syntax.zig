// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Mausmann. Additional terms (GPLv3 section 7) apply, see NOTICE.md.

//! Syntax highlighting.
//!
//! Deliberately simple: each language is a small table (how comments start,
//! what strings look like, which words are keywords). A single pass per line
//! assigns a colour to every byte. It understands code less deeply than a real
//! parser, but it is fast, needs no third-party components and cannot crash,
//! however broken the file is.
//!
//! Constructs spanning several lines (block comments, long strings) are tracked
//! by a state passed from line to line.

const std = @import("std");

pub const Kind = enum(u8) {
    normal,
    comment,
    string,
    number,
    keyword,
    /// Name before "=" or ":" in config files.
    key,
    /// Heading (Markdown) or section (INI/TOML).
    heading,
    /// Added line in a diff.
    added,
    /// Removed line in a diff.
    removed,
};

/// State at the start of a line. 0 = normal, 1 = inside a block comment, 2 and
/// up = inside multi-line string number (n - 2).
pub const State = u8;
pub const normal_state: State = 0;
const block_state: State = 1;

const Pair = struct { open: []const u8, close: []const u8 };

pub const Lang = struct {
    name: []const u8,
    line_comments: []const []const u8 = &.{},
    /// A comment only counts if preceded by nothing or whitespace (shell).
    comment_needs_space: bool = false,
    /// A comment only counts at the start of a line (kitty.conf, INI).
    comment_only_at_start: bool = false,
    block_comment: ?Pair = null,
    quotes: []const u8 = "\"'",
    multiline: []const Pair = &.{},
    keywords: []const []const u8 = &.{},
    /// Highlight "name = value" or "name: value".
    key_value: bool = false,
    /// Highlight "[section]" as a heading.
    sections: bool = false,
    markdown: bool = false,
    /// A hyphen belongs to the word (CSS, config keys).
    dash_words: bool = false,
    /// "name value" without an equals sign: the first word of the line is the name
    /// (kitty.conf).
    space_keys: bool = false,
    /// Highlight colour values such as #1e1e2e.
    hex_colors: bool = false,
    /// "map" is followed by a key combination (kitty.conf).
    map_combos: bool = false,
    /// Keywords match in any case (SQL: select = SELECT).
    keywords_any_case: bool = false,
    /// "<name" is an element, "name=" inside it an attribute (HTML, XML).
    tags: bool = false,
    /// Lines are coloured by their first character: + added, - removed, @ hunk.
    diff: bool = false,
};

const c_block: Pair = .{ .open = "/*", .close = "*/" };
const css_keywords: []const []const u8 = &.{ "important", "none", "auto", "inherit", "solid", "transparent" };

pub const languages = [_]Lang{
    .{
        .name = "Shell",
        .line_comments = &.{"#"},
        .comment_needs_space = true,
        .keywords = &.{ "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "exit", "local", "export", "readonly", "source", "alias", "unset", "set", "shift", "break", "continue", "echo", "printf", "read", "cd", "test", "eval", "exec", "trap", "declare", "typeset" },
    },
    .{
        .name = "Hyprland",
        .line_comments = &.{"#"},
        .key_value = true,
        .dash_words = true,
        .keywords = &.{ "true", "false", "yes", "no", "on", "off", "source", "exec", "exec-once", "bind", "bindm", "binde", "bindl", "bindel", "bindr", "monitor", "windowrule", "windowrulev2", "layerrule", "workspace", "env", "submap", "animation", "bezier" },
    },
    .{
        .name = "Config",
        .line_comments = &.{ "#", ";" },
        .comment_only_at_start = true,
        .key_value = true,
        .sections = true,
        .dash_words = true,
        .space_keys = true,
        .hex_colors = true,
        .map_combos = true,
        .keywords = &.{ "true", "false", "yes", "no", "on", "off", "none", "map", "include" },
    },
    .{
        .name = "TOML",
        .line_comments = &.{"#"},
        .multiline = &.{ .{ .open = "\"\"\"", .close = "\"\"\"" }, .{ .open = "'''", .close = "'''" } },
        .key_value = true,
        .sections = true,
        .dash_words = true,
        .keywords = &.{ "true", "false" },
    },
    .{
        .name = "YAML",
        .line_comments = &.{"#"},
        .comment_needs_space = true,
        .key_value = true,
        .dash_words = true,
        .keywords = &.{ "true", "false", "yes", "no", "null", "on", "off" },
    },
    .{
        .name = "JSON",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .quotes = "\"",
        .keywords = &.{ "true", "false", "null" },
    },
    .{
        .name = "Lua",
        .line_comments = &.{"--"},
        .block_comment = .{ .open = "--[[", .close = "]]" },
        .multiline = &.{.{ .open = "[[", .close = "]]" }},
        .keywords = &.{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "require" },
    },
    .{
        .name = "Python",
        .line_comments = &.{"#"},
        .multiline = &.{ .{ .open = "\"\"\"", .close = "\"\"\"" }, .{ .open = "'''", .close = "'''" } },
        .keywords = &.{ "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self", "match", "case" },
    },
    .{
        .name = "Zig",
        .line_comments = &.{"//"},
        .keywords = &.{ "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "var", "volatile", "while", "true", "false", "null", "undefined", "void", "bool", "usize", "isize", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "type", "noreturn", "anyerror" },
    },
    .{
        .name = "Rust",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .quotes = "\"",
        .keywords = &.{ "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while" },
    },
    .{
        .name = "C",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .keywords = &.{ "auto", "bool", "break", "case", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extern", "false", "float", "for", "goto", "if", "inline", "int", "long", "namespace", "new", "delete", "nullptr", "NULL", "private", "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "true", "typedef", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "include", "define", "ifdef", "ifndef", "endif", "pragma" },
    },
    .{
        .name = "JavaScript",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .multiline = &.{.{ .open = "`", .close = "`" }},
        .keywords = &.{ "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield", "property", "signal", "readonly", "required" },
    },
    .{
        .name = "Go",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .multiline = &.{.{ .open = "`", .close = "`" }},
        .keywords = &.{ "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var" },
    },
    .{
        // CSS knows only /* */. "//" is not a comment there and appears in
        // url(https://…).
        .name = "CSS",
        .hex_colors = true,
        .block_comment = c_block,
        .dash_words = true,
        .key_value = true,
        .keywords = css_keywords,
    },
    .{
        .name = "SCSS",
        .hex_colors = true,
        .block_comment = c_block,
        .line_comments = &.{"//"},
        // Keeps url(https://…) intact.
        .comment_needs_space = true,
        .dash_words = true,
        .key_value = true,
        .keywords = css_keywords,
    },
    .{
        .name = "Nix",
        .line_comments = &.{"#"},
        .block_comment = c_block,
        .quotes = "\"",
        .multiline = &.{.{ .open = "''", .close = "''" }},
        .dash_words = true,
        .keywords = &.{ "let", "in", "with", "rec", "inherit", "if", "then", "else", "import", "true", "false", "null" },
    },
    .{
        .name = "TypeScript",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .multiline = &.{.{ .open = "`", .close = "`" }},
        .keywords = &.{ "abstract", "any", "as", "async", "await", "boolean", "break", "case", "catch", "class", "const", "continue", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "infer", "instanceof", "interface", "is", "keyof", "let", "namespace", "never", "new", "null", "number", "of", "private", "protected", "public", "readonly", "return", "satisfies", "static", "string", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "unknown", "var", "void", "while", "yield" },
    },
    .{
        .name = "Java",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .multiline = &.{.{ .open = "\"\"\"", .close = "\"\"\"" }},
        .keywords = &.{ "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package", "private", "protected", "public", "record", "return", "sealed", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try", "var", "void", "volatile", "while", "yield" },
    },
    .{
        .name = "C#",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .multiline = &.{.{ .open = "\"\"\"", .close = "\"\"\"" }},
        .keywords = &.{ "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char", "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "false", "finally", "float", "for", "foreach", "get", "if", "in", "init", "int", "interface", "internal", "is", "long", "namespace", "new", "null", "object", "out", "override", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "set", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "using", "var", "virtual", "void", "while", "yield" },
    },
    .{
        .name = "Kotlin",
        .line_comments = &.{"//"},
        .block_comment = c_block,
        .quotes = "\"",
        .multiline = &.{.{ .open = "\"\"\"", .close = "\"\"\"" }},
        .keywords = &.{ "abstract", "as", "break", "by", "catch", "class", "companion", "const", "continue", "data", "do", "else", "enum", "false", "final", "finally", "for", "fun", "if", "import", "in", "interface", "internal", "is", "lateinit", "null", "object", "open", "override", "package", "private", "protected", "public", "return", "sealed", "super", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while" },
    },
    .{
        .name = "PHP",
        .line_comments = &.{ "//", "#" },
        .block_comment = c_block,
        .keywords = &.{ "abstract", "and", "array", "as", "break", "case", "catch", "class", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "match", "namespace", "new", "null", "or", "print", "private", "protected", "public", "readonly", "require", "return", "static", "switch", "throw", "trait", "true", "try", "use", "var", "while", "yield", "php" },
    },
    .{
        .name = "Ruby",
        .line_comments = &.{"#"},
        .block_comment = .{ .open = "=begin", .close = "=end" },
        .keywords = &.{ "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor", "attr_reader", "attr_writer", "puts" },
    },
    .{
        .name = "SQL",
        .line_comments = &.{"--"},
        .block_comment = c_block,
        .quotes = "'\"",
        .keywords_any_case = true,
        .keywords = &.{ "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "check", "column", "commit", "constraint", "create", "cross", "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "full", "group", "having", "if", "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer", "primary", "references", "returning", "right", "rollback", "select", "set", "table", "then", "transaction", "union", "unique", "update", "values", "view", "when", "where", "with", "integer", "text", "real", "blob", "varchar", "boolean", "timestamp", "true", "false" },
    },
    .{
        .name = "HTML",
        .block_comment = .{ .open = "<!--", .close = "-->" },
        .tags = true,
        .dash_words = true,
    },
    .{
        .name = "Dockerfile",
        .line_comments = &.{"#"},
        .comment_only_at_start = true,
        .keywords_any_case = true,
        .keywords = &.{ "from", "run", "cmd", "label", "maintainer", "expose", "env", "add", "copy", "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as" },
    },
    .{
        .name = "Makefile",
        .line_comments = &.{"#"},
        .comment_needs_space = true,
        .key_value = true,
        .dash_words = true,
        .keywords = &.{ "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export", "unexport", "override", "PHONY" },
    },
    .{
        .name = "Diff",
        .quotes = "",
        .diff = true,
    },
    .{
        .name = "Git",
        .line_comments = &.{"#"},
        .comment_only_at_start = true,
        .quotes = "",
        .keywords = &.{ "pick", "reword", "edit", "squash", "fixup", "exec", "break", "drop", "label", "reset", "merge" },
    },
    .{
        .name = "Markdown",
        .markdown = true,
        .quotes = "",
        .multiline = &.{.{ .open = "```", .close = "```" }},
    },
};

fn langNamed(name: []const u8) ?*const Lang {
    for (&languages) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

const ExtMap = struct { ext: []const u8, lang: []const u8 };
const extensions = [_]ExtMap{
    .{ .ext = ".sh", .lang = "Shell" },     .{ .ext = ".bash", .lang = "Shell" },   .{ .ext = ".zsh", .lang = "Shell" },
    .{ .ext = ".fish", .lang = "Shell" },   .{ .ext = ".conf", .lang = "Config" },  .{ .ext = ".ini", .lang = "Config" },
    .{ .ext = ".cfg", .lang = "Config" },   .{ .ext = ".service", .lang = "Config" }, .{ .ext = ".timer", .lang = "Config" },
    .{ .ext = ".desktop", .lang = "Config" }, .{ .ext = ".rules", .lang = "Config" }, .{ .ext = ".toml", .lang = "TOML" },
    .{ .ext = ".yaml", .lang = "YAML" },    .{ .ext = ".yml", .lang = "YAML" },     .{ .ext = ".json", .lang = "JSON" },
    .{ .ext = ".jsonc", .lang = "JSON" },   .{ .ext = ".lua", .lang = "Lua" },      .{ .ext = ".py", .lang = "Python" },
    .{ .ext = ".zig", .lang = "Zig" },      .{ .ext = ".zon", .lang = "Zig" },      .{ .ext = ".rs", .lang = "Rust" },
    .{ .ext = ".c", .lang = "C" },          .{ .ext = ".h", .lang = "C" },          .{ .ext = ".cpp", .lang = "C" },
    .{ .ext = ".hpp", .lang = "C" },        .{ .ext = ".cc", .lang = "C" },         .{ .ext = ".glsl", .lang = "C" },
    .{ .ext = ".js", .lang = "JavaScript" }, .{ .ext = ".ts", .lang = "TypeScript" }, .{ .ext = ".jsx", .lang = "JavaScript" },
    .{ .ext = ".tsx", .lang = "TypeScript" }, .{ .ext = ".qml", .lang = "JavaScript" }, .{ .ext = ".go", .lang = "Go" },
    .{ .ext = ".mjs", .lang = "JavaScript" }, .{ .ext = ".cjs", .lang = "JavaScript" }, .{ .ext = ".mts", .lang = "TypeScript" },
    .{ .ext = ".java", .lang = "Java" },    .{ .ext = ".cs", .lang = "C#" },        .{ .ext = ".kt", .lang = "Kotlin" },
    .{ .ext = ".kts", .lang = "Kotlin" },   .{ .ext = ".php", .lang = "PHP" },      .{ .ext = ".rb", .lang = "Ruby" },
    .{ .ext = ".sql", .lang = "SQL" },      .{ .ext = ".html", .lang = "HTML" },    .{ .ext = ".htm", .lang = "HTML" },
    .{ .ext = ".xml", .lang = "HTML" },     .{ .ext = ".svg", .lang = "HTML" },     .{ .ext = ".xhtml", .lang = "HTML" },
    .{ .ext = ".vue", .lang = "HTML" },     .{ .ext = ".svelte", .lang = "HTML" },  .{ .ext = ".diff", .lang = "Diff" },
    .{ .ext = ".patch", .lang = "Diff" },   .{ .ext = ".mk", .lang = "Makefile" },  .{ .ext = ".mount", .lang = "Config" },
    .{ .ext = ".socket", .lang = "Config" }, .{ .ext = ".path", .lang = "Config" },  .{ .ext = ".target", .lang = "Config" },
    .{ .ext = ".editorconfig", .lang = "Config" }, .{ .ext = ".gitconfig", .lang = "Config" }, .{ .ext = ".install", .lang = "Shell" },
    .{ .ext = ".css", .lang = "CSS" },      .{ .ext = ".scss", .lang = "SCSS" },     .{ .ext = ".nix", .lang = "Nix" },
    .{ .ext = ".md", .lang = "Markdown" },  .{ .ext = ".markdown", .lang = "Markdown" },
};

/// Detects the language from the file name and the first line. `null`: no colours.
pub fn detect(path: []const u8, first_line: []const u8) ?*const Lang {
    const base = std.fs.path.basename(path);

    // Hyprland files are also called *.conf but have their own rules. Outside
    // the hypr folder (dotfiles repo, a copy) the name gives them away:
    // hyprland.conf, hyprlock.conf, hypridle.conf, hyprpaper.conf, …
    if (std.mem.endsWith(u8, base, ".conf") and
        (std.mem.indexOf(u8, path, "/hypr/") != null or std.mem.startsWith(u8, base, "hypr")))
        return langNamed("Hyprland");

    const names = [_]ExtMap{
        .{ .ext = ".zshrc", .lang = "Shell" },     .{ .ext = ".bashrc", .lang = "Shell" },  .{ .ext = ".profile", .lang = "Shell" },
        .{ .ext = ".zprofile", .lang = "Shell" },  .{ .ext = ".zshenv", .lang = "Shell" },  .{ .ext = "PKGBUILD", .lang = "Shell" },
        .{ .ext = "config", .lang = "Config" },    .{ .ext = "fstab", .lang = "Config" },   .{ .ext = "Makefile", .lang = "Makefile" },
        .{ .ext = "makefile", .lang = "Makefile" }, .{ .ext = "GNUmakefile", .lang = "Makefile" }, .{ .ext = "Dockerfile", .lang = "Dockerfile" },
        .{ .ext = "Containerfile", .lang = "Dockerfile" }, .{ .ext = "COMMIT_EDITMSG", .lang = "Git" }, .{ .ext = "MERGE_MSG", .lang = "Git" },
        .{ .ext = "TAG_EDITMSG", .lang = "Git" },  .{ .ext = "git-rebase-todo", .lang = "Git" }, .{ .ext = ".gitignore", .lang = "Git" },
        .{ .ext = ".gitconfig", .lang = "Config" }, .{ .ext = ".editorconfig", .lang = "Config" }, .{ .ext = "Gemfile", .lang = "Ruby" },
        .{ .ext = "Rakefile", .lang = "Ruby" },    .{ .ext = ".bash_profile", .lang = "Shell" }, .{ .ext = ".bash_aliases", .lang = "Shell" },
    };
    if (std.mem.startsWith(u8, base, "Dockerfile.")) return langNamed("Dockerfile");
    for (names) |n| {
        if (std.mem.eql(u8, base, n.ext)) return langNamed(n.lang);
    }
    const ext = std.fs.path.extension(base);
    if (ext.len > 0) {
        for (extensions) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e.ext)) return langNamed(e.lang);
        }
    }
    if (std.mem.startsWith(u8, first_line, "#!")) {
        if (std.mem.indexOf(u8, first_line, "python") != null) return langNamed("Python");
        if (std.mem.indexOf(u8, first_line, "lua") != null) return langNamed("Lua");
        if (std.mem.indexOf(u8, first_line, "ruby") != null) return langNamed("Ruby");
        if (std.mem.indexOf(u8, first_line, "node") != null) return langNamed("JavaScript");
        if (std.mem.indexOf(u8, first_line, "php") != null) return langNamed("PHP");
        if (std.mem.indexOf(u8, first_line, "sh") != null) return langNamed("Shell");
    }
    if (std.mem.startsWith(u8, first_line, "diff --git ") or std.mem.startsWith(u8, first_line, "--- ")) return langNamed("Diff");
    if (std.mem.startsWith(u8, first_line, "<?xml") or std.ascii.startsWithIgnoreCase(first_line, "<!doctype html")) return langNamed("HTML");
    return null;
}

fn isWordStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_' or b >= 0x80;
}

fn isWordByte(lang: *const Lang, b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80 or (lang.dash_words and b == '-');
}

fn startsAt(line: []const u8, i: usize, needle: []const u8) bool {
    return needle.len > 0 and line.len - i >= needle.len and std.mem.eql(u8, line[i..][0..needle.len], needle);
}

/// Highlights one line. `out` must be as long as `line`. Returns the state for
/// the start of the next line.
pub fn highlightLine(lang: *const Lang, line: []const u8, state_in: State, out: []Kind) State {
    std.debug.assert(out.len == line.len);
    @memset(out, .normal);
    var state = state_in;
    var i: usize = 0;

    // Line starts inside a multi-line construct.
    if (state != normal_state) {
        const close = closerOf(lang, state) orelse return normal_state;
        const kind: Kind = if (state == block_state) .comment else .string;
        if (std.mem.indexOf(u8, line, close)) |at| {
            @memset(out[0 .. at + close.len], kind);
            i = at + close.len;
            state = normal_state;
        } else {
            @memset(out, kind);
            return state;
        }
    }

    if (lang.diff) {
        const kind: Kind = if (line.len == 0)
            .normal
        else if (std.mem.startsWith(u8, line, "@@"))
            .heading
        else if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or
            std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "index "))
            .keyword
        else switch (line[0]) {
            '+' => Kind.added,
            '-' => Kind.removed,
            else => Kind.normal,
        };
        @memset(out, kind);
        return normal_state;
    }

    if (lang.markdown and i == 0) {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "#")) {
            @memset(out, .heading);
            return normal_state;
        }
        if (std.mem.startsWith(u8, trimmed, ">")) {
            @memset(out, .comment);
            return normal_state;
        }
    }
    if (lang.sections and i == 0) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            @memset(out, .heading);
            return normal_state;
        }
    }

    const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
    var seen_key = false;
    var combo_next = false;

    while (i < line.len) {
        const b = line[i];

        // Key combination after "map". Options such as "--when-focus-on value"
        // before it are skipped.
        if (combo_next and b != ' ' and b != '\t') {
            var j = i;
            while (j < line.len and line[j] != ' ' and line[j] != '\t') j += 1;
            if (startsAt(line, i, "--")) {
                while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
                while (j < line.len and line[j] != ' ' and line[j] != '\t') j += 1;
            } else {
                @memset(out[i..j], .string);
                combo_next = false;
            }
            i = j;
            continue;
        }

        // Colour value such as #fff or #1e1e2e (not at the start of a line, where it would
        // be a comment)
        if (lang.hex_colors and b == '#' and i != indent) {
            var j = i + 1;
            while (j < line.len and std.ascii.isHex(line[j])) j += 1;
            const n = j - i - 1;
            if ((n == 3 or n == 4 or n == 6 or n == 8) and (j == line.len or !isWordByte(lang, line[j]))) {
                @memset(out[i..j], .number);
                i = j;
                continue;
            }
        }

        // Block comment
        if (lang.block_comment) |bc| {
            if (startsAt(line, i, bc.open)) {
                if (std.mem.indexOfPos(u8, line, i + bc.open.len, bc.close)) |at| {
                    @memset(out[i .. at + bc.close.len], .comment);
                    i = at + bc.close.len;
                    continue;
                }
                @memset(out[i..], .comment);
                return block_state;
            }
        }
        // Multi-line string
        var matched_multi = false;
        for (lang.multiline, 0..) |m, idx| {
            if (!startsAt(line, i, m.open)) continue;
            matched_multi = true;
            if (std.mem.indexOfPos(u8, line, i + m.open.len, m.close)) |at| {
                @memset(out[i .. at + m.close.len], .string);
                i = at + m.close.len;
            } else {
                @memset(out[i..], .string);
                return @intCast(2 + idx);
            }
            break;
        }
        if (matched_multi) continue;

        // Line comment
        var is_comment = false;
        for (lang.line_comments) |lc| {
            if (!startsAt(line, i, lc)) continue;
            if (lang.comment_only_at_start and i != indent) continue;
            if (lang.comment_needs_space and i != 0 and line[i - 1] != ' ' and line[i - 1] != '\t') continue;
            is_comment = true;
            break;
        }
        if (is_comment) {
            @memset(out[i..], .comment);
            return normal_state;
        }

        // Single-line string
        if (std.mem.indexOfScalar(u8, lang.quotes, b) != null) {
            var j = i + 1;
            while (j < line.len and line[j] != b) : (j += 1) {
                if (line[j] == '\\' and j + 1 < line.len) j += 1;
            }
            const end = @min(j + 1, line.len);
            @memset(out[i..end], .string);
            i = end;
            continue;
        }

        // Number
        if (std.ascii.isDigit(b) and (i == 0 or !isWordByte(lang, line[i - 1]))) {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '.' or line[j] == '_')) j += 1;
            @memset(out[i..j], .number);
            i = j;
            continue;
        }

        // Word
        if (isWordStart(b)) {
            var j = i + 1;
            while (j < line.len and isWordByte(lang, line[j])) j += 1;
            const word = line[i..j];
            var kind: Kind = .normal;
            for (lang.keywords) |kw| {
                const same = if (lang.keywords_any_case) std.ascii.eqlIgnoreCase(kw, word) else std.mem.eql(u8, kw, word);
                if (same) {
                    kind = .keyword;
                    break;
                }
            }
            if (lang.tags) {
                // Right after "<" or "</" comes an element name; before "=" an
                // attribute name.
                const after_open = i > 0 and (line[i - 1] == '<' or (i > 1 and line[i - 1] == '/' and line[i - 2] == '<'));
                if (after_open) {
                    // "svg:rect" or "v-if" belong to it entirely.
                    while (j < line.len and (isWordByte(lang, line[j]) or line[j] == ':')) j += 1;
                    kind = .keyword;
                } else if (j < line.len and line[j] == '=') {
                    kind = .key;
                }
            }
            if (lang.key_value and !seen_key and kind == .normal) {
                // First word of the line, followed by "=" or ":".
                var k = j;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
                if (k < line.len and (line[k] == '=' or line[k] == ':')) kind = .key;
            }
            if (lang.space_keys and i == indent and kind == .normal and j < line.len and (line[j] == ' ' or line[j] == '\t')) {
                kind = .key;
            }
            if (lang.map_combos and i == indent and std.mem.eql(u8, word, "map")) combo_next = true;
            seen_key = true;
            @memset(out[i..j], kind);
            i = j;
            continue;
        }

        if (b != ' ' and b != '\t' and b != '-' and b != '$') seen_key = true;
        i += 1;
    }
    return normal_state;
}

fn closerOf(lang: *const Lang, state: State) ?[]const u8 {
    if (state == block_state) return if (lang.block_comment) |bc| bc.close else null;
    const idx = state - 2;
    if (idx >= lang.multiline.len) return null;
    return lang.multiline[idx].close;
}

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

fn kinds(lang_name: []const u8, line: []const u8, state: State, out: []Kind) State {
    return highlightLine(langNamed(lang_name).?, line, state, out[0..line.len]);
}

test "language is detected" {
    try testing.expectEqualStrings("Hyprland", detect("/home/x/.config/hypr/hyprland.conf", "").?.name);
    try testing.expectEqualStrings("Config", detect("/home/x/.config/kitty/kitty.conf", "").?.name);
    // Outside the hypr folder the name decides.
    try testing.expectEqualStrings("Hyprland", detect("/home/x/dotfiles/hyprland.conf", "").?.name);
    try testing.expectEqualStrings("Hyprland", detect("hyprlock.conf", "").?.name);
    try testing.expectEqualStrings("Config", detect("/home/x/dotfiles/kitty.conf", "").?.name);
    try testing.expectEqualStrings("Lua", detect("/home/x/.config/hypr/hyprland.lua", "").?.name);
    try testing.expectEqualStrings("Lua", detect("init.lua", "").?.name);
    try testing.expectEqualStrings("Shell", detect("/home/x/.zshrc", "").?.name);
    try testing.expectEqualStrings("Python", detect("skript", "#!/usr/bin/env python3").?.name);
    try testing.expect(detect("notizen.txt", "hallo") == null);
}

test "shell: comment, string, keyword" {
    var out: [64]Kind = undefined;
    const line = "if [ \"$x\" = 1 ]; then # los";
    _ = kinds("Shell", line, 0, &out);
    try testing.expectEqual(Kind.keyword, out[0]);
    try testing.expectEqual(Kind.string, out[5]);
    try testing.expectEqual(Kind.number, out[12]);
    try testing.expectEqual(Kind.keyword, out[17]);
    try testing.expectEqual(Kind.comment, out[22]);
    // "#" inside a word is not a comment.
    const l2 = "echo ${x#y}";
    _ = kinds("Shell", l2, 0, &out);
    try testing.expectEqual(Kind.normal, out[8]);
}

test "config: colour with # is not a comment, key is detected" {
    var out: [64]Kind = undefined;
    const line = "color0 #1e1e2e";
    _ = kinds("Config", line, 0, &out);
    try testing.expectEqual(Kind.number, out[7]); // Colour value, not a comment
    const l2 = "font_size = 12";
    _ = kinds("Config", l2, 0, &out);
    try testing.expectEqual(Kind.key, out[0]);
    try testing.expectEqual(Kind.number, out[12]);
    const l3 = "  # Kommentar";
    _ = kinds("Config", l3, 0, &out);
    try testing.expectEqual(Kind.comment, out[2]);
    const l4 = "[Abschnitt]";
    _ = kinds("Config", l4, 0, &out);
    try testing.expectEqual(Kind.heading, out[3]);
}

test "kitty.conf: name without equals sign, colour value, key combination" {
    var out: [80]Kind = undefined;
    const l1 = "background_opacity 0.78";
    _ = kinds("Config", l1, 0, &out);
    try testing.expectEqual(Kind.key, out[0]);
    try testing.expectEqual(Kind.number, out[19]);
    const l2 = "background #000000";
    _ = kinds("Config", l2, 0, &out);
    try testing.expectEqual(Kind.key, out[0]);
    try testing.expectEqual(Kind.number, out[11]);
    const l3 = "map ctrl+c    copy_or_interrupt";
    _ = kinds("Config", l3, 0, &out);
    try testing.expectEqual(Kind.keyword, out[0]);
    try testing.expectEqual(Kind.string, out[4]);
    try testing.expectEqual(Kind.string, out[9]);
    try testing.expectEqual(Kind.normal, out[14]);
    const l4 = "map --when-focus-on var:in_editor kitty_mod+s";
    _ = kinds("Config", l4, 0, &out);
    try testing.expectEqual(Kind.normal, out[4]);
    try testing.expectEqual(Kind.normal, out[20]);
    try testing.expectEqual(Kind.string, out[34]);
}

test "block comment across several lines" {
    var out: [64]Kind = undefined;
    var st = kinds("C", "int a; /* fängt an", 0, &out);
    try testing.expectEqual(Kind.keyword, out[0]);
    try testing.expectEqual(Kind.comment, out[8]);
    try testing.expectEqual(block_state, st);
    st = kinds("C", "immer noch", st, &out);
    try testing.expectEqual(Kind.comment, out[0]);
    try testing.expectEqual(block_state, st);
    st = kinds("C", "ende */ int b;", st, &out);
    try testing.expectEqual(Kind.comment, out[5]);
    try testing.expectEqual(Kind.keyword, out[8]);
    try testing.expectEqual(normal_state, st);
}

test "Lua: long string and long comment" {
    var out: [64]Kind = undefined;
    var st = kinds("Lua", "local s = [[erste", 0, &out);
    try testing.expectEqual(Kind.keyword, out[0]);
    try testing.expectEqual(Kind.string, out[10]);
    try testing.expect(st >= 2);
    st = kinds("Lua", "zweite]] .. x -- ende", st, &out);
    try testing.expectEqual(Kind.string, out[0]);
    try testing.expectEqual(Kind.normal, out[12]);
    try testing.expectEqual(Kind.comment, out[14]);
    st = kinds("Lua", "--[[ lang", 0, &out);
    try testing.expectEqual(block_state, st);
}

test "Markdown: heading and code block" {
    var out: [64]Kind = undefined;
    _ = kinds("Markdown", "## Titel", 0, &out);
    try testing.expectEqual(Kind.heading, out[4]);
    var st = kinds("Markdown", "```sh", 0, &out);
    try testing.expect(st >= 2);
    st = kinds("Markdown", "echo hi", st, &out);
    try testing.expectEqual(Kind.string, out[0]);
    st = kinds("Markdown", "```", st, &out);
    try testing.expectEqual(normal_state, st);
}

test "CSS: // is not a comment, SCSS: // is" {
    var out: [64]Kind = undefined;
    try testing.expectEqualStrings("CSS", detect("/x/waybar/style.css", "").?.name);
    try testing.expectEqualStrings("SCSS", detect("/x/eww/eww.scss", "").?.name);

    const url = "background: url(https://x.org/a.png);";
    _ = kinds("CSS", url, 0, &out);
    for (out[0..url.len]) |k| try testing.expect(k != .comment);
    _ = kinds("SCSS", url, 0, &out);
    for (out[0..url.len]) |k| try testing.expect(k != .comment);

    const css = "a { color: red; } // no";
    _ = kinds("CSS", css, 0, &out);
    try testing.expect(out[18] != .comment);
    _ = kinds("SCSS", css, 0, &out);
    try testing.expectEqual(Kind.comment, out[18]);
    const top = "// at the start";
    _ = kinds("SCSS", top, 0, &out);
    try testing.expectEqual(Kind.comment, out[0]);

    // Both still have block comments.
    const block = "a { /* hidden */ }";
    _ = kinds("CSS", block, 0, &out);
    try testing.expectEqual(Kind.comment, out[6]);
}

test "random test: arbitrary bytes never break the highlighter" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const alphabet = "ab_ 1.\"'`#/-*[]=:\\\t{}$<>x\xc3\xa4";
    var line: [48]u8 = undefined;
    var out: [48]Kind = undefined;
    for (&languages) |*lang| {
        var state: State = 0;
        var round: usize = 0;
        while (round < 3000) : (round += 1) {
            const len = rnd.uintAtMost(usize, line.len);
            for (line[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            state = highlightLine(lang, line[0..len], state, out[0..len]);
            try testing.expect(state < 2 + lang.multiline.len);
        }
    }
}

test "new languages are detected" {
    try testing.expectEqualStrings("TypeScript", detect("app.ts", "").?.name);
    try testing.expectEqualStrings("Java", detect("Main.java", "").?.name);
    try testing.expectEqualStrings("C#", detect("Program.cs", "").?.name);
    try testing.expectEqualStrings("SQL", detect("schema.SQL", "").?.name);
    try testing.expectEqualStrings("HTML", detect("index.html", "").?.name);
    try testing.expectEqualStrings("HTML", detect("bild.svg", "").?.name);
    try testing.expectEqualStrings("Dockerfile", detect("/x/Dockerfile", "").?.name);
    try testing.expectEqualStrings("Dockerfile", detect("/x/Dockerfile.dev", "").?.name);
    try testing.expectEqualStrings("Makefile", detect("/x/Makefile", "").?.name);
    try testing.expectEqualStrings("Config", detect("/etc/fstab", "").?.name);
    try testing.expectEqualStrings("Git", detect("/x/.git/COMMIT_EDITMSG", "").?.name);
    try testing.expectEqualStrings("Diff", detect("aenderung.patch", "").?.name);
    try testing.expectEqualStrings("Diff", detect("ohne-endung", "diff --git a/x b/x").?.name);
    try testing.expectEqualStrings("Ruby", detect("skript", "#!/usr/bin/env ruby").?.name);
}

test "SQL: keywords in any case" {
    var out: [64]Kind = undefined;
    const line = "select Name FROM leute -- alle";
    _ = kinds("SQL", line, 0, &out);
    try testing.expectEqual(Kind.keyword, out[0]);
    try testing.expectEqual(Kind.normal, out[7]);
    try testing.expectEqual(Kind.keyword, out[12]);
    try testing.expectEqual(Kind.comment, out[23]);
}

test "HTML: element, attribute, comment across lines" {
    var out: [64]Kind = undefined;
    const line = "<a href=\"x\" data-id=1>Text</a> <!-- los";
    const st = kinds("HTML", line, 0, &out);
    try testing.expectEqual(Kind.keyword, out[1]); // a
    try testing.expectEqual(Kind.key, out[3]); // href
    try testing.expectEqual(Kind.string, out[8]);
    try testing.expectEqual(Kind.key, out[12]); // data-id
    try testing.expectEqual(Kind.normal, out[22]); // Text
    try testing.expectEqual(Kind.keyword, out[28]); // a in </a>
    try testing.expectEqual(Kind.comment, out[31]);
    try testing.expect(st != normal_state);
    const l2 = "noch drin --> <svg:rect/>";
    try testing.expectEqual(normal_state, kinds("HTML", l2, st, &out));
    try testing.expectEqual(Kind.comment, out[0]);
    try testing.expectEqual(Kind.keyword, out[19]); // rect belongs to svg:rect
}

test "diff: lines by their first character" {
    var out: [64]Kind = undefined;
    _ = kinds("Diff", "+neu", 0, &out);
    try testing.expectEqual(Kind.added, out[1]);
    _ = kinds("Diff", "-weg", 0, &out);
    try testing.expectEqual(Kind.removed, out[1]);
    _ = kinds("Diff", "@@ -1,2 +1,3 @@", 0, &out);
    try testing.expectEqual(Kind.heading, out[4]);
    _ = kinds("Diff", "+++ b/datei", 0, &out);
    try testing.expectEqual(Kind.keyword, out[0]);
    _ = kinds("Diff", " gleich", 0, &out);
    try testing.expectEqual(Kind.normal, out[1]);
}

test "random lines never crash any highlighter" {
    var prng = std.Random.DefaultPrng.init(0x1505);
    const rnd = prng.random();
    const alphabet = "ab <>/=\"'`#-+@*!?[]{}()\\\t0123456789:$.,;_äß🦅";
    var line_buf: [96]u8 = undefined;
    var out: [96]Kind = undefined;
    for (&languages) |*lang| {
        var state: State = normal_state;
        var round: usize = 0;
        while (round < 400) : (round += 1) {
            const n = rnd.uintLessThan(usize, line_buf.len);
            for (line_buf[0..n]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            state = highlightLine(lang, line_buf[0..n], state, out[0..n]);
        }
    }
}
