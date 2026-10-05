import SwiftUI

struct AccountZoomControl: View {
    @ObservedObject var store: RelayStore
    let account: Account
    let theme: ShellTheme
    @ViewState private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text("\(Int((account.zoom * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.muted).frame(width: 44, height: 28)
        }
        .buttonStyle(ShellButtonStyle(theme: theme))
        .help("Page zoom").accessibilityLabel("Page zoom, \(Int((account.zoom * 100).rounded())) percent")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Page zoom").fontWeight(.semibold)
                    Spacer()
                    Text("\(Int((account.zoom * 100).rounded()))%").monospacedDigit()
                }
                Slider(value: Binding(get: { account.zoom }, set: { store.setZoom(account, to: $0) }),
                       in: 0.5...2, step: 0.05)
                    .accessibilityLabel("Page zoom")
                HStack {
                    Text("50–200%").foregroundStyle(theme.muted)
                    Spacer()
                    Button("Reset") { store.setZoom(account, to: 1) }.disabled(account.zoom == 1)
                }
            }
            .font(.system(size: 12)).padding(16).frame(width: 240)
            .foregroundStyle(theme.ink).tint(theme.accent).background(theme.panel)
        }
    }
}
