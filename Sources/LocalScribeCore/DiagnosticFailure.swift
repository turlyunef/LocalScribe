import Foundation

/// Public diagnostic vocabulary shared by the app and the worker protocol.
public enum DiagnosticPhase: String, Codable, Sendable {
    case launch, commandWrite, protocolRead, inputValidation, modelValidation, modelLoad
    case processing, resultValidation, resultWrite, admission, sourceOpen, captureStart, captureStop
}

public struct DiagnosticSystemCode: Codable, Equatable, Sendable {
    public enum Domain: String, Codable, Sendable {
        case cocoa = "NSCocoaErrorDomain"
        case posix = "NSPOSIXErrorDomain"
        case url = "NSURLErrorDomain"
        case osStatus = "NSOSStatusErrorDomain"
        case http = "HTTP"
        case mach = "NSMachErrorDomain"
    }

    public let domain: Domain
    public let code: Int

    public init(domain: Domain, code: Int) {
        self.domain = domain
        self.code = code
    }

    public init?(_ error: Error) {
        let ns = error as NSError
        guard let domain = Domain(rawValue: ns.domain) else { return nil }
        self.domain = domain
        code = ns.code
    }
}

public struct DiagnosticFailure: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case operationFailed, workerLaunch, workerCommandWrite, workerProtocol, workerExit
        case workerSignal, workerMissingCompletion, workerInvalidCommand, workerIsolation, workerSetup
        case invalidInput, modelValidation, modelLoad
        case processingFailed, invalidResult, resultWrite, sizeLimit, storageUnavailable, permissionDenied
    }

    public let code: Code
    public var phase: DiagnosticPhase?
    public let system: DiagnosticSystemCode?

    public init(_ code: Code, phase: DiagnosticPhase? = nil, error: Error? = nil, system: DiagnosticSystemCode? = nil) {
        self.code = code
        self.phase = phase
        self.system = system ?? error.flatMap(DiagnosticSystemCode.init)
    }
}

/// Carries a safe categorization across layers which present their own message.
public struct ClassifiedDiagnosticError: LocalizedError, Sendable {
    public let diagnostic: DiagnosticFailure
    public let message: String

    public init(_ error: Error, code: DiagnosticFailure.Code, phase: DiagnosticPhase,
                fallback: String, preserveScribeMessage: Bool = true) {
        diagnostic = DiagnosticFailure(code, phase: phase, error: error)
        message = preserveScribeMessage ? (error as? ScribeError)?.localizedDescription ?? fallback : fallback
    }

    public init(message: String, diagnostic: DiagnosticFailure) {
        self.message = message
        self.diagnostic = diagnostic
    }

    public var errorDescription: String? { message }
}
