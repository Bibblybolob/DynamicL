import WidgetKit
import SwiftUI

@main
struct LyricWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WatchLyricComplication()
        WatchLyricStackWidget()
        WatchKaraokeWidget()
        WatchAlbumWidget()
    }
}
