import Foundation
import XCTest
@testable import LocalScribeCore

final class DiagnosticFailureTests: XCTestCase {
    func testSystemCodeClassifiesEverySupportedErrorDomain() {
        let pairs: [(String, Int, DiagnosticSystemCode.Domain)] = [
            (NSCocoaErrorDomain, 260, .cocoa),
            (NSPOSIXErrorDomain, 13, .posix),
            (NSURLErrorDomain, -1005, .url),
            (NSOSStatusErrorDomain, 1_852_797_029, .osStatus),
            ("HTTP", 404, .http),
            (NSMachErrorDomain, 268_435_459, .mach)
        ]
        for (domain, code, expected) in pairs {
            XCTAssertEqual(DiagnosticSystemCode(NSError(domain: domain, code: code)),
                           DiagnosticSystemCode(domain: expected, code: code))
        }
    }

    func testSystemCodeRejectsUnknownDomainsAndSwiftErrors() {
        // Значение константы NSCustomErrorDomain, не экспортируемой в Swift этим SDK.
        XCTAssertNil(DiagnosticSystemCode(NSError(domain: "NSCustomErrorDomain", code: 1)))
        XCTAssertNil(DiagnosticSystemCode(NSError(domain: "LocalScribe.UnknownDomain", code: 2)))
        XCTAssertNil(DiagnosticSystemCode(ScribeError.message("Сообщение")))
        XCTAssertNil(DiagnosticSystemCode(CancellationError()))
    }

    func testFailureDerivesSystemCodeFromErrorAndExplicitSystemWins() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 260)
        let derived = DiagnosticFailure(.invalidInput, phase: .sourceOpen, error: cocoa)
        XCTAssertEqual(derived.code, .invalidInput)
        XCTAssertEqual(derived.phase, .sourceOpen)
        XCTAssertEqual(derived.system, DiagnosticSystemCode(domain: .cocoa, code: 260))

        // Явный system имеет приоритет над кодом из ошибки.
        let explicit = DiagnosticFailure(.resultWrite, phase: .resultWrite, error: cocoa,
                                         system: DiagnosticSystemCode(domain: .posix, code: 28))
        XCTAssertEqual(explicit.system, DiagnosticSystemCode(domain: .posix, code: 28))

        XCTAssertNil(DiagnosticFailure(.processingFailed, phase: .processing, error: ScribeError.message("Ошибка")).system)
        let minimal = DiagnosticFailure(.workerExit)
        XCTAssertEqual(minimal.code, .workerExit)
        XCTAssertNil(minimal.phase)
        XCTAssertNil(minimal.system)
    }

    func testFailureCodableRoundTripPreservesCodePhaseAndSystem() throws {
        let populated = DiagnosticFailure(.invalidResult, phase: .resultValidation,
                                          error: NSError(domain: NSPOSIXErrorDomain, code: 75))
        let data = try JSONEncoder().encode(populated)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticFailure.self, from: data), populated)

        let minimal = DiagnosticFailure(.workerProtocol)
        let minimalData = try JSONEncoder().encode(minimal)
        let decoded = try JSONDecoder().decode(DiagnosticFailure.self, from: minimalData)
        XCTAssertEqual(decoded, minimal)
        XCTAssertNil(decoded.phase)
        XCTAssertNil(decoded.system)
    }

    func testClassifiedErrorKeepsScribeMessageAndFallsBackForForeignErrors() {
        let scribe = ClassifiedDiagnosticError(ScribeError.message("Некорректное выравнивание Qwen"),
                                               code: .processingFailed, phase: .processing,
                                               fallback: "Обработка прервана")
        XCTAssertEqual(scribe.message, "Некорректное выравнивание Qwen")
        XCTAssertEqual(scribe.errorDescription, "Некорректное выравнивание Qwen")
        XCTAssertEqual(scribe.diagnostic.code, .processingFailed)
        XCTAssertEqual(scribe.diagnostic.phase, .processing)
        XCTAssertNil(scribe.diagnostic.system)

        let foreign = ClassifiedDiagnosticError(NSError(domain: NSCocoaErrorDomain, code: 4),
                                                code: .invalidInput, phase: .sourceOpen,
                                                fallback: "Не удалось открыть оригинал")
        XCTAssertEqual(foreign.message, "Не удалось открыть оригинал")
        XCTAssertEqual(foreign.errorDescription, "Не удалось открыть оригинал")
        XCTAssertEqual(foreign.diagnostic.code, .invalidInput)
        XCTAssertEqual(foreign.diagnostic.system, DiagnosticSystemCode(domain: .cocoa, code: 4))
    }

    func testClassifiedErrorCanDiscardScribeMessage() {
        let classified = ClassifiedDiagnosticError(ScribeError.message("Сообщение worker"),
                                                   code: .invalidResult, phase: .resultValidation,
                                                   fallback: "Результат не прошёл проверку",
                                                   preserveScribeMessage: false)
        XCTAssertEqual(classified.message, "Результат не прошёл проверку")
        XCTAssertEqual(classified.errorDescription, "Результат не прошёл проверку")
    }

    func testClassifiedErrorDirectInitializerExposesMessageAsErrorDescription() {
        let failure = DiagnosticFailure(.workerLaunch, phase: .launch,
                                        error: NSError(domain: NSPOSIXErrorDomain, code: 2))
        let classified = ClassifiedDiagnosticError(message: "Не удалось запустить worker", diagnostic: failure)
        XCTAssertEqual(classified.message, "Не удалось запустить worker")
        XCTAssertEqual(classified.errorDescription, "Не удалось запустить worker")
        XCTAssertEqual(classified.diagnostic, failure)
    }

    func testDegradedCurrentInputIsUnavailableEvenWhenItMatchesExpectedConfiguration() {
        let expected = CaptureInputConfiguration(deviceID: 7, sampleRate: 0, channels: 1, formatID: 1, formatFlags: 0)
        // Непригодная конфигурация входа отвергается до сравнения с ожидаемой и до учёта движка.
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected: expected, current: expected, engineRunning: true), .inputUnavailable)
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected: expected, current: expected, engineRunning: false), .inputUnavailable)
    }

    func testNonPositiveSampleRateOrChannelsInNonNullCurrentReportUnavailableInput() {
        let expected = CaptureInputConfiguration(deviceID: 7, sampleRate: 48_000, channels: 2, formatID: 1, formatFlags: 0)
        let degraded = [
            CaptureInputConfiguration(deviceID: 7, sampleRate: 0, channels: 2, formatID: 1, formatFlags: 0),
            CaptureInputConfiguration(deviceID: 7, sampleRate: -48_000, channels: 2, formatID: 1, formatFlags: 0),
            CaptureInputConfiguration(deviceID: 7, sampleRate: 48_000, channels: 0, formatID: 1, formatFlags: 0)
        ]
        for current in degraded {
            XCTAssertEqual(CaptureConfigurationAction.evaluate(expected: expected, current: current, engineRunning: true), .inputUnavailable)
            XCTAssertEqual(CaptureConfigurationAction.evaluate(expected: expected, current: current, engineRunning: false), .inputUnavailable)
        }
    }
}
