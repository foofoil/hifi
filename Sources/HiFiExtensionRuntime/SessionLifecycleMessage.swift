import Foundation

/// 与 extension-kit 的 session.lifecycle v1 JSON 契约对应；不引入宿主对象依赖。
struct SessionLifecycleMessage: Decodable {
    enum Operation: String, Decodable { case close, restore }
    struct Restoration: Decodable {
        let currentItemID: String?
        let position: Double?
    }
    let commandID: String
    let contractVersion: UInt32
    let operation: Operation
    let restoration: Restoration?

    func validate() throws {
        guard commandID == "session.lifecycle", contractVersion == 1 else {
            throw LifecycleMessageError.unsupportedContract
        }
        switch operation {
        case .close:
            guard restoration == nil else { throw LifecycleMessageError.invalidRestoration }
        case .restore:
            guard let restoration,
                  restoration.currentItemID.map({ !$0.isEmpty }) ?? true,
                  restoration.position.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw LifecycleMessageError.invalidRestoration
            }
        }
    }
}

enum LifecycleMessageError: Error {
    case unsupportedContract
    case invalidRestoration
    case activeSession
}
