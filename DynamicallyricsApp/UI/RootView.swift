import SwiftUI
import LyricCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Now Playing")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if model.auth.isConnected {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Disconnect", role: .destructive) {
                                model.disconnect()
                            }
                            .font(.footnote)
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            connectionCard

            if !SpotifyConfig.isConfigured {
                setupCard
            } else if let signature = model.signature, let document = model.lyrics.document {
                nowPlayingBar(signature: signature)
                SyncedLyricsView(document: document, currentIndex: model.lyrics.currentIndex)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                placeholder
            }

            if model.lyrics.document != nil {
                lockScreenToggle
                appearanceLink
                offsetControl
            }

            // Server setup is independent of whether the current track has
            // lyrics. Keeping it outside the document-only controls means a
            // user can configure push before the first successful lookup (or
            // recover a server setup while the current song has no lyrics).
            SyncServerRow()

            #if DEBUG
            demoControls
            #endif
        }
    }

    private var lockScreenToggle: some View {
        Toggle(isOn: Binding(
            get: { model.lockScreenLyricsEnabled },
            set: { model.lockScreenLyricsEnabled = $0 }
        )) {
            Label("Lock Screen & Island lyrics", systemImage: "lock.iphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var appearanceLink: some View {
        NavigationLink {
            AppearanceView()
        } label: {
            Label("Live Activity Style", systemImage: "paintpalette")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    #if DEBUG
    private var demoControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                if model.demoActive {
                    Button("Stop demo") { model.stopDemo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start demo activity") { model.startDemo() }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                }
            }
            .font(.footnote.bold())
            Text(verbatim: "LA enabled=\(model.liveActivity.isEnabled) running=\(model.liveActivity.isRunning)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 12)
    }
    #endif

    private var connectionCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "circle.grid.cross")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(red: 0.11, green: 0.86, blue: 0.36))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.auth.isConnected ? "Connected to Spotify" : "Not connected")
                        .font(.subheadline.weight(.semibold))
                    Text(model.provider?.lastError ?? model.provider?.lastPollSummary ?? (model.auth.isConnected ? "Listening for playback…" : "Sign in to see live lyrics"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.auth.isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        if model.isConnecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect").font(.footnote.bold())
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.11, green: 0.86, blue: 0.36))
                    .disabled(model.isConnecting || !SpotifyConfig.isConfigured)
                }
            }

            if let error = model.connectError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .padding([.horizontal, .top])
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("One-time setup", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Create an app at developer.spotify.com/dashboard")
                Text("2. Add redirect URI: dynamicallyrics://callback")
                Text("3. Paste the Client ID into SpotifyConfig.swift")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func nowPlayingBar(signature: TrackSignature) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.title3)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(signature.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(signature.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.status?.state == .playing {
                    EqualizerBars()
                } else {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.secondary)
                }
            }

            if signature.duration ?? 0 > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(.pink.gradient)
                            .frame(width: max(4, min(geo.size.width, geo.size.width * progressFraction)))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding()
        .padding(.top, 4)
    }

    private var progressFraction: Double {
        guard let duration = model.signature?.duration, duration > 0 else { return 0 }
        return min(1, model.lyrics.displayPosition / duration)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 14) {
            Spacer()
            if model.lyrics.isLoading {
                ProgressView("Fetching lyrics…")
            } else if model.auth.isConnected {
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Play something on Spotify")
                    .foregroundStyle(.secondary)
                if let status = model.lyrics.lookupStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else if model.lyrics.document == nil {
                Image(systemName: "waveform")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Connect Spotify to begin")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var offsetControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .font(.footnote)
            Slider(value: Binding(
                get: { model.offset },
                set: { model.offset = $0 }
            ), in: -5...5, step: 0.25)
            Text("\(model.offset >= 0 ? "+" : "")\(model.offset, specifier: "%.2f")s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding()
    }
}

struct EqualizerBars: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(red: 0.11, green: 0.86, blue: 0.36))
                    .frame(width: 3, height: animating ? 16 : 6)
                    .animation(
                        .easeInOut(duration: Double(0.4 + Double(index) * 0.13)).repeatForever(autoreverses: true),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
