import SwiftUI

/// Toolbar button that saves the current iPhone clipboard into history.
struct SaveClipboardButton: View {
    @EnvironmentObject private var store: ClipStore
    let targetPinboard: Pinboard?
    let isCircular: Bool

    @State private var didJustSave = false
    @State private var isShowingNothingToSaveAlert = false

    init(targetPinboard: Pinboard? = nil, isCircular: Bool = false) {
        self.targetPinboard = targetPinboard
        self.isCircular = isCircular
    }

    var body: some View {
        Button(action: saveClipboard) {
            Image(systemName: didJustSave ? "checkmark" : "plus")
                .font(.system(size: isCircular ? 26 : 17, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: isCircular ? 58 : nil, height: isCircular ? 58 : nil)
                .background {
                    if isCircular {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(didJustSave)
        .accessibilityLabel("Save current clipboard")
        .alert("Nothing to Save", isPresented: $isShowingNothingToSaveAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The clipboard is empty or its content could not be saved.")
        }
    }

    private func saveClipboard() {
        guard let content = ClipboardReader.readCurrentContent(),
              let item = store.insert(content) else {
            isShowingNothingToSaveAlert = true
            return
        }
        if let targetPinboard {
            store.assign(item, to: targetPinboard)
        }
        withAnimation { didJustSave = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { didJustSave = false }
        }
    }
}
