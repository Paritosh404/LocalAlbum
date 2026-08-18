import SwiftUI

struct ContentView: View {
    @StateObject private var organizer = PhotoAlbumOrganizer()

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue)

                VStack(spacing: 10) {
                    Text("Location Albums")
                        .font(.largeTitle.bold())
                    Text("Organize your library by city, state, and month using the GPS location saved in each photo.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                statusView

                Button {
                    Task { await organizer.organize() }
                } label: {
                    Label(organizer.isRunning ? "Organizing…" : "Organize Photos",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(organizer.isRunning)

                Text("Photos without a usable city are added to “Unknown Location”. Your originals stay in the main library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Location Albums", isPresented: $organizer.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(organizer.alertMessage)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if organizer.isRunning {
            VStack(spacing: 10) {
                ProgressView(value: organizer.progress)
                Text(organizer.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if !organizer.statusText.isEmpty {
            Label(organizer.statusText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
