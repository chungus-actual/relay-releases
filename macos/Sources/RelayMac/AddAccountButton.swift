import SwiftUI

struct AddAccountButton: View {
    let theme: ShellTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add account", systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 148, height: 40)
        }
        .buttonStyle(ShellButtonStyle(theme: theme, primary: true))
        .accessibilityIdentifier("add-account")
    }
}

struct AddAccountPicker: View {
    let services: [Service]
    let theme: ShellTheme
    let add: (Service) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add account").font(.system(size: 18, weight: .semibold))
            Text("Choose a service. Each account has its own sign-in.")
                .font(.system(size: 12)).foregroundStyle(theme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(services) { service in
                    Button { selectedID = service.id } label: {
                        HStack(spacing: 8) {
                            ServiceIcon(id: service.id, size: 20)
                            Text(service.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                        }.padding(10).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(ShellButtonStyle(theme: theme, selected: selectedID == service.id, bordered: true))
                    .accessibilityAddTraits(selectedID == service.id ? .isSelected : [])
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    guard let service = services.first(where: { $0.id == selectedID }) else { return }
                    add(service)
                } label: {
                    Text("Add account").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).frame(height: 32)
                }
                .buttonStyle(ShellButtonStyle(theme: theme, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
        }
        .padding(24).frame(width: 520).foregroundStyle(theme.ink).background(theme.base)
    }
}
