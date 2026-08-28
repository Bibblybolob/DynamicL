import WidgetKit
import SwiftUI

@main
struct LyricWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CurrentLineWidget()
        AlbumPlayerWidget()
        LyricFocusWidget()
        MinimalLyricsWidget()
        AlbumCardWidget()
        KaraokeFocusWidget()
        LyricsPosterWidget()
        WaveformPlayerWidget()
        AlbumStackWidget()
        LockscreenLyricWidget()
        LockscreenAlbumWidget()
        LockscreenQuoteWidget()
        VinylWidget()
        LyricsLiveActivity()
    }
}
