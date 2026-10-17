import Foundation

@objc public protocol ModelDownloadServiceProtocol {
    func download(_ profileID: String, fileIndex: Int, requestID: String, withReply reply: @escaping (FileHandle?, String?) -> Void)
    func check(withReply reply: @escaping (FileHandle?, String?) -> Void)
    func releaseDownload()
    func cancel()
}
@objc public protocol ModelDownloadProgressProtocol {
    func update(_ requestID: String, bytesWritten: Int64)
}
