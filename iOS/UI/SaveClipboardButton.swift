import SwiftUI

/// Toolbar button that saves the current iPhone clipboard into history.
struct SaveClipboardButton: View {
    @EnvironmentObject private var store: ClipStore
    @State private var didJustSave = false
    @State private var isShowingNothingToSaveAlert = false

    var body: some View {
        Button(action: saveClipboard) {
            Image(systemName: didJustSave ? "checkmark" : "plus")
                .contentTransition(.symbolEffect(.replace))
        }
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
              store.insert(content) != nil else {
            isShowingNothingToSaveAlert = true
            return
        }
        withAnimation { didJustSave = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { didJustSave = false }
        }
    }
}
