//! PostgreSQL's own parser, used to structurally analyze a candidate agent
//! statement (see the module-level comment below for why). Pure string
//! processing plus `pg_sys::raw_parser`/`nodeToString` FFI, no SPI.

use pgrx::prelude::*;
use serde_json::{json, Value};
use std::ffi::CStr;

// ---------------------------------------------------------------------------
// SQL analysis, via PostgreSQL's own parser
//
// The SQL sandbox used to decide what an agent statement touched by running
// regexes over the statement text.  That approach has to re-implement lexing --
// comments, dollar quotes, string literals, quoted identifiers, `extract(x FROM
// y)`, comma joins, CTE scoping -- and every one of those was a way to be wrong.
//
// Because Allgres is already a C extension we can call `raw_parser`, the exact
// grammar the server uses, and read the resulting tree.  Nothing is planned,
// rewritten, or executed: this is parse only.  `nodeToString` then gives a
// canonical serialization of that tree, which is what `analyze_dump` reads.
//
// Reading a machine-generated node dump is not the same thing as pattern
// matching user text: by this point the grammar has already resolved every
// lexical ambiguity, so a string literal can never be mistaken for a table and
// a comment cannot hide one.
// ---------------------------------------------------------------------------

pub(crate) fn raw_parse_dump(sql: &str) -> String {
    let Ok(c_sql) = std::ffi::CString::new(sql) else {
        // An interior NUL cannot reach the parser; treat it as unparseable.
        return String::new();
    };
    unsafe {
        let list = pg_sys::raw_parser(c_sql.as_ptr(), pg_sys::RawParseMode::RAW_PARSE_DEFAULT);
        if list.is_null() {
            return String::new();
        }
        let s = pg_sys::nodeToString(list as *const std::ffi::c_void);
        if s.is_null() {
            return String::new();
        }
        CStr::from_ptr(s).to_string_lossy().into_owned()
    }
}

/// Read one `outToken`-encoded value: `<>` is NULL, `""` is empty, and any
/// other token ends at the first unescaped delimiter.
pub(crate) fn read_token(s: &str) -> (Option<String>, usize) {
    let bytes = s.as_bytes();
    if bytes.starts_with(b"<>") {
        return (None, 2);
    }
    if bytes.starts_with(b"\"\"") {
        return (Some(String::new()), 2);
    }
    let mut out = String::new();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'\\' {
            // outToken escapes the delimiters, and prefixes a leading '<', '"'
            // or digit so it cannot be confused with NULL or a number.
            if i + 1 < bytes.len() {
                out.push(bytes[i + 1] as char);
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if b.is_ascii_whitespace() || b == b'}' || b == b')' || b == b'{' || b == b'(' {
            break;
        }
        out.push(b as char);
        i += 1;
    }
    (Some(out), i)
}

/// The substring covering one node, starting just after its `{TAG` opener.
pub(crate) fn node_body(s: &str) -> &str {
    let bytes = s.as_bytes();
    let mut depth = 0usize;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 1,
            b'{' => depth += 1,
            b'}' => {
                if depth == 0 {
                    return &s[..i];
                }
                depth -= 1;
            }
            _ => {}
        }
        i += 1;
    }
    s
}

/// The substring covering one parenthesised list, starting just after its `(`.
pub(crate) fn paren_body(s: &str) -> &str {
    let bytes = s.as_bytes();
    let mut depth = 0usize;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 1,
            b'(' => depth += 1,
            b')' => {
                if depth == 0 {
                    return &s[..i];
                }
                depth -= 1;
            }
            _ => {}
        }
        i += 1;
    }
    s
}

/// String nodes inside a List serialise as `"name"`, not as `{STRING ...}`,
/// so a funcname list looks like `("pg_catalog" "generate_series")`.
pub(crate) fn quoted_strings(body: &str) -> Vec<String> {
    let bytes = body.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'"' {
            i += 1;
            continue;
        }
        i += 1;
        let mut s = String::new();
        while i < bytes.len() && bytes[i] != b'"' {
            if bytes[i] == b'\\' && i + 1 < bytes.len() {
                s.push(bytes[i + 1] as char);
                i += 2;
            } else {
                s.push(bytes[i] as char);
                i += 1;
            }
        }
        i += 1;
        out.push(s);
    }
    out
}

/// Value of `:name` within a node body, ignoring nested nodes' own fields for
/// names that are unique to the node type we are reading.
fn field(body: &str, name: &str) -> Option<String> {
    let needle = format!(":{name} ");
    let at = body.find(&needle)? + needle.len();
    read_token(&body[at..]).0
}

fn read_ident(s: &str) -> String {
    s.chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect()
}

pub(crate) fn analyze_dump(dump: &str) -> Value {
    if dump.is_empty() {
        return json!({"ok": false, "error": "unparseable"});
    }

    // Top-level statement tags.
    let mut kinds: Vec<String> = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find("{RAWSTMT") {
        let start = idx + p;
        let body = node_body(&dump[start + "{RAWSTMT".len()..]);
        if let Some(q) = body.find(":stmt {") {
            kinds.push(read_ident(&body[q + ":stmt {".len()..]));
        }
        idx = start + "{RAWSTMT".len();
    }

    let mut relations = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find("{RANGEVAR ") {
        let start = idx + p + "{RANGEVAR ".len();
        let body = node_body(&dump[start..]);
        let name = field(body, "relname");
        if let Some(name) = name {
            relations.push(json!({
                "schema": field(body, "schemaname"),
                "name": name,
            }));
        }
        idx = start;
    }

    // A RangeVar naming a CTE is indistinguishable from a table at parse time,
    // so the caller needs the CTE names to tell them apart.
    let mut ctes = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find(":ctename ") {
        let start = idx + p + ":ctename ".len();
        if let (Some(name), _) = read_token(&dump[start..]) {
            ctes.push(Value::String(name));
        }
        idx = start;
    }

    // Every function the statement calls.  PostgreSQL forbids SET ROLE inside a
    // security-definer function, so the statement cannot be dropped to an
    // unprivileged role; the caller vets these against pg_proc instead.
    // funcname is a List of String nodes: ("pg_catalog" "generate_series").
    let mut functions = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find(":funcname (") {
        let start = idx + p + ":funcname (".len();
        let mut parts = quoted_strings(paren_body(&dump[start..]));
        if let Some(name) = parts.pop() {
            functions.push(json!({ "schema": parts.pop(), "name": name }));
        }
        idx = start;
    }

    // `SELECT ... INTO t` and data-modifying CTEs are SelectStmts that write.
    let has_into = dump.contains(":intoClause {");
    let has_dml = ["{INSERTSTMT", "{UPDATESTMT", "{DELETESTMT", "{MERGESTMT"]
        .iter()
        .any(|tag| dump.contains(tag));

    let kind = if kinds.len() == 1 && kinds[0] == "SELECTSTMT" {
        "select"
    } else {
        "other"
    };

    json!({
        "ok": true,
        "statements": kinds.len(),
        "kind": kind,
        "writes": has_into || has_dml,
        "relations": relations,
        "functions": functions,
        "ctes": ctes,
    })
}
