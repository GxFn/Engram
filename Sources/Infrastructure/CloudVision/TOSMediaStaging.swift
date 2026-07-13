import CryptoKit
import Foundation

public struct TOSTemporaryCredentials: Hashable, Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let securityToken: String
    public let expiresAt: Date

    public init(
        accessKeyID: String,
        secretAccessKey: String,
        securityToken: String,
        expiresAt: Date
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.securityToken = securityToken
        self.expiresAt = expiresAt
    }
}

public struct TOSMediaStagingConfiguration: Codable, Hashable, Sendable {
    public let region: LASServiceRegion
    public let bucket: String
    public let objectPrefix: String
    public let partSizeBytes: Int

    public init(
        region: LASServiceRegion,
        bucket: String,
        objectPrefix: String,
        partSizeBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.region = region
        self.bucket = bucket
        self.objectPrefix = objectPrefix
        self.partSizeBytes = max(1, partSizeBytes)
    }
}

public struct TOSUploadedPart: Codable, Hashable, Sendable {
    public let number: Int
    public let eTag: String

    public init(number: Int, eTag: String) {
        self.number = number
        self.eTag = eTag
    }
}

public enum TOSCleanupState: String, Codable, Hashable, Sendable {
    case pending
    case deleted
    case retryRequired
}

/// Restart-safe, non-secret upload state. It contains only opaque provider identity and never a
/// signed URL, credential, local file path or media body.
public struct TOSUploadCheckpoint: Codable, Hashable, Sendable {
    public let sourceFingerprint: String
    public let objectKey: String
    public let uploadID: String
    public let byteCount: Int64
    public let parts: [TOSUploadedPart]
    public let isCompleted: Bool
    public let isVerified: Bool
    public let isProviderReadable: Bool
    public let cleanupState: TOSCleanupState
    public let expiresAt: Date

    public init(
        sourceFingerprint: String,
        objectKey: String,
        uploadID: String,
        byteCount: Int64,
        parts: [TOSUploadedPart],
        isCompleted: Bool,
        isVerified: Bool,
        isProviderReadable: Bool,
        cleanupState: TOSCleanupState,
        expiresAt: Date
    ) {
        self.sourceFingerprint = sourceFingerprint
        self.objectKey = objectKey
        self.uploadID = uploadID
        self.byteCount = byteCount
        self.parts = parts.sorted { $0.number < $1.number }
        self.isCompleted = isCompleted
        self.isVerified = isVerified
        self.isProviderReadable = isProviderReadable
        self.cleanupState = cleanupState
        self.expiresAt = expiresAt
    }

    fileprivate func updating(
        parts: [TOSUploadedPart]? = nil,
        isCompleted: Bool? = nil,
        isVerified: Bool? = nil,
        isProviderReadable: Bool? = nil,
        cleanupState: TOSCleanupState? = nil
    ) -> Self {
        Self(
            sourceFingerprint: sourceFingerprint,
            objectKey: objectKey,
            uploadID: uploadID,
            byteCount: byteCount,
            parts: parts ?? self.parts,
            isCompleted: isCompleted ?? self.isCompleted,
            isVerified: isVerified ?? self.isVerified,
            isProviderReadable: isProviderReadable ?? self.isProviderReadable,
            cleanupState: cleanupState ?? self.cleanupState,
            expiresAt: expiresAt
        )
    }
}

public struct TOSStagedObject: Codable, Hashable, Sendable {
    public let bucket: String
    public let objectKey: String
    public let tosURL: String
    public let byteCount: Int64
    public let expiresAt: Date
}

public struct TOSStagingResult: Codable, Hashable, Sendable {
    public let object: TOSStagedObject
    public let checkpoint: TOSUploadCheckpoint
}

public enum TOSMediaStagingError: Error, Hashable, Sendable {
    case invalidConfiguration(String)
    case temporaryCredentialsExpired
    case consentMismatch
    case sourceMismatch
    case fileUnavailable
    case authenticationRejected
    case rateLimited
    case providerUnavailable(Int)
    case invalidResponse(String)
}

public struct URLSessionTOSMediaStager: Sendable {
    private let configuration: TOSMediaStagingConfiguration
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        configuration: TOSMediaStagingConfiguration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.session = session
        self.now = now
    }

    public func stage(
        fileURL: URL,
        sourceFingerprint: String,
        byteCount: Int64,
        consent: CloudRunConsentReceipt,
        credentials: TOSTemporaryCredentials,
        checkpoint existing: TOSUploadCheckpoint?,
        persistCheckpoint: @escaping @Sendable (TOSUploadCheckpoint) async throws -> Void
    ) async throws -> TOSStagingResult {
        try validate(
            fileURL: fileURL,
            sourceFingerprint: sourceFingerprint,
            byteCount: byteCount,
            consent: consent,
            credentials: credentials
        )
        let objectKey = try deterministicObjectKey(fileURL: fileURL, fingerprint: sourceFingerprint)
        if let existing {
            guard existing.sourceFingerprint == sourceFingerprint,
                  existing.objectKey == objectKey,
                  existing.byteCount == byteCount
            else { throw TOSMediaStagingError.sourceMismatch }
            if existing.isCompleted, existing.isVerified, existing.isProviderReadable {
                return result(checkpoint: existing)
            }
        }

        var checkpoint: TOSUploadCheckpoint
        if let existing {
            checkpoint = existing
        } else {
            checkpoint = try await initiate(
                objectKey: objectKey,
                sourceFingerprint: sourceFingerprint,
                byteCount: byteCount,
                credentials: credentials
            )
        }
        if existing == nil { try await persistCheckpoint(checkpoint) }

        let partCount = Int((byteCount + Int64(configuration.partSizeBytes) - 1)
            / Int64(configuration.partSizeBytes))
        var uploaded = Dictionary(uniqueKeysWithValues: checkpoint.parts.map { ($0.number, $0) })
        for number in 1...partCount where uploaded[number] == nil {
            let offset = Int64(number - 1) * Int64(configuration.partSizeBytes)
            let length = min(Int64(configuration.partSizeBytes), byteCount - offset)
            let part = try await uploadPart(
                fileURL: fileURL,
                objectKey: objectKey,
                uploadID: checkpoint.uploadID,
                number: number,
                offset: offset,
                length: length,
                credentials: credentials
            )
            uploaded[number] = part
            checkpoint = checkpoint.updating(parts: uploaded.values.sorted { $0.number < $1.number })
            try await persistCheckpoint(checkpoint)
        }

        if !checkpoint.isCompleted {
            try await complete(checkpoint, credentials: credentials)
            checkpoint = checkpoint.updating(isCompleted: true)
            try await persistCheckpoint(checkpoint)
        }
        if !checkpoint.isVerified {
            try await verify(checkpoint, credentials: credentials)
            checkpoint = checkpoint.updating(isVerified: true)
            try await persistCheckpoint(checkpoint)
        }
        if !checkpoint.isProviderReadable {
            try await verifyProviderReadability(checkpoint, credentials: credentials)
            checkpoint = checkpoint.updating(isProviderReadable: true)
            try await persistCheckpoint(checkpoint)
        }
        return result(checkpoint: checkpoint)
    }

    /// Best-effort terminal cleanup. Failure is represented explicitly so it can be retried until
    /// the 24-hour object TTL instead of being hidden as a successful cancellation.
    public func cleanup(
        _ checkpoint: TOSUploadCheckpoint,
        credentials: TOSTemporaryCredentials
    ) async -> TOSUploadCheckpoint {
        do {
            var query: [URLQueryItem] = []
            if !checkpoint.isCompleted {
                query = [URLQueryItem(name: "uploadId", value: checkpoint.uploadID)]
            }
            var request = try signedRequest(
                method: "DELETE",
                objectKey: checkpoint.objectKey,
                queryItems: query,
                payloadHash: Self.emptySHA256,
                contentLength: nil,
                body: nil,
                credentials: credentials
            )
            request.timeoutInterval = 20
            _ = try await execute(request, allowedStatuses: 200..<300)
            return checkpoint.updating(cleanupState: .deleted)
        } catch {
            return checkpoint.updating(cleanupState: .retryRequired)
        }
    }

    private func validate(
        fileURL: URL,
        sourceFingerprint: String,
        byteCount: Int64,
        consent: CloudRunConsentReceipt,
        credentials: TOSTemporaryCredentials
    ) throws {
        guard configuration.objectPrefix.hasPrefix("engram/"),
              configuration.objectPrefix.hasSuffix("/"),
              !configuration.bucket.isEmpty,
              configuration.bucket.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { throw TOSMediaStagingError.invalidConfiguration("least-privilege-prefix-or-bucket-invalid") }
        guard credentials.expiresAt > now(),
              !credentials.accessKeyID.isEmpty,
              !credentials.secretAccessKey.isEmpty,
              !credentials.securityToken.isEmpty
        else { throw TOSMediaStagingError.temporaryCredentialsExpired }
        guard consent.sourceFingerprint == sourceFingerprint,
              consent.maximumBytes >= byteCount,
              byteCount > 0
        else { throw TOSMediaStagingError.consentMismatch }
        guard fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let actual = (attributes[.size] as? NSNumber)?.int64Value,
              actual == byteCount
        else { throw TOSMediaStagingError.fileUnavailable }
    }

    private func deterministicObjectKey(fileURL: URL, fingerprint: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !fingerprint.isEmpty,
              fingerprint.unicodeScalars.allSatisfy(allowed.contains)
        else { throw TOSMediaStagingError.invalidConfiguration("source-fingerprint-invalid") }
        let ext = fileURL.pathExtension.lowercased()
        let safeExtension = ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
            ? ext : "bin"
        return "\(configuration.objectPrefix)\(fingerprint).\(safeExtension.isEmpty ? "bin" : safeExtension)"
    }

    private func initiate(
        objectKey: String,
        sourceFingerprint: String,
        byteCount: Int64,
        credentials: TOSTemporaryCredentials
    ) async throws -> TOSUploadCheckpoint {
        let request = try signedRequest(
            method: "POST",
            objectKey: objectKey,
            queryItems: [URLQueryItem(name: "uploads", value: nil)],
            payloadHash: Self.emptySHA256,
            contentLength: 0,
            body: Data(),
            credentials: credentials
        )
        let (data, _) = try await execute(request, allowedStatuses: 200..<300)
        guard let string = String(data: data, encoding: .utf8),
              let start = string.range(of: "<UploadId>")?.upperBound,
              let end = string.range(of: "</UploadId>", range: start..<string.endIndex)?.lowerBound,
              start < end
        else { throw TOSMediaStagingError.invalidResponse("multipart-upload-id-missing") }
        return TOSUploadCheckpoint(
            sourceFingerprint: sourceFingerprint,
            objectKey: objectKey,
            uploadID: String(string[start..<end]),
            byteCount: byteCount,
            parts: [],
            isCompleted: false,
            isVerified: false,
            isProviderReadable: false,
            cleanupState: .pending,
            expiresAt: now().addingTimeInterval(86_400)
        )
    }

    private func uploadPart(
        fileURL: URL,
        objectKey: String,
        uploadID: String,
        number: Int,
        offset: Int64,
        length: Int64,
        credentials: TOSTemporaryCredentials
    ) async throws -> TOSUploadedPart {
        let prepared = try PreparedFilePart(sourceURL: fileURL, offset: offset, length: length)
        defer { prepared.remove() }
        var request = try signedRequest(
            method: "PUT",
            objectKey: objectKey,
            queryItems: [
                URLQueryItem(name: "partNumber", value: String(number)),
                URLQueryItem(name: "uploadId", value: uploadID),
            ],
            payloadHash: prepared.sha256,
            contentLength: length,
            body: nil,
            credentials: credentials
        )
        request.httpBodyStream = InputStream(url: prepared.url)
        let (_, response) = try await execute(request, allowedStatuses: 200..<300)
        guard let eTag = response.value(forHTTPHeaderField: "ETag"), !eTag.isEmpty else {
            throw TOSMediaStagingError.invalidResponse("multipart-etag-missing")
        }
        return TOSUploadedPart(number: number, eTag: eTag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    private func complete(
        _ checkpoint: TOSUploadCheckpoint,
        credentials: TOSTemporaryCredentials
    ) async throws {
        let body = Data((
            "<CompleteMultipartUpload>" + checkpoint.parts.map {
                "<Part><PartNumber>\($0.number)</PartNumber><ETag>\($0.eTag)</ETag></Part>"
            }.joined() + "</CompleteMultipartUpload>"
        ).utf8)
        let request = try signedRequest(
            method: "POST",
            objectKey: checkpoint.objectKey,
            queryItems: [URLQueryItem(name: "uploadId", value: checkpoint.uploadID)],
            payloadHash: Self.sha256(body),
            contentLength: Int64(body.count),
            body: body,
            credentials: credentials
        )
        _ = try await execute(request, allowedStatuses: 200..<300)
    }

    private func verify(
        _ checkpoint: TOSUploadCheckpoint,
        credentials: TOSTemporaryCredentials
    ) async throws {
        let request = try signedRequest(
            method: "HEAD",
            objectKey: checkpoint.objectKey,
            queryItems: [],
            payloadHash: Self.emptySHA256,
            contentLength: nil,
            body: nil,
            credentials: credentials
        )
        let (_, response) = try await execute(request, allowedStatuses: 200..<300)
        guard Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") == checkpoint.byteCount else {
            throw TOSMediaStagingError.invalidResponse("staged-object-size-mismatch")
        }
    }

    private func verifyProviderReadability(
        _ checkpoint: TOSUploadCheckpoint,
        credentials: TOSTemporaryCredentials
    ) async throws {
        var request = try signedRequest(
            method: "GET",
            objectKey: checkpoint.objectKey,
            queryItems: [],
            payloadHash: Self.emptySHA256,
            contentLength: nil,
            body: nil,
            credentials: credentials
        )
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        _ = try await execute(request, allowedStatuses: 200..<300)
    }

    private func result(checkpoint: TOSUploadCheckpoint) -> TOSStagingResult {
        TOSStagingResult(
            object: TOSStagedObject(
                bucket: configuration.bucket,
                objectKey: checkpoint.objectKey,
                tosURL: "tos://\(configuration.bucket)/\(checkpoint.objectKey)",
                byteCount: checkpoint.byteCount,
                expiresAt: checkpoint.expiresAt
            ),
            checkpoint: checkpoint
        )
    }

    private func objectURL(key: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(configuration.bucket).\(configuration.region.TOSEndpointHost)"
        components.path = "/\(key)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw TOSMediaStagingError.invalidConfiguration("object-url-invalid")
        }
        return url
    }

    private func signedRequest(
        method: String,
        objectKey: String,
        queryItems: [URLQueryItem],
        payloadHash: String,
        contentLength: Int64?,
        body: Data?,
        credentials: TOSTemporaryCredentials
    ) throws -> URLRequest {
        guard credentials.expiresAt > now() else {
            throw TOSMediaStagingError.temporaryCredentialsExpired
        }
        var request = URLRequest(url: try objectURL(key: objectKey, queryItems: queryItems))
        request.httpMethod = method
        request.httpBody = body
        if let contentLength { request.setValue(String(contentLength), forHTTPHeaderField: "Content-Length") }
        let timestamp = now()
        let dateTime = Self.format(timestamp, pattern: "yyyyMMdd'T'HHmmss'Z'")
        let date = Self.format(timestamp, pattern: "yyyyMMdd")
        request.setValue(payloadHash, forHTTPHeaderField: "x-tos-content-sha256")
        request.setValue(dateTime, forHTTPHeaderField: "x-tos-date")
        request.setValue(credentials.securityToken, forHTTPHeaderField: "x-tos-security-token")
        let host = request.url?.host ?? ""
        let canonicalHeaders = [
            "host:\(host)",
            "x-tos-content-sha256:\(payloadHash)",
            "x-tos-date:\(dateTime)",
            "x-tos-security-token:\(credentials.securityToken)",
            "",
        ].joined(separator: "\n")
        let signedHeaders = "host;x-tos-content-sha256;x-tos-date;x-tos-security-token"
        let canonicalRequest = [
            method,
            URLComponents(url: request.url ?? URL(string: "https://invalid")!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/",
            Self.canonicalQuery(request.url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(date)/\(configuration.region.rawValue)/tos/request"
        let stringToSign = [
            "TOS4-HMAC-SHA256",
            dateTime,
            scope,
            Self.sha256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let signature = Self.signature(
            secret: credentials.secretAccessKey,
            date: date,
            region: configuration.region.rawValue,
            stringToSign: stringToSign
        )
        request.setValue(
            "TOS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func execute(
        _ request: URLRequest,
        allowedStatuses: Range<Int>
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TOSMediaStagingError.invalidResponse("non-http-response")
        }
        switch http.statusCode {
        case 401, 403: throw TOSMediaStagingError.authenticationRejected
        case 429: throw TOSMediaStagingError.rateLimited
        case 500..<600: throw TOSMediaStagingError.providerUnavailable(http.statusCode)
        case let value where allowedStatuses.contains(value): return (data, http)
        default: throw TOSMediaStagingError.invalidResponse("HTTP \(http.statusCode): tos-request-failed")
        }
    }

    private static let emptySHA256 = sha256(Data())

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalQuery(_ url: URL?) -> String {
        let items = URLComponents(url: url ?? URL(string: "https://invalid")!, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        let encoded: [(String, String)] = items.map {
            (Self.percentEncode($0.name), Self.percentEncode($0.value ?? ""))
        }
        let sorted = encoded.sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        let pairs: [String] = sorted.map { item in item.0 + "=" + item.1 }
        return pairs.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private static func signature(
        secret: String,
        date: String,
        region: String,
        stringToSign: String
    ) -> String {
        func hmac(_ key: Data, _ value: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(
                for: Data(value.utf8),
                using: SymmetricKey(data: key)
            ))
        }
        let dateKey = hmac(Data("TOS4\(secret)".utf8), date)
        let regionKey = hmac(dateKey, region)
        let serviceKey = hmac(regionKey, "tos")
        let signingKey = hmac(serviceKey, "request")
        return hmac(signingKey, stringToSign).map { String(format: "%02x", $0) }.joined()
    }

    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private final class PreparedFilePart: @unchecked Sendable {
    let url: URL
    let sha256: String

    init(sourceURL: URL, offset: Int64, length: Int64) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-tos-part-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TOSMediaStagingError.fileUnavailable
        }
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: url)
        defer {
            try? source.close()
            try? destination.close()
        }
        try source.seek(toOffset: UInt64(offset))
        var remaining = length
        var hasher = SHA256()
        while remaining > 0 {
            let requested = min(Int64(1_024 * 1_024), remaining)
            guard let chunk = try source.read(upToCount: Int(requested)), !chunk.isEmpty else {
                throw TOSMediaStagingError.fileUnavailable
            }
            try destination.write(contentsOf: chunk)
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
