//! Unit tests for the pure request/auth/parsing logic across the split
//! modules -- no database needed. Run with `cargo pgrx test --features pg17`.

use crate::http_protocol::{parse_http_request, HttpRequest};
use crate::rpc::valid_uuid;
use crate::sql_parser::{analyze_dump, node_body, paren_body, quoted_strings, read_token};
use crate::truncate_utf8;
use crate::web::{
    auth_failures_exceeded, authorized, check_exposure, consume_sse_ticket, constant_time_eq,
    csrf_ok, mint_sse_ticket, percent_decode, rate_limited, record_auth_failure, WebConfig,
    RATE_AUTH_FAIL_LIMIT, RATE_GENERAL_LIMIT, RATE_GENERAL_WINDOW, RATE_LIMIT, SSE_TICKETS,
};
use crate::{DASHBOARD_HTML, SSE_TICKET_TTL};
use std::net::IpAddr;
use std::path::PathBuf;
use std::time::{Duration, Instant};


fn req(raw: &str) -> HttpRequest {
    parse_http_request(raw.as_bytes()).expect("parses")
}

#[test]
fn parses_method_path_headers_and_body() {
    let r = req("POST /api/v1/run?x=1 HTTP/1.1\r\nHost: a:8088\r\nContent-Length: 2\r\n\r\n{}");
    assert_eq!(r.method, "POST");
    assert_eq!(r.route(), "/api/v1/run");
    assert_eq!(r.query(), "x=1");
    assert_eq!(r.header("host"), Some("a:8088"));
    assert_eq!(r.body, "{}");
}

#[test]
fn header_lookup_is_case_insensitive() {
    let r = req("GET / HTTP/1.1\r\nX-Allgres-Client: dashboard\r\n\r\n");
    assert_eq!(r.header("x-allgres-client"), Some("dashboard"));
    assert_eq!(r.header("X-ALLGRES-CLIENT"), Some("dashboard"));
}

#[test]
fn truncated_request_is_rejected() {
    assert!(parse_http_request(b"GET / HTTP/1.1\r\nHost: a").is_none());
}

#[test]
fn constant_time_eq_matches_semantics_of_eq() {
    assert!(constant_time_eq(b"secret", b"secret"));
    assert!(!constant_time_eq(b"secret", b"secreT"));
    assert!(!constant_time_eq(b"secret", b"secret1"));
    assert!(constant_time_eq(b"", b""));
}

#[test]
fn csrf_requires_custom_header_on_api_calls() {
    assert!(!csrf_ok(&req("GET /api/v1/tasks HTTP/1.1\r\nHost: a\r\n\r\n")));
    assert!(csrf_ok(&req(
        "GET /api/v1/tasks HTTP/1.1\r\nHost: a\r\nX-Allgres-Client: dashboard\r\n\r\n"
    )));
}

#[test]
fn csrf_rejects_foreign_origin_and_opaque_origin() {
    assert!(!csrf_ok(&req(
        "POST /api/v1/run HTTP/1.1\r\nHost: a\r\nOrigin: http://evil.test\r\nX-Allgres-Client: d\r\n\r\n"
    )));
    assert!(!csrf_ok(&req(
        "POST /api/v1/run HTTP/1.1\r\nHost: a\r\nOrigin: null\r\nX-Allgres-Client: d\r\n\r\n"
    )));
    assert!(csrf_ok(&req(
        "POST /api/v1/run HTTP/1.1\r\nHost: a\r\nOrigin: http://a\r\nX-Allgres-Client: d\r\n\r\n"
    )));
}

#[test]
fn event_stream_is_exempt_from_the_custom_header() {
    assert!(csrf_ok(&req("GET /api/v1/events HTTP/1.1\r\nHost: a\r\n\r\n")));
}

#[test]
fn token_is_required_when_configured() {
    let cfg = WebConfig {
        token: "s3cr3t".into(),
        socket: PathBuf::from("/dev/null"),
        mock_enabled: false,
    };
    assert!(!authorized(&req("GET /api/v1/tasks HTTP/1.1\r\n\r\n"), &cfg));
    assert!(!authorized(
        &req("GET /api/v1/tasks HTTP/1.1\r\nAuthorization: Bearer nope\r\n\r\n"),
        &cfg
    ));
    assert!(authorized(
        &req("GET /api/v1/tasks HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n\r\n"),
        &cfg
    ));
}

#[test]
fn query_ticket_is_accepted_only_for_the_event_stream_and_only_once() {
    let cfg = WebConfig {
        token: "s3cr3t".into(),
        socket: PathBuf::from("/dev/null"),
        mock_enabled: false,
    };
    // The durable token itself, presented as a query param, must never
    // authorize -- only a minted ticket does, and only for /api/v1/events.
    assert!(!authorized(&req("GET /api/v1/events?token=s3cr3t HTTP/1.1\r\n\r\n"), &cfg));

    let ticket = mint_sse_ticket();
    assert!(authorized(
        &req(&format!("GET /api/v1/events?ticket={ticket} HTTP/1.1\r\n\r\n")),
        &cfg
    ));
    // Single-use: the same ticket does not authorize a second time.
    assert!(!authorized(
        &req(&format!("GET /api/v1/events?ticket={ticket} HTTP/1.1\r\n\r\n")),
        &cfg
    ));
    // Not accepted on any other route, even freshly minted.
    let ticket2 = mint_sse_ticket();
    assert!(!authorized(
        &req(&format!("GET /api/v1/tasks?ticket={ticket2} HTTP/1.1\r\n\r\n")),
        &cfg
    ));
}

#[test]
fn sse_ticket_expires() {
    let ticket = mint_sse_ticket();
    {
        let mut tickets = SSE_TICKETS.lock().unwrap();
        let stale = Instant::now() - SSE_TICKET_TTL - Duration::from_secs(1);
        tickets.insert(ticket.clone(), stale);
    }
    assert!(!consume_sse_ticket(&ticket));
}

#[test]
fn rate_limit_trips_after_the_general_cap_and_recovers_outside_the_window() {
    let ip: IpAddr = "203.0.113.7".parse().unwrap();
    for _ in 0..RATE_GENERAL_LIMIT {
        assert!(!rate_limited(ip));
    }
    assert!(rate_limited(ip));

    // A hit recorded outside the window does not count against the cap.
    {
        let mut w = RATE_LIMIT.lock().unwrap();
        let old = Instant::now() - RATE_GENERAL_WINDOW - Duration::from_secs(1);
        w.general.insert(ip, vec![old; RATE_GENERAL_LIMIT]);
    }
    assert!(!rate_limited(ip));
}

#[test]
fn auth_failure_lockout_is_independent_of_the_general_rate_limit() {
    let ip: IpAddr = "203.0.113.8".parse().unwrap();
    assert!(!auth_failures_exceeded(ip));
    for _ in 0..RATE_AUTH_FAIL_LIMIT {
        record_auth_failure(ip);
    }
    assert!(auth_failures_exceeded(ip));
    // A different IP is unaffected.
    let other: IpAddr = "203.0.113.9".parse().unwrap();
    assert!(!auth_failures_exceeded(other));
}

#[test]
fn percent_decoding_handles_escapes_and_plus() {
    assert_eq!(percent_decode("a%20b+c"), "a b c");
    assert_eq!(percent_decode("%2F"), "/");
    assert_eq!(percent_decode("100%"), "100%");
}

#[test]
fn exposure_check_blocks_public_bind_without_token() {
    assert!(check_exposure("127.0.0.1:8088", "").is_ok());
    assert!(check_exposure("0.0.0.0:8088", "token").is_ok());
    assert!(check_exposure("0.0.0.0:8088", "").is_err());
}

#[test]
fn uuid_shape_is_validated_before_it_reaches_a_cast() {
    assert!(valid_uuid("0f6f1b7c-3c2e-4f5a-9a1b-2c3d4e5f6a7b"));
    assert!(!valid_uuid("0f6f1b7c-3c2e-4f5a-9a1b-2c3d4e5f6a7"));
    assert!(!valid_uuid("'; DROP TABLE agents; --"));
}

#[test]
fn truncation_keeps_utf8_boundaries() {
    assert_eq!(truncate_utf8("héllo", 2), "h");
    assert_eq!(truncate_utf8("hello", 99), "hello");
}

#[test]
fn dashboard_html_carries_the_csp_nonce_placeholder() {
    assert_eq!(DASHBOARD_HTML.matches("__CSP_NONCE__").count(), 2);
}

// --- node-dump reader -------------------------------------------------
//
// These exercise `analyze_dump` against the shape `nodeToString` produces.
// The end-to-end path (real parser -> real dump) is covered by
// allgres_public.fn_selftest, which runs inside the database.

fn rangevar(schema: &str, rel: &str) -> String {
    format!("{{RANGEVAR :schemaname {schema} :relname {rel} :inh true :relpersistence p :alias <> :location 14}}")
}

fn select_dump(inner: &str) -> String {
    format!("({{RAWSTMT :stmt {{SELECTSTMT :distinctClause <> :intoClause <> :targetList <> :fromClause ({inner}) }} :stmt_location 0 :stmt_len 40}})")
}

#[test]
fn reads_a_schema_qualified_relation() {
    let d = analyze_dump(&select_dump(&rangevar("allgres_public", "v_sales")));
    assert_eq!(d["kind"], "select");
    assert_eq!(d["statements"], 1);
    assert_eq!(d["writes"], false);
    assert_eq!(d["relations"][0]["schema"], "allgres_public");
    assert_eq!(d["relations"][0]["name"], "v_sales");
}

#[test]
fn reads_every_relation_in_a_comma_join() {
    let inner = format!("{} {}", rangevar("allgres_public", "v_sales"), rangevar("allgres_private", "sessions"));
    let d = analyze_dump(&select_dump(&inner));
    let rels = d["relations"].as_array().unwrap();
    assert_eq!(rels.len(), 2);
    assert_eq!(rels[1]["schema"], "allgres_private");
}

#[test]
fn unqualified_relation_reports_a_null_schema() {
    let d = analyze_dump(&select_dump(&rangevar("<>", "sessions")));
    assert!(d["relations"][0]["schema"].is_null());
    assert_eq!(d["relations"][0]["name"], "sessions");
}

#[test]
fn collects_cte_names() {
    let dump = select_dump(&format!(
        "{{COMMONTABLEEXPR :ctename x :aliascolnames <> :ctequery <> :location 5}} {}",
        rangevar("<>", "x")
    ));
    let d = analyze_dump(&dump);
    assert_eq!(d["ctes"][0], "x");
}

#[test]
fn flags_select_into_and_data_modifying_ctes() {
    let into = "({RAWSTMT :stmt {SELECTSTMT :intoClause {INTOCLAUSE :rel <>} }})";
    assert_eq!(analyze_dump(into)["writes"], true);
    let dml = "({RAWSTMT :stmt {SELECTSTMT :intoClause <> :withClause {INSERTSTMT :relation <>} }})";
    assert_eq!(analyze_dump(dml)["writes"], true);
}

#[test]
fn counts_statements_and_rejects_non_select_kinds() {
    let two = format!("({} {})",
        "{RAWSTMT :stmt {SELECTSTMT :intoClause <>}}",
        "{RAWSTMT :stmt {SELECTSTMT :intoClause <>}}");
    assert_eq!(analyze_dump(&two)["statements"], 2);
    assert_eq!(analyze_dump(&two)["kind"], "other");

    let update = "({RAWSTMT :stmt {UPDATESTMT :relation <>}})";
    assert_eq!(analyze_dump(update)["kind"], "other");
}

#[test]
fn token_reader_handles_escapes_null_and_empty() {
    assert_eq!(read_token("<> :relname x").0, None);
    assert_eq!(read_token("\"\" :x").0, Some(String::new()));
    assert_eq!(read_token("plain rest").0, Some("plain".into()));
    // outToken escapes embedded delimiters and prefixes a leading digit.
    assert_eq!(read_token("odd\\ name rest").0, Some("odd name".into()));
    assert_eq!(read_token("\\2fast rest").0, Some("2fast".into()));
    assert_eq!(read_token("last}").0, Some("last".into()));
}

#[test]
fn collects_function_names_from_a_funcname_list() {
    // Verified against real PG18 nodeToString output: String nodes inside a
    // List serialise as "name", not as {STRING :sval name}.
    let dump = "({RAWSTMT :stmt {SELECTSTMT :intoClause <> :targetList ({RESTARGET :val \
                {FUNCCALL :funcname (\"pg_sleep\") :args ({A_CONST :val 30})}})}})";
    let d = analyze_dump(dump);
    assert_eq!(d["functions"][0]["name"], "pg_sleep");
    assert!(d["functions"][0]["schema"].is_null());
}

#[test]
fn keeps_the_schema_of_a_qualified_function() {
    let dump = "({RAWSTMT :stmt {SELECTSTMT :intoClause <> \
                :fromClause ({FUNCCALL :funcname (\"pg_catalog\" \"generate_series\") :args <>})}})";
    let d = analyze_dump(dump);
    assert_eq!(d["functions"][0]["schema"], "pg_catalog");
    assert_eq!(d["functions"][0]["name"], "generate_series");
}

#[test]
fn paren_body_stops_at_its_own_closing_paren() {
    assert_eq!(paren_body("\"a\" \"b\") :args (x)"), "\"a\" \"b\"");
    assert_eq!(paren_body("(nested) tail) rest"), "(nested) tail");
}

#[test]
fn quoted_strings_unescapes() {
    assert_eq!(quoted_strings("\"a\" \"b\""), vec!["a", "b"]);
    assert_eq!(quoted_strings("\"od\\\"d\""), vec!["od\"d"]);
    assert!(quoted_strings("no quotes here").is_empty());
}

#[test]
fn node_body_stops_at_its_own_closing_brace() {
    let s = " :alias {ALIAS :aliasname a} :location 3} :trailing";
    assert!(node_body(s).contains(":aliasname a"));
    assert!(!node_body(s).contains(":trailing"));
}

#[test]
fn unparseable_input_is_reported_rather_than_silently_empty() {
    assert_eq!(analyze_dump("")["ok"], false);
}
