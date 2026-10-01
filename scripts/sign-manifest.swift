// Signs (or verifies) a release manifest with Ed25519 (CryptoKit), writing <file>.sig as
// base64. The private key comes from AIME_MANIFEST_KEY (base64 raw 32 bytes); the app
// embeds the public key (AppUpdateChecker.manifestPublicKey).
//
//   swift scripts/sign-manifest.swift sign latest.json
//   swift scripts/sign-manifest.swift verify latest.json <public-key-base64>
//   swift scripts/sign-manifest.swift keygen      # prints a new private and public key
import CryptoKit
import Foundation

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private:", key.rawRepresentation.base64EncodedString())
    print("public: ", key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first else { fail("usage: sign <file>") }
    guard let raw = ProcessInfo.processInfo.environment["AIME_MANIFEST_KEY"].flatMap({ Data(base64Encoded: $0) }),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("AIME_MANIFEST_KEY missing or invalid") }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let signature = try key.signature(for: data)
    try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("signed \(path) with \(key.publicKey.rawRepresentation.base64EncodedString())")
case "verify":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let keyData = Data(base64Encoded: rest[1]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("usage: verify <file> <public-key>") }
    let data = try Data(contentsOf: URL(fileURLWithPath: rest[0]))
    let sigText = try String(contentsOfFile: rest[0] + ".sig", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sig = Data(base64Encoded: sigText), key.isValidSignature(sig, for: data) else { fail("signature invalid") }
    print("signature valid")
default:
    fail("usage: sign-manifest.swift keygen | sign <file> | verify <file> <public-key>")
}
