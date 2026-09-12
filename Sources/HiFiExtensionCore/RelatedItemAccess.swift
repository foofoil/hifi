//
//  RelatedItemAccess.swift
//  HiFiExtensionCore
//
//  Created by 董超 on 2026/9/12.
//

import Foundation

/// 沙盒下读取用户所选文件的同目录关联文件。
/// 直接 open 被沙盒拒绝时，把打开的主文件声明为 primary，经 NSFileCoordinator 关联项
/// 申请一次性读取授权；CUE 与同目录 APE 互读依赖该机制。
public enum RelatedItemAccess {
    public static func readData(at url: URL, relatedTo primary: URL) -> Data? {
        if let data = try? Data(contentsOf: url) {
            return data
        }
        return coordinatedRead(at: url, relatedTo: primary)
    }

    static func coordinatedRead(at url: URL, relatedTo primary: URL) -> Data? {
        let presenter = Presenter(primary: primary, related: url)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            data = try? Data(contentsOf: coordinatedURL)
        }
        return data
    }

    private final class Presenter: NSObject, NSFilePresenter {
        let primaryPresentedItemURL: URL?
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue

        init(primary: URL, related: URL) {
            primaryPresentedItemURL = primary
            presentedItemURL = related
            presentedItemOperationQueue = OperationQueue()
            presentedItemOperationQueue.name = "foofoil.hifi.related-item-access"
            presentedItemOperationQueue.maxConcurrentOperationCount = 1
        }
    }
}
