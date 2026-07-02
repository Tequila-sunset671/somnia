import Foundation

// Lightweight test harness for Somnia's pure logic. Compiled directly with
// swiftc (SwiftPM/XCTest are unavailable under Command Line Tools only) by
// linking all Sources except App.swift together with this file. Run: ./test.sh

var failures = 0
var passed = 0

func check(_ cond: Bool, _ name: String) {
    if cond { passed += 1 }
    else { failures += 1; print("  ✗ \(name)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    if a == b { passed += 1 } else { failures += 1; print("  ✗ \(name): \(a) != \(b)") }
}

// MARK: URL resolution (BrowserState.resolve) — many branches, easy to break.
do {
    let searchGoogle = BrowserState.resolve("hello world")
    check(searchGoogle.absoluteString.hasPrefix(SearchEngine.google.queryPrefix), "resolve: multi-word → search")

    let bareWord = BrowserState.resolve("swift")
    check(bareWord.absoluteString.hasPrefix(SearchEngine.google.queryPrefix), "resolve: single bare word (no dot) → search")

    let domain = BrowserState.resolve("example.com")
    eq(domain.absoluteString, "https://example.com", "resolve: domain → https")

    let explicit = BrowserState.resolve("https://a.com/x")
    eq(explicit.absoluteString, "https://a.com/x", "resolve: explicit https passthrough")

    let local = BrowserState.resolve("localhost:3000")
    eq(local.absoluteString, "http://localhost:3000", "resolve: localhost:port → http")

    let loopback = BrowserState.resolve("127.0.0.1:8080")
    eq(loopback.absoluteString, "http://127.0.0.1:8080", "resolve: 127.x → http")

    let file = BrowserState.resolve("/tmp/report.pdf")
    check(file.isFileURL && file.path == "/tmp/report.pdf", "resolve: absolute path → file URL")
}

// MARK: Search engines
do {
    eq(SearchEngine.google.queryPrefix, "https://www.google.com/search?q=", "engine: google prefix")
    eq(SearchEngine.duckduckgo.queryPrefix, "https://duckduckgo.com/?q=", "engine: ddg prefix")
    eq(SearchEngine(rawValue: "brave"), .brave, "engine: rawValue roundtrip")
    eq(SearchEngine.allCases.count, 4, "engine: four options")
}

// MARK: Wiki-links extraction + dedupe (NotesStore.wikiLinks)
do {
    let links = NotesStore.wikiLinks(in: "See [[Alpha]] and [[Beta]] and [[alpha]] again.")
    eq(links.count, 2, "wikiLinks: dedupes case-insensitively")
    check(links.contains("Alpha") && links.contains("Beta"), "wikiLinks: extracts both titles")
    eq(NotesStore.wikiLinks(in: "no links here").count, 0, "wikiLinks: none when absent")
}

// MARK: Deterministic stable IDs (NotesStore.stableID)
do {
    eq(NotesStore.stableID("notes/a.md"), NotesStore.stableID("notes/a.md"), "stableID: deterministic")
    check(NotesStore.stableID("a") != NotesStore.stableID("b"), "stableID: distinct inputs differ")
}

// MARK: Markdown block parsing (MarkdownView.parse)
do {
    let blocks = MarkdownView.parse("# Title\n\n- item one\n- item two\n> quote\n\nparagraph")
    var headings = 0, bullets = 0, quotes = 0, paras = 0
    for b in blocks {
        switch b {
        case .heading: headings += 1
        case .bullet:  bullets += 1
        case .quote:   quotes += 1
        case .paragraph: paras += 1
        default: break
        }
    }
    eq(headings, 1, "markdown: one heading")
    eq(bullets, 2, "markdown: two bullets")
    eq(quotes, 1, "markdown: one quote")
    eq(paras, 1, "markdown: one paragraph")

    let fenced = MarkdownView.parse("```\ncode line\n```")
    check(fenced.contains { if case .code = $0 { return true }; return false }, "markdown: fenced code block")
}

// MARK: Report
print("")
if failures == 0 {
    print("✓ all \(passed) assertions passed")
    exit(0)
} else {
    print("✗ \(failures) failed, \(passed) passed")
    exit(1)
}
