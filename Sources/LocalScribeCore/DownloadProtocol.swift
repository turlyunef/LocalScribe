import Foundation

@objc public protocol ModelDownloadServiceProtocol {
    func download(_ profileID: String, fileIndex: Int, withReply reply: @escaping (FileHandle?, String?) -> Void)
    func check(withReply reply: @escaping (FileHandle?, String?) -> Void)
    func releaseDownload()
    func cancel()
}
@objc public protocol ModelDownloadProgressProtocol {
    func update(_ message: String)
}
