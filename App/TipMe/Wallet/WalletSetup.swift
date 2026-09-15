import Foundation
import MnemonicSwift
import TipMeCore

/// First-run wallet creation and restore.
///
/// Non-custodial means exactly this: the mnemonic is generated on the device,
/// stored only in the device keychain, and never transmitted. TipMe cannot
/// recover it, cannot freeze it, and cannot spend from it. The flip side, which
/// the onboarding UI states plainly rather than burying, is that losing the
/// phrase loses the funds.
///
/// ## On the BIP-39 dependency
///
/// Mnemonic generation and validation come from `MnemonicSwift` rather than
/// being implemented here. This is deliberate. The BIP-39 English wordlist is
/// 2048 specific words in a specific order, and a single wrong entry produces
/// phrases that look valid, generate a working wallet, and cannot be restored
/// in any other wallet — a silent, unrecoverable loss of funds discovered only
/// when someone tries to get their money out. That is not a component to
/// reimplement for convenience. Vet and pin whichever package you settle on;
/// the seam is small enough to swap.
public struct WalletSetup: Sendable {
    private let keychain: WalletKeychain

    public init(keychain: WalletKeychain) {
        self.keychain = keychain
    }

    public enum SetupError: Error, CustomStringConvertible {
        case alreadyExists
        case invalidMnemonic

        public var description: String {
            switch self {
            case .alreadyExists:
                return "A wallet already exists on this device."
            case .invalidMnemonic:
                return "That recovery phrase isn't valid. It should be 12 words from the BIP-39 list."
            }
        }
    }

    /// Generates a new 12-word BIP-39 mnemonic and stores it in the keychain.
    ///
    /// Entropy comes from the library's use of the system CSPRNG. The returned
    /// string is shown to the user exactly once, during onboarding, and is not
    /// logged or persisted anywhere except the keychain.
    @discardableResult
    public func createWallet() throws -> String {
        guard !keychain.hasMnemonic() else { throw SetupError.alreadyExists }
        let mnemonic = try Mnemonic.generateMnemonic(strength: 128) // 128 bits -> 12 words
        try keychain.store(mnemonic: mnemonic)
        return mnemonic
    }

    public func restoreWallet(mnemonic raw: String) throws {
        let normalised = raw.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Validates both the wordlist membership and the checksum, so a typo in
        // a single word is caught here rather than silently opening an empty
        // wallet the user then believes is theirs.
        do {
            try Mnemonic.validate(mnemonic: normalised)
        } catch {
            throw SetupError.invalidMnemonic
        }
        try keychain.store(mnemonic: normalised)
    }

    /// Backed by the keychain, and gated behind biometric confirmation at the
    /// call site in Settings.
    public func revealMnemonic() throws -> String {
        try keychain.loadMnemonic()
    }
}
