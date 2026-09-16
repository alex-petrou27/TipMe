#!/usr/bin/env python3
"""Cheap static checks over the Swift sources.

Not a compiler. It catches the classes of mistake that are easy to make when
editing Swift without one: unbalanced delimiters, a type declared twice, and a
reference to a TipMe type that does not exist (a rename left half-applied, or a
helper that was described but never written).

Run:  python3 Scripts/swift-sanity.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIRS = ["Sources", "App", "Tests"]

# Captures the indentation too. Column-0 declarations are the ones eligible for
# the redeclaration check below; nested ones (PaymentReceipt.Status,
# WalletTransaction.Status) are scoped to their enclosing type and Swift allows
# the same name to repeat freely there. Every match, nested or not, still feeds
# the "known types" set used by the reference check — a private nested test
# double is a real, referenceable type within its file.
DECL = re.compile(
    r"^(?P<indent>[ \t]*)(?:(?P<access>public|internal|private|fileprivate|open)\s+|final\s+|@\w+\s+)*"
    r"(?P<kind>struct|class|enum|actor|protocol|extension|typealias)\s+(?P<name>[A-Z][A-Za-z0-9_]*)",
    re.M,
)

# Identifiers that look like ours: PascalCase, and not obviously a framework type.
KNOWN_EXTERNAL = {
    # Swift / Foundation
    "String","Int","Int64","UInt64","Double","Bool","Data","Date","URL","UUID","Error","Void",
    "Array","Set","Dictionary","Optional","Result","Task","Sendable","Equatable","Hashable",
    "Codable","Decodable","Encodable","Comparable","CaseIterable","Identifiable","Never",
    "TimeInterval","JSONEncoder","JSONDecoder","JSONSerialization","FileManager","FileHandle",
    "NSLock","NSRange","NSRegularExpression","NSString","NSNumber","NumberFormatter","Bundle",
    "URLSession","URLRequest","URLResponse","HTTPURLResponse","URLSessionConfiguration",
    "URLSessionTask","URLSessionTaskDelegate","URLError","URLComponents","NSObject","NSNumber",
    "NSDataDetector","NSTextCheckingResult","NSSecureCoding","NSItemProvider","NSExtensionItem",
    "NSAttributedString","CodingKey","CodingKeyRepresentable","RawRepresentable","OSStatus",
    "FileProtectionType","SecRandomCopyBytes","ProcessInfo","Locale","Calendar","IndexSet",
    # Security / CryptoKit / LocalAuthentication
    "SecItemAdd","SecItemDelete","SecItemCopyMatching","CFDictionary","CFTypeRef",
    "Curve25519","SHA256","LAContext","LAError","LABiometryType",
    # UIKit / SwiftUI / UTType / LinkPresentation
    "UIViewController","UIHostingController","UIPasteboard","UIPasteControl","UIColor","UIView",
    "NSLayoutConstraint","UTType","LPLinkMetadata","App","Scene","WindowGroup","View","AnyView",
    "Text","Image","Button","VStack","HStack","ZStack","Spacer","Divider","List","Form","Section",
    "NavigationStack","NavigationLink","LazyVGrid","GridItem","Toggle","Picker","TextField",
    "TextEditor","ProgressView","ShareLink","PasteButton","LabeledContent","Label","Capsule",
    "Circle","RoundedRectangle","Color","Font","Binding","State","StateObject","ObservedObject",
    "Published","ObservableObject","MainActor","ContentUnavailableView","ShapeStyle","EnvironmentObject",
    "UIPasteboardDetectionPattern","ViewBuilder","PreferenceKey","Group","EmptyView",
    # Breez SDK
    "BindingLiquidSdk","LiquidNetwork","ConnectRequest","GetInfoResponse","WalletInfo","AssetBalance",
    "InputType","LnUrlPayRequestData","PrepareLnUrlPayRequest","PrepareLnUrlPayResponse",
    "LnUrlPayRequest","LnUrlPayResult","Payment","PayAmount","Rate","PaymentMethod","ReceiveAmount",
    "PrepareReceiveRequest","ReceivePaymentRequest","BreezSDKLiquid",
    # MnemonicSwift
    "Mnemonic",
    # Breez SDK types confirmed against the real 0.12.4 bindings.
    "PrepareSendResponse","ReceivePaymentResponse","SendPaymentRequest","SendPaymentResponse",
    "ListPaymentsRequest","PrepareReceiveResponse","PrepareSendRequest",
    "UInt32","UInt16","UInt64","Int64","Int32",
    # XCTest
    "XCTestCase","XCTest","XCTAssertEqual","XCTAssertTrue","XCTAssertFalse","XCTAssertNil",
    "XCTAssertNotNil","XCTAssertNotEqual","XCTAssertThrowsError","XCTAssertNoThrow","XCTFail",
    "XCTUnwrap","NSError","UserDefaults",
    # Swift keywords / generic parameter conventions that appear in type position
    "Self","Any","AnyObject","Type","Element","Value","Key","Output","Failure",
    "Content","Body","Label","ID","Wrapped",
    # Module names used as explicit qualifiers (e.g. TipMeCore.Amount), needed
    # here specifically to disambiguate from BreezSDKLiquid's own Amount enum.
    "TipMeCore","BreezSDKLiquid","MnemonicSwift","UIKit","SwiftUI","Foundation",
    "LocalAuthentication","LinkPresentation","UniformTypeIdentifiers","XCTest",
    "CryptoKit","Security","DateComponents",
}

def source_files() -> list[Path]:
    files: list[Path] = []
    for directory in SOURCE_DIRS:
        files.extend((ROOT / directory).rglob("*.swift"))
    return sorted(files)


def check_delimiters(path: Path, text: str) -> list[str]:
    """Balance check that ignores strings and comments."""
    problems = []
    depth = {"{": 0, "(": 0, "[": 0}
    closing = {"}": "{", ")": "(", "]": "["}
    i, n = 0, len(text)
    in_line_comment = in_block_comment = in_string = False
    string_delim = ""
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n": in_line_comment = False
        elif in_block_comment:
            if ch == "*" and nxt == "/": in_block_comment = False; i += 1
        elif in_string:
            if ch == "\\": i += 1
            elif text.startswith(string_delim, i): i += len(string_delim) - 1; in_string = False
        else:
            if ch == "/" and nxt == "/": in_line_comment = True; i += 1
            elif ch == "/" and nxt == "*": in_block_comment = True; i += 1
            elif text.startswith('"""', i): in_string = True; string_delim = '"""'; i += 2
            elif ch == '"': in_string = True; string_delim = '"'
            elif ch in depth: depth[ch] += 1
            elif ch in closing:
                depth[closing[ch]] -= 1
                if depth[closing[ch]] < 0:
                    problems.append(f"{path.relative_to(ROOT)}: unbalanced '{ch}'")
                    depth[closing[ch]] = 0
        i += 1
    for opener, count in depth.items():
        if count != 0:
            problems.append(f"{path.relative_to(ROOT)}: {count} unclosed '{opener}'")
    return problems


def main() -> int:
    files = source_files()
    declared: dict[str, list[str]] = {}
    visible: dict[str, list[str]] = {}
    problems: list[str] = []

    for path in files:
        text = path.read_text()
        problems.extend(check_delimiters(path, text))
        for match in DECL.finditer(text):
            kind, name = match.group("kind"), match.group("name")
            if kind == "extension":
                continue
            declared.setdefault(name, []).append(str(path.relative_to(ROOT)))
            # Only a column-0 (top-level), non-private declaration is eligible
            # for the redeclaration check: a nested type is scoped to its
            # parent regardless of access, and a file-private top-level type
            # may legitimately share a name with one in another file.
            if not match.group("indent") and match.group("access") not in ("private", "fileprivate"):
                visible.setdefault(name, []).append(str(path.relative_to(ROOT)))

    # A non-private type declared twice in one module is a redeclaration error.
    for name, paths in sorted(visible.items()):
        if len(set(paths)) > 1:
            problems.append(f"'{name}' declared in multiple files: {', '.join(sorted(set(paths)))}")

    # References in *type position* only — after a colon, an arrow, `as`/`is`,
    # or inside angle brackets. Matching every capitalised word produces mostly
    # imports, XCTAssert calls and generic parameters, which drowns the signal.
    known = set(declared) | KNOWN_EXTERNAL
    type_position = re.compile(
        r"(?::\s*|->\s*|\bas[!?]?\s+|\bis\s+|<)"
        r"(?:\[|some\s+|any\s+)?([A-Z][A-Za-z0-9_]{2,})"
    )
    unknown: dict[str, set[str]] = {}
    for path in files:
        text = path.read_text()
        text = re.sub(r"//.*", "", text)
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
        text = re.sub(r'"[^"\n]*"', '""', text)
        # Drop import lines: a module name is not a type reference.
        text = re.sub(r"^\s*import\s+.*$", "", text, flags=re.M)
        for name in type_position.findall(text):
            # Foo.Bar -> the root is what must exist.
            root = name.split(".")[0]
            if root not in known:
                unknown.setdefault(root, set()).add(str(path.relative_to(ROOT)))

    print(f"scanned {len(files)} Swift files, {len(declared)} declared types\n")
    if problems:
        print("PROBLEMS")
        for problem in problems:
            print(f"  {problem}")
    else:
        print("no delimiter or redeclaration problems")

    if unknown:
        print(f"\nunrecognised identifiers ({len(unknown)}) — review for typos/renames:")
        for name, paths in sorted(unknown.items()):
            print(f"  {name}: {', '.join(sorted(paths))}")

    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
