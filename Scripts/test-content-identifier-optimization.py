#!/usr/bin/env python3
"""Exercise the real content policy with synthetic input at -Onone and -O.

macOS/Xcode command-line tools only; Python uses the standard library. The
production declarations are extracted unchanged, excluding ContentCatalog and
its real metadata. No HTTP, credentials, photographs, or simulator is used.
"""

import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "Yishu/Models/Portfolio.swift"


def extract_policy(source):
    start = "import Foundation\n"
    end = "\nenum ContentCatalog {"
    policy = "\nenum ContentManifestPolicy {"
    if not source.startswith(start) or source.count(end) != 1 or source.count(policy) != 1:
        raise ValueError("Production model/policy extraction anchors changed")
    declarations = source[:source.index(end)]
    required = ("struct Portfolio:", "struct DramaWork:", "struct LaunchPosterContent:",
                "struct AppContentManifest:", "enum ContentManifestPolicy {",
                "static func isValid(_ manifest: AppContentManifest) -> Bool {")
    if any(declarations.count(marker) != 1 for marker in required):
        raise ValueError("Expected production declarations are absent or ambiguous")
    return declarations


PROBE = r'''
@main private struct ContentIdentifierOptimizationProbe {
    private static var checks = 0
    private static var failures = 0
    // URL values are metadata only. Nothing in this probe loads them.
    private static let image = URL(fileURLWithPath: "/synthetic-content-probe.png")

    private static func poster(_ id: String, title: String = "合成海报") -> LaunchPosterContent {
        LaunchPosterContent(id: id, isEnabled: true, imageURL: image,
            eyebrow: "合成说明", title: title, subtitle: "Synthetic subtitle",
            startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 86_400), displaySeconds: 2.5)
    }

    private static func drama(_ id: String, title: String = "合成影视") -> DramaWork {
        DramaWork(id: id, title: title, imageURL: image, destinationURL: image)
    }

    private static func manifest(posters: [LaunchPosterContent] = [],
                                 dramas: [DramaWork] = [],
                                 heroes: [URL]? = nil,
                                 portfolios: [Portfolio] = []) -> AppContentManifest {
        AppContentManifest(schemaVersion: 1, updatedAt: Date(timeIntervalSince1970: 1),
            heroImages: heroes ?? [image], aboutPortraitURL: nil,
            launchPosters: posters, showreel: nil, dramas: dramas,
            portfolios: portfolios, contentAudience: .administrator)
    }

    private static func check(_ label: String, _ value: AppContentManifest, expected: Bool) {
        checks += 1
        if ContentManifestPolicy.isValid(value) != expected {
            failures += 1
            print("FAIL category=\(label)")
        }
    }

    private static func checkIdentifier(_ label: String, _ id: String, expected: Bool) {
        check("poster-\(label)", manifest(posters: [poster(id)]), expected: expected)
        check("drama-\(label)", manifest(dramas: [drama(id)]), expected: expected)
        if !expected {
            check("poster-mixed-\(label)", manifest(posters: [poster("valid-id"), poster(id)]), expected: false)
            check("drama-mixed-\(label)", manifest(dramas: [drama("valid-id"), drama(id)]), expected: false)
        }
    }

    static func main() {
        check("baseline", manifest(), expected: true)
        // Exercise every ASCII scalar, including every allowed character and
        // all controls/punctuation/uppercase characters outside the contract.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        for value in UInt32(0)...127 {
            guard let scalar = UnicodeScalar(value) else { exit(2) }
            let text = String(scalar)
            checkIdentifier("ascii-\(value)", text, expected: allowed.contains(Character(text)))
        }
        let cases: [(String, String, Bool)] = [
            ("all-allowed", "abcdefghijklmnopqrstuvwxyz0123456789-_", true),
            ("mixed", "poster-2026_09", true),
            ("uuid", "00000000-1234-4abc-8def-000000000001", true),
            ("limit-80", String(repeating: "a", count: 80), true),
            ("limit-81", String(repeating: "a", count: 81), false),
            ("empty", "", false),
            ("unicode-han", "合成标题", false),
            ("unicode-mixed", "abc合成", false),
            ("unicode-accent", "café", false),
            ("unicode-combining", "cafe\u{301}", false),
            ("unicode-fullwidth", "ａｂｃ１２３", false),
            ("unicode-emoji", "test😀", false),
            ("unicode-zero-width", "abc\u{200B}def", false),
            ("unicode-control", "abc\u{0085}def", false),
            ("embedded-null", "abc\0def", false),
            ("embedded-newline", "abc\ndef", false),
            ("embedded-tab", "abc\tdef", false),
            ("uppercase", "Poster-ID", false),
            ("uuid-uppercase", "00000000-1234-4ABC-8DEF-000000000001", false),
        ]
        for (label, id, expected) in cases { checkIdentifier(label, id, expected: expected) }

        check("poster-distinct-ids-same-title", manifest(posters: [poster("one"), poster("two")]), expected: true)
        check("drama-distinct-ids-same-title", manifest(dramas: [drama("one"), drama("two")]), expected: true)
        check("poster-duplicate-id", manifest(posters: [poster("one"), poster("one")]), expected: false)
        check("drama-duplicate-id", manifest(dramas: [drama("one"), drama("one")]), expected: false)
        check("hero-duplicate", manifest(heroes: [image, image]), expected: false)
        for (label, title) in [("empty-title", ""), ("blank-title", "   "), ("control-title", "合成\n标题")] {
            check("poster-\(label)", manifest(posters: [poster("one", title: title)]), expected: false)
            check("drama-\(label)", manifest(dramas: [drama("one", title: title)]), expected: false)
        }
        check("poster-title-limit", manifest(posters: [poster("one", title: String(repeating: "字", count: 160))]), expected: true)
        check("poster-title-overlimit", manifest(posters: [poster("one", title: String(repeating: "字", count: 161))]), expected: false)
        check("drama-title-limit", manifest(dramas: [drama("one", title: String(repeating: "字", count: 200))]), expected: true)
        check("drama-title-overlimit", manifest(dramas: [drama("one", title: String(repeating: "字", count: 201))]), expected: false)
        check("poster-count-limit", manifest(posters: (0..<12).map { poster("p-\($0)") }), expected: true)
        check("poster-count-overlimit", manifest(posters: (0..<13).map { poster("p-\($0)") }), expected: false)
        check("drama-count-limit", manifest(dramas: (0..<50).map { drama("d-\($0)") }), expected: true)
        check("drama-count-overlimit", manifest(dramas: (0..<51).map { drama("d-\($0)") }), expected: false)
        let photo = PortfolioImage(id: 1, url: image, fullSizeURL: image, altText: "合成照片")
        let album = Portfolio(id: 1, title: "合成相册", subtitle: "", eyebrow: "", slug: "synthetic",
            websiteURL: image, coverURL: nil, images: [photo])
        check("portfolio-valid", manifest(portfolios: [album]), expected: true)
        check("portfolio-duplicate-id", manifest(portfolios: [album, album]), expected: false)
        let duplicatePhotos = Portfolio(id: 2, title: "合成相册", subtitle: "", eyebrow: "", slug: "synthetic",
            websiteURL: image, coverURL: nil, images: [photo, photo])
        check("portfolio-duplicate-photo-id", manifest(portfolios: [duplicatePhotos]), expected: false)
        print("{\"checks\":\(checks),\"failures\":\(failures)}")
        if failures > 0 { exit(1) }
    }
}
'''


def checked_run(arguments):
    result = subprocess.run(arguments, text=True, capture_output=True, timeout=180, check=False)
    if result.returncode:
        raise RuntimeError(f"Probe command failed ({result.returncode}):\n{result.stdout}{result.stderr}")
    return result.stdout


def verify_source(source):
    declarations = extract_policy(source)
    results = []
    with tempfile.TemporaryDirectory(prefix="shuzi-content-identifiers-") as directory:
        temporary = Path(directory)
        swift = temporary / "ContentIdentifierOptimizationProbe.swift"
        swift.write_text(declarations + "\n" + PROBE, encoding="utf-8")
        for mode in ("-Onone", "-O"):
            executable = temporary / f"probe-{mode[1:]}"
            checked_run(["xcrun", "swiftc", "-parse-as-library", mode, str(swift), "-o", str(executable)])
            output = checked_run([str(executable)])
            summary = json.loads(output.strip())
            if summary.get("failures") != 0 or summary.get("checks", 0) < 400:
                raise RuntimeError("Probe did not complete the expected assertion matrix")
            results.append(summary)
            print(f"PASS {mode}: {summary['checks']} synthetic checks, no failures")
    if results[0] != results[1]:
        raise RuntimeError("Optimized and unoptimized assertion matrices differ")


if __name__ == "__main__":
    verify_source(MODEL.read_text(encoding="utf-8"))
