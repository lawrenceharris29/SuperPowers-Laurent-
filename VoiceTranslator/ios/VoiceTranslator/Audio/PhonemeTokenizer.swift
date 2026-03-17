import Foundation

/// Converts Thai IPA phoneme strings into integer token IDs for CoreML model input.
///
/// Uses the phoneme inventory from Gemini's `thai_phonemes.json`, which maps
/// IPA symbols to integer token IDs via the `vocab` dictionary.
///
/// Special tokens:
///   - `<pad>` (0): padding for fixed-length sequences
///   - `<unk>` (1): unknown/unrecognized symbols
///   - ` ` (2): word boundary
///   - `.` (3): syllable boundary
final class PhonemeTokenizer {

    /// Decoded from thai_phonemes.json
    struct PhonemeInventory: Codable {
        let vocab: [String: Int]
        let consonants: ConsonantSet?
        let vowels: VowelSet?
        let tones: [String: String]?

        struct ConsonantSet: Codable {
            let initial: [String]?
            let final: [String]?
        }
        struct VowelSet: Codable {
            let short: [String]?
            let long: [String]?
            let diphthong: [String]?
        }
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

    /// Sorted vocab keys (longest first) for greedy matching
    private var sortedVocabKeys: [String] = []

    /// Max sequence length for model input padding
    var maxSequenceLength: Int = 256

    var padID: Int { inventory?.vocab["<pad>"] ?? 0 }
    var unkID: Int { inventory?.vocab["<unk>"] ?? 1 }

    var isLoaded: Bool { inventory != nil }

    /// Load the phoneme inventory JSON from a file path.
    func loadInventory(from path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw TokenizerError.fileNotFound(path)
        }
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PhonemeInventory.self, from: data)
            inventory = decoded
            buildSortedKeys()
        } catch {
            throw TokenizerError.decodingFailed(error.localizedDescription)
        }
    }

    /// Load from the app bundle (default: thai_phonemes.json).
    func loadInventory(bundle: Bundle = .main, resource: String = "thai_phonemes", ext: String = "json") throws {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else {
            throw TokenizerError.fileNotFound("\(resource).\(ext) in bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PhonemeInventory.self, from: data)
            inventory = decoded
            buildSortedKeys()
        } catch {
            throw TokenizerError.decodingFailed(error.localizedDescription)
        }
    }

    /// Tokenize an IPA phoneme string into token ID array.
    ///
    /// Uses greedy longest-match against the vocab. Syllable dots and word
    /// spaces are preserved as tokens (IDs 3 and 2 respectively).
    ///
    /// Example: "sa˨˩.wat̚˨˩.diː˧" →  [23, 33, 5, 3, 27, 33, 31, 5, 3, 14, 43, 4]
    ///
    /// - Parameter phonemes: IPA phoneme string
    /// - Returns: Array of Int32 token IDs
    func tokenize(_ phonemes: String) throws -> [Int32] {
        guard let inv = inventory else { throw TokenizerError.inventoryNotLoaded }

        var tokenIDs: [Int32] = []
        var i = phonemes.startIndex

        while i < phonemes.endIndex {
            var matched = false

            for key in sortedVocabKeys {
                guard key != "<pad>" && key != "<unk>" else { continue }

                let endIndex = phonemes.index(i, offsetBy: key.count, limitedBy: phonemes.endIndex)
                guard let end = endIndex else { continue }

                if phonemes[i..<end] == key {
                    if let id = inv.vocab[key] {
                        tokenIDs.append(Int32(id))
                    }
                    i = end
                    matched = true
                    break
                }
            }

            if !matched {
                tokenIDs.append(Int32(unkID))
                i = phonemes.index(after: i)
            }
        }

        return tokenIDs
    }

    /// Tokenize and pad to fixed length for CoreML input.
    func tokenizeAndPad(_ phonemes: String) throws -> [Int32] {
        var tokens = try tokenize(phonemes)

        // Truncate if too long
        if tokens.count > maxSequenceLength {
            tokens = Array(tokens.prefix(maxSequenceLength))
        }

        // Pad to fixed length
        let pad = Int32(padID)
        while tokens.count < maxSequenceLength {
            tokens.append(pad)
        }

        return tokens
    }

    // MARK: - Private

    private func buildSortedKeys() {
        guard let inv = inventory else { return }
        // Sort by length descending for greedy longest-match
        sortedVocabKeys = inv.vocab.keys.sorted { $0.count > $1.count }
    }
}
