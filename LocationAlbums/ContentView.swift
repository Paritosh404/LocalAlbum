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
                    Text("Organize media by year and location, adding month folders only when a location spans multiple months.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                statusView

                VStack(spacing: 12) {
                    if organizer.photoAccessGranted {
                        Label("Photos access granted", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await organizer.requestPhotoPermission() }
                        } label: {
                            Label("Allow Photos Access", systemImage: "photo.badge.checkmark")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

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
                    .disabled(organizer.isRunning || !organizer.photoAccessGranted)
                }

                Text("Only media without GPS goes to “Unknown Location”. Temporary lookup failures go to “Location Lookup Pending”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Version 1.7 • Build 8")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

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
            .onAppear {
                organizer.refreshPermission()
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
