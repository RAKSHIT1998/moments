import Foundation
import Contacts

/// Optional, explicit, one person at a time. MOMENT never imports the address book.
@MainActor
final class ContactsService {
    private let store = CNContactStore()

    var isAuthorized: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized || status == .limited
    }

    func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Fetches the details for a contact the user explicitly picked.
    func contact(identifier: String) -> (name: String, birthday: Date?)? {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactBirthdayKey] as [CNKeyDescriptor]
        guard let c = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys) else { return nil }
        let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let birthday = c.birthday.flatMap { Calendar.current.date(from: $0) }
        return (name, birthday)
    }
}
