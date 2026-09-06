import SwiftUI
import WidgetKit
import LyricCore

struct WidgetGalleryView: View {
    @State private var designs = WidgetDesignStore.load()
    @State private var editing: WidgetDesign?
    @State private var search = ""
    @State private var category = "All"
    @AppStorage("widgetStudioFavorites") private var favoriteIDs = ""
    private let categories = ["All", "Favorites", "Dark", "Colorful", "Aesthetic", "Light", "Dynamic"]
    private var palettes: [WidgetPalette] {
        WidgetPaletteCatalog.all.filter { palette in
            (category == "All" || category == palette.category || (category == "Favorites" && favoriteIDs.split(separator: ",").contains(Substring(palette.id)))) &&
            (search.isEmpty || palette.name.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your music.\nYour canvas.").font(.largeTitle.bold())
                    Text("Start with a palette or a layout. Save a design, then choose it in Edit Widget.").foregroundStyle(.secondary)
                }
                if !designs.isEmpty {
                    Text("My Designs").font(.title2.bold())
                    ForEach(designs) { design in
                        Button { editing = design } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 10).fill(design.resolvedStyle.palette["accent"].color).frame(width: 38, height: 38)
                                VStack(alignment: .leading) {
                                    Text(design.name).font(.headline)
                                    Text(design.resolvedStyle.palette.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right")
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Text("Explore layouts").font(.title2.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(WidgetTemplate.all) { template in
                            Button {
                                create(template: template.id, palette: "midnight", name: template.name)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    WidgetStudioPreview(style: .preset(template: template.id), size: .small, content: .studioSample)
                                    Text(template.name).font(.headline)
                                    Text(template.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(width: 165)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Text("Find your color").font(.title2.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(categories, id: \.self) { value in
                            Button(value) { category = value }.buttonStyle(.bordered).tint(category == value ? .accentColor : .secondary)
                        }
                    }
                }
                ForEach(palettes) { palette in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { create(template: "stack", palette: palette.id, name: palette.name) } label: {
                            WidgetStudioPreview(style: .preset(template: "stack", paletteID: palette.id), size: .medium, content: .studioSample)
                        }.buttonStyle(.plain)
                        HStack {
                            Text(palette.name).font(.headline); Text(palette.category).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                var ids = Set(favoriteIDs.split(separator: ",").map(String.init))
                                if !ids.insert(palette.id).inserted { ids.remove(palette.id) }
                                favoriteIDs = ids.sorted().joined(separator: ",")
                            } label: {
                                Image(systemName: favoriteIDs.split(separator: ",").contains(Substring(palette.id)) ? "heart.fill" : "heart")
                            }.accessibilityLabel("Favorite \(palette.name)")
                        }
                    }
                }
                Button("Import Live Activity Appearance", systemImage: "square.and.arrow.down") { importLegacy() }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Make it a widget", systemImage: "plus.square.dashed").font(.headline)
                    Text("Touch and hold your Home Screen → Edit → Add Widget → OpenLyrics Widgets. Then touch and hold the widget → Edit Widget → Saved design.")
                    Text("Each widget keeps its own selection. Widgets selecting the same design share its edits; duplicate a design to make it independent.")
                    Text("Lock Screen widgets simplify your design for their size. iOS controls tint and background presentation.")
                }.font(.subheadline).foregroundStyle(.secondary).padding().background(.quaternary, in: .rect(cornerRadius: 20))
            }.padding()
        }
        .searchable(text: $search, prompt: "Search 50 palettes")
        .navigationTitle("Widget Studio").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing, onDismiss: { designs = WidgetDesignStore.load() }) { design in
            NavigationStack { WidgetDesignEditorView(design: design) }
        }
    }
    private func create(template: String, palette: String, name: String) {
        var design = WidgetDesign(name: name, appearance: .init())
        design.style = .preset(template: template, paletteID: palette)
        editing = design
    }
    private func importLegacy() {
        let old = LAStyleStore.load()
        var appearance = WidgetAppearance(preset: old.layout == .lyricsFocus ? .lyricsFocus : .minimal)
        appearance.font = old.fontStyle; appearance.showTitle = old.showTrackInfo
        appearance.alignment = old.textAlignment == .center ? .center : .leading
        let palette = LAStyleStore.resolve(prefs: old, albumDominant: nil)
        appearance.accent = palette.accent; appearance.backgroundColor = palette.backgroundBottom
        appearance.background = .gradient
        var design = WidgetDesign(name: "Imported Appearance", appearance: appearance)
        design.style = WidgetStylePrefs(legacy: appearance)
        design.style?.templateID = old.layout == .player ? "nowPlaying" : (old.layout == .lyricsFocus ? "hero" : "minimal")
        design.style?.details.next = old.showNextLine
        design.style?.details.progress = old.showProgressBar
        design.style?.typography.scale = old.lyricScale == .large ? 1.2 : (old.lyricScale == .compact ? 0.85 : 1)
        design.style?.artwork.placement = old.artworkStyle == .hidden ? .hidden : .feature
        design.style?.artwork.shape = old.artworkStyle == .vinyl ? .vinyl : .square
        design.style?.palette.colors["background"] = WidgetColor(palette.backgroundTop)
        design.style?.palette.colors["secondaryBackground"] = WidgetColor(palette.backgroundBottom)
        for role in ["primaryLyric", "secondaryLyric", "songTitle", "artist"] { design.style?.palette.colors[role] = WidgetColor(palette.text) }
        switch old.surfaceStyle {
        case .glass: design.style?.background.treatment = .frosted
        case .neon: design.style?.background.treatment = .neon
        case .paper: design.style?.background.treatment = .paper
        case .outline: design.style?.background.treatment = .outline
        case .gradient: break
        }
        editing = design
    }
}

extension WidgetPresentation {
    static var studioSample: WidgetPresentation {
        var value = WidgetPresentation.preview
        value.isPlaying = true; value.album = "After Hours"
        value.frozenProgress = 0.42; value.elapsedSeconds = 86; value.durationSeconds = 205
        return value
    }
}

struct WidgetStudioPreview: View {
    let style: WidgetStylePrefs
    let size: WidgetTemplateView.Size
    let content: WidgetPresentation
    var mode = "Full color"
    private var accessory: Bool { [.inline, .circular, .rectangular].contains(size) }
    private var width: CGFloat? {
        switch size { case .small: 160; case .circular: 64; case .rectangular: 170; case .inline: 300; default: nil }
    }
    private var height: CGFloat {
        switch size { case .large: 320; case .inline: 28; case .circular: 64; case .rectangular: 76; default: 160 }
    }
    var body: some View {
        WidgetTemplateView(content: content, style: style, size: size, monochrome: accessory || mode != "Full color")
            .padding(accessory ? 5 : 16)
            .frame(width: width, height: height).frame(maxWidth: width == nil ? .infinity : nil)
            .background {
                if !accessory && mode == "Full color" { WidgetStudioBackground(style: style, content: content) }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: accessory ? 12 : 24))
            .overlay(RoundedRectangle(cornerRadius: accessory ? 12 : 24).stroke(.primary.opacity(0.08)))
    }
}

struct WidgetDesignEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WidgetDesign
    @State private var style: WidgetStylePrefs
    @State private var previewSize: WidgetTemplateView.Size = .medium
    @State private var previewMode = "Full color"
    @State private var useCurrent = false
    @State private var section = "Palette"
    @State private var advanced = false
    @State private var errorMessage: String?
    @State private var paletteName = "My Palette"
    @State private var customPalettes = CustomWidgetPaletteStore.load()
    @State private var snapshot = SharedNowPlaying.load()
    @State private var artworkData: Data?
    private let sections = ["Template", "Palette", "Type", "Background", "Artwork", "Details"]

    init(design: WidgetDesign) {
        _draft = State(initialValue: design); _style = State(initialValue: design.resolvedStyle)
    }
    private func presentation(at date: Date) -> WidgetPresentation {
        guard useCurrent, let snapshot else { return .studioSample }
        var value = WidgetPresentation(snapshot: snapshot, at: SharedNowPlaying.widgetPresentationDate(snapshot, at: date))
        value.artworkData = artworkData
        value.isPlaying = SharedNowPlaying.effectiveIsPlaying(snapshot)
        if !value.isPlaying, let elapsed = value.elapsedSeconds, let duration = value.durationSeconds { value.frozenProgress = elapsed / duration; value.progressInterval = nil }
        return value
    }
    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                WidgetStudioPreview(style: style, size: previewSize, content: presentation(at: context.date), mode: previewMode)
                    .frame(maxWidth: .infinity)
            }.padding(.horizontal).padding(.top, 8)
            HStack {
                Picker("Preview size", selection: $previewSize) {
                    ForEach(WidgetTemplateView.Size.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Rendering", selection: $previewMode) {
                    ForEach(["Full color", "Tinted", "No background"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("Current song", isOn: $useCurrent).labelsHidden().accessibilityLabel("Preview current song")
            }.font(.caption).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(sections, id: \.self) { name in
                    Button(name) { section = name }.buttonStyle(.bordered).tint(section == name ? .accentColor : .secondary)
                } }.padding(.horizontal)
            }.padding(.vertical, 8)
            Form {
                Section {
                    TextField("Design name", text: $draft.name)
                    Toggle("Advanced controls", isOn: $advanced)
                }
                editorSection
                Section {
                    Button("Duplicate / Make Independent", systemImage: "doc.on.doc") {
                        draft.id = UUID().uuidString; draft.name = String(draft.name.prefix(50)) + " Copy"; draft.revision = 1
                    }
                } footer: {
                    Text("Save updates widgets selecting this design. Preview edits stay local until Save. Preview sizes are representative; verify system tint, artwork and typography in your actual widgets.")
                }
            }
        }
        .navigationTitle("Edit Design").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold() }
        }
        .onAppear { artworkData = snapshot?.albumImageData ?? snapshot?.albumImageURL.flatMap(ArtworkFileCache.data(for:)) }
        .alert("Couldn’t save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }
    @ViewBuilder private var editorSection: some View {
        switch section {
        case "Template":
            Section("Layout") {
                ForEach(WidgetTemplate.all) { template in
                    Button {
                        if advanced { style.templateID = template.id }
                        else {
                            let palette = style.palette
                            style = .preset(template: template.id, paletteID: palette.id); style.palette = palette
                        }
                    } label: {
                        HStack { VStack(alignment: .leading) { Text(template.name); Text(template.subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); if style.templateID == template.id { Image(systemName: "checkmark") } }
                    }
                }
            }
        case "Palette": paletteSection
        case "Type": typeSection
        case "Background": backgroundSection
        case "Artwork": artworkSection
        default: detailsSection
        }
    }
    private var paletteSection: some View {
        Section {
            Picker("Palette", selection: Binding(get: { style.palette.id }, set: { id in
                style.palette = customPalettes.first { $0.id == id } ?? WidgetPaletteCatalog.find(id)
            })) {
                ForEach(WidgetPaletteCatalog.all + customPalettes) { Text($0.name).tag($0.id) }
                if !WidgetPaletteCatalog.all.contains(where: { $0.id == style.palette.id }) && !customPalettes.contains(where: { $0.id == style.palette.id }) { Text(style.palette.name).tag(style.palette.id) }
            }
            if advanced {
                ForEach(WidgetPalette.roles, id: \.self) { role in
                    HStack {
                        ColorPicker(roleLabel(role), selection: colorBinding(role), supportsOpacity: false)
                        Button { style.palette.colors[role] = WidgetPaletteCatalog.find(style.palette.id)[role] } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).accessibilityLabel("Reset \(roleLabel(role))")
                    }
                }
                TextField("Palette name", text: $paletteName)
                Button("Save Colors as New Palette") {
                    var palette = style.palette; palette.id = UUID().uuidString; palette.name = paletteName; palette.dynamic = nil
                    do {
                        try CustomWidgetPaletteStore.save(palette); customPalettes = CustomWidgetPaletteStore.load(); style.palette = palette
                    } catch { errorMessage = "The palette could not be saved." }
                }
            }
        } header: { Text("Color story") } footer: {
            Text("Custom colors are saved with this design. Save a named palette to reuse it in another design or select it in Edit Widget. Dynamic colors use the cached album hue with a dark contrast layer.")
        }
    }
    private var typeSection: some View {
        Section("Typography") {
            Picker("Font", selection: $style.typography.fontID) { ForEach(WidgetFont.all) { Text($0.name).tag($0.id) } }
            Picker("Weight", selection: $style.typography.weight) { ForEach(WidgetAppearance.Weight.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Alignment", selection: $style.typography.alignment) { ForEach(WidgetAppearance.Alignment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            slider("Lyric size", value: $style.typography.scale, range: 0.7...1.6)
            if advanced {
                Toggle("Uppercase", isOn: $style.typography.uppercase)
                slider("Line spacing", value: $style.typography.lineSpacing, range: 0...12)
                Stepper("Maximum wrapped lines: \(style.typography.maxLines)", value: $style.typography.maxLines, in: 1...6)
                slider("Current opacity", value: $style.typography.currentOpacity, range: 0.5...1)
                slider("Previous opacity", value: $style.typography.previousOpacity, range: 0.15...1)
                slider("Next opacity", value: $style.typography.nextOpacity, range: 0.15...1)
                Picker("Emphasis", selection: $style.typography.emphasis) { ForEach(WidgetStylePrefs.Emphasis.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Subtle shadow", isOn: $style.typography.shadow)
            }
        }
    }
    private var backgroundSection: some View {
        Section {
            Picker("Fill", selection: $style.background.fill) { ForEach(WidgetStylePrefs.Fill.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Treatment", selection: $style.background.treatment) { ForEach(WidgetStylePrefs.Treatment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            if advanced {
                Picker("Direction", selection: $style.background.direction) { ForEach(WidgetStylePrefs.Direction.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Three gradient colors", isOn: $style.background.threeColors)
                slider("Inner corner radius", value: $style.cornerRadius, range: 0...28)
            }
        } header: { Text("Surface") } footer: {
            Text("Frosted layers sit over your widget content. Glow uses static gradients. iOS may remove backgrounds or replace colors in tinted modes.")
        }
    }
    private var artworkSection: some View {
        Section("Album artwork") {
            Picker("Placement", selection: $style.artwork.placement) { ForEach(WidgetStylePrefs.Placement.allCases, id: \.self) { Text(roleLabel($0.rawValue)).tag($0) } }
            Picker("Shape", selection: $style.artwork.shape) { ForEach(WidgetStylePrefs.Shape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            if advanced {
                slider("Artwork size", value: $style.artwork.size, range: 0.6...1.4)
                slider("Opacity", value: $style.artwork.opacity, range: 0...1)
                slider("Darkening", value: $style.artwork.darkening, range: 0...0.85)
                slider("Tint", value: $style.artwork.tint, range: 0...0.8)
                slider("Blur", value: $style.artwork.blur, range: 0...16)
            }
            Text("Artwork layouts use cached covers. Background placement is available across layouts; compact and Lock Screen widgets prioritize lyrics.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var detailsSection: some View {
        Section("Information") {
            Toggle("Song title", isOn: $style.details.title)
            Toggle("Artist", isOn: $style.details.artist)
            Toggle("Album", isOn: $style.details.album)
            Toggle("Previous lyric", isOn: $style.details.previous)
            Toggle("Next lyric", isOn: $style.details.next)
            Toggle("Progress bar", isOn: $style.details.progress)
            if advanced {
                Toggle("Elapsed time", isOn: $style.details.elapsed)
                Toggle("Remaining time", isOn: $style.details.remaining)
                Toggle("Playback icon", isOn: $style.details.playbackIcon)
                Toggle("Quotation marks (Quote layout)", isOn: $style.details.quotes)
            }
            Text("Unavailable metadata is omitted. Small widgets hide previous lyrics; Lock Screen widgets simplify artwork and details.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) { LabeledContent(name, value: value.wrappedValue.formatted(.number.precision(.fractionLength(2)))); Slider(value: value, in: range).accessibilityLabel(name) }
    }
    private func roleLabel(_ role: String) -> String {
        role.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
    private func colorBinding(_ role: String) -> Binding<Color> {
        Binding(get: { style.palette[role].color }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
                style.palette.colors[role] = WidgetColor(RGB(r: Double(r), g: Double(g), b: Double(b)))
                style.palette.dynamic = nil
            }
        })
    }
    private func save() {
        do {
            draft.style = style.normalized
            if try WidgetDesignStore.save(draft) {
                WidgetCenter.shared.reloadTimelines(ofKind: "OpenLyricsCustomHome")
                WidgetCenter.shared.reloadTimelines(ofKind: "OpenLyricsCustomLock")
            }
            dismiss()
        } catch { errorMessage = "Your design wasn’t saved. Please try again." }
    }
}
