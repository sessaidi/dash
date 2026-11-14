import DashKitUI
import DashKit
import Foundation
import SwiftData

extension ExtensionHost {
    func preferences(for item: any DashExtension) -> PreferenceStore { PreferenceStore(prefix: item.storagePrefix) }

    /// Rows stored per model type of an extension.
    func dataSummary(for item: any DashExtension) -> [(model: String, count: Int)] {
        item.models.map { model in (String(describing: model), count(model)) }
    }

    private func count<T: PersistentModel>(_ type: T.Type) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type) {
        try? context.delete(model: T.self)
    }

    /// Deletes every row of the extension's models (synced data, reviews, transcripts…).
    func deleteData(for item: any DashExtension) {
        for model in item.models { deleteAll(model) }
        try? context.save()
    }

    /// Removes the extension's secrets and preferences, as if it had never been set up.
    func resetStorage(for item: any DashExtension) {
        item.secrets?.removeAll(item.secretKeys)
        preferences(for: item).removeAll()
    }
}
