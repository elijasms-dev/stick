import Foundation

public struct StickNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var body: String
    public var appBundleID: String
    public var appName: String
    public var documentID: String
    public var documentTitle: String
    public var anchor: TextAnchor
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), body: String, appBundleID: String, appName: String,
        documentID: String, documentTitle: String, anchor: TextAnchor,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.body = body
        self.appBundleID = appBundleID
        self.appName = appName
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.anchor = anchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
