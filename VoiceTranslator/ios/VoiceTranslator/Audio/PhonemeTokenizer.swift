import Foundation

/// Converts Thai IPA phoneme strings into integer token IDs for CoreML model input.
///
/// Loads a phoneme inventory (JSON mapping) from disk—this will be delivered by
/// Stream 3 (Gemini). The tokenizer handles:
/// - Phoneme-to-ID lookup
/// - Sequence padding/truncation for fixed-length model input
/// - Special tokens (PAD, BOS, EOS, UNK)
final class PhonemeTokenizer {

    struct PhonemeInventory: Codable {
        let phonemes: [String: Int]    // phoneme → token ID
        let padID: Int
        let bosID: Int
        let eosID: Int
        let unkID: Int
        let maxSequenceLength: Int
    }

    enum TokenizerError: LocalizedError {
        case inventoryNotLoaded
        case fileNotFound(String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .inventoryNotLoaded: return "Phoneme inventory not loaded"
            case .fileNotFound(let p): return "Phoneme inventory not found at \(p)"
            case .decodingFailed(let m): return "Failed to decode phoneme inventory: \(m)"
            }
        }
    }

    private var inventory: PhonemeInventory?

    var isLoaded: Bool { inventory != nil }

    /// Load the phoneme inventory JSON from disk.
    ///
    /// Expected JSON format:
    /// ```json
    /// {
    ///   "phonemes": { "k": 1, "aː": 2, "t": 3, ... },
    ///   "padID": 0,
    ///   "bosID": 1,
    ///   "eosID": 2,
    ///   "unkID": 3,
    ///   "maxSequenceLength": 256
    /// }
    /// ```
    func loadInventory(from path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw TokenizerError.fileNotFound(path)
        }
        do {
            let data = try Data(contentsOf: url)
            inventory = try JSONDecoder().decode(PhonemeInventory.self, from: data)
        } catch {
            throw TokenizerError.decodingFailed(error.localizedDescription)
        }
    }

    /// Load from a bundled resource.
    func loadInventory(bundle: Bundle = .main, resource: String = "thai_phonemes", ext: String = "json") throws {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else {
            throw TokenizerError.fileNotFound("\(resource).\(ext) in bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            inventory = try JSONDecoder().decode(PhonemeInventory.self, from: data)
        } catch {
            throw TokenizerError.decodingFailed(error.localizedDescription)
        }
    }

    /// Tokenize an IPA phoneme string into padded token ID array.
    ///
    /// The input phoneme string uses dots as syllable separators and spaces
    /// between words (e.g., "sa˨˩.wat̚˨˩.diː˧ kʰrap̚˦˥").
    ///
    /// - Parameter phonemes: IPA phoneme string
    /// - Returns: Array of Int32 token IDs, padded to `maxSequenceLength`
    func tokenize(_ phonemes: String) throws -> [Int32] {
        guard let inv = inventory else { throw TokenizerError.inventoryNotLoaded }

        // Split on dots and spaces to get individual phoneme tokens
        let symbols = phonemes
            .components(separatedBy: CharacterSet(charactersIn: ". "))
            .filter { !$0.isEmpty }

        var tokenIDs: [Int32] = [Int32(inv.bosID)]

        for symbol in symbols {
            if let id = inv.phonemes[symbol] {
                tokenIDs.append(Int32(id))
            } else {
                // Try to match sub-components (tone marks may be separate)
                let matched = greedyMatch(symbol, inventory: inv)
                tokenIDs.append(contentsOf: matched)
            }
        }

        tokenIDs.append(Int32(inv.eosID))

        // Truncate if too long
        if tokenIDs.count > inv.maxSequenceLength {
            tokenIDs = Array(tokenIDs.prefix(inv.maxSequenceLength - 1))
            tokenIDs.append(Int32(inv.eosID))
        }

        // Pad to fixed length
        while tokenIDs.count < inv.maxSequenceLength {
            tokenIDs.append(Int32(inv.padID))
        }

        return tokenIDs
    }

    /// Greedy left-to-right matching for compound phoneme symbols.
    private func greedyMatch(_ symbol: String, inventory inv: PhonemeInventory) -> [Int32] {
        var result: [Int32] = []
        var remaining = symbol[symbol.startIndex...]

        while !remaining.isEmpty {
            var matched = false
            // Try longest match first (up to 4 characters for IPA + tone)
            for len in stride(from: min(remaining.count, 4), through: 1, by: -1) {
                let end = remaining.index(remaining.startIndex, offsetBy: len)
                let candidate = String(remaining[remaining.startIndex..<end])
                if let id = inv.phonemes[candidate] {
                    result.append(Int32(id))
                    remaining = remaining[end...]
                    matched = true
                    break
                }
            }
            if !matched {
                // Unknown character — use UNK token and advance
                result.append(Int32(inv.unkID))
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
        }
        return result
    }
}
