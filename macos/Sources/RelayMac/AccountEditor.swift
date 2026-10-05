import SwiftUI

struct AccountEditor: View {
    @ObservedObject var store: RelayStore
    let account: Account
    let theme: ShellTheme
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String
    @ViewState private var failure: String?
    @ViewState private var color: String

    init(store: RelayStore, account: Account, theme: ShellTheme) {
        self.store = store; self.account = account; self.theme = theme
        _name = ViewState(wrappedValue: account.name)
        _color = ViewState(wrappedValue: account.identityColor ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Account identity").font(.system(size: 18, weight: .semibold))
            TextField("Account name", text: $name).textFieldStyle(.roundedBorder).onSubmit { save() }
            Picker("Identity color", selection: $color) {
                ForEach(Productivity.colors, id: \.self) { Text($0.isEmpty ? "Default" : $0).tag($0) }
            }
            if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 380).foregroundStyle(theme.ink).background(theme.base)
    }

    private func save() {
        do { _ = try store.preferences.validatedName(name, serviceID: account.serviceID, excluding: account.id) }
        catch { failure = error.localizedDescription; return }
        if store.rename(account, to: name) { store.setIdentity(account, color: color); dismiss() }
        else { failure = store.error; store.error = nil }
    }
}
