import XCTest
@testable import VoiceTranslator

/// Tests translation quality using the evaluation test suite from Stream 4.
///
/// These tests require a valid Claude API key (set via ANTHROPIC_API_KEY env var)
/// and network access. They are intended for manual validation, not CI.
///
/// The test suite verifies:
///   - Correct particle usage (ครับ/ค่ะ)
///   - Tonal word selection accuracy
///   - Natural spoken register (ภาษาพูด vs ภาษาเขียน)
///   - Idiom adaptation
///   - No romanization leakage
final class TranslationQualityTests: XCTestCase {

    /// Verifies output contains only Thai script and punctuation — no romanization.
    @MainActor
    func testOutputContainsOnlyThaiScript() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw XCTSkip("ANTHROPIC_API_KEY not set")
        }

        let service = TranslationService()
        service.configure(apiKey: apiKey)

        var collectedText = ""
        service.onPhrase = { collectedText += $0 }

        await service.translate("Hello, how are you?")

        let fullText = service.translatedText
        XCTAssertFalse(fullText.isEmpty, "Translation should not be empty")

        // Check no Latin letters leaked through
        let latinRange = fullText.rangeOfCharacter(from: .letters.subtracting(
            CharacterSet(charactersIn: "\u{0E01}"..."\u{0E5B}") // Thai Unicode block
        ))
        XCTAssertNil(latinRange, "Translation should not contain Latin characters: \(fullText)")
    }

    /// Verifies male speaker gets ครับ particle.
    @MainActor
    func testMaleSpeakerParticle() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw XCTSkip("ANTHROPIC_API_KEY not set")
        }

        let service = TranslationService()
        service.configure(apiKey: apiKey)
        service.speakerGender = .male

        await service.translate("Thank you very much.")

        let text = service.translatedText
        XCTAssertTrue(text.contains("ครับ"), "Male speaker translation should contain ครับ: \(text)")
    }

    /// Verifies female speaker gets ค่ะ particle.
    @MainActor
    func testFemaleSpeakerParticle() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw XCTSkip("ANTHROPIC_API_KEY not set")
        }

        let service = TranslationService()
        service.configure(apiKey: apiKey)
        service.speakerGender = .female

        await service.translate("Thank you very much.")

        let text = service.translatedText
        XCTAssertTrue(text.contains("ค่ะ") || text.contains("คะ"),
                      "Female speaker translation should contain ค่ะ/คะ: \(text)")
    }

    /// Verifies common greetings produce natural Thai equivalents.
    @MainActor
    func testGreetingTranslation() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw XCTSkip("ANTHROPIC_API_KEY not set")
        }

        let service = TranslationService()
        service.configure(apiKey: apiKey)

        await service.translate("Hi there!")

        let text = service.translatedText
        XCTAssertTrue(text.contains("สวัสดี"), "Greeting should contain สวัสดี: \(text)")
    }

    /// Verifies phrase callback produces at least one phrase for short input.
    @MainActor
    func testPhraseEmission() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw XCTSkip("ANTHROPIC_API_KEY not set")
        }

        let service = TranslationService()
        service.configure(apiKey: apiKey)

        var phrases: [String] = []
        service.onPhrase = { phrases.append($0) }

        await service.translate("I would like to order some food please.")

        XCTAssertFalse(phrases.isEmpty, "Should emit at least one phrase")
        let combined = phrases.joined()
        XCTAssertFalse(combined.isEmpty, "Combined phrases should not be empty")
    }
}
