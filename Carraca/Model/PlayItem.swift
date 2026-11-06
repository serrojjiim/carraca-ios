import Foundation

/// Qué reproducir y, si es VOD, con qué datos guardarlo en "Seguir viendo".
struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var subtitle: String? = nil
    var isLive = false
    var liveStreamId: Int? = nil
    var startMs = 0
    var resume: ResumeTarget? = nil
    /// Directo: lista desde la que se abrió el canal, para cambiar a anterior/siguiente.
    var channels: [LiveStream] = []
    var channelIndex = 0
    var channelURL: ((LiveStream) -> URL)? = nil
    /// Directo: todos los canales de la cuenta (para saltar a un canal reciente de otra categoría).
    var allChannels: [LiveStream] = []
    /// Series: lo que va después (siguiente capítulo automático al acabar).
    var next: (() -> PlayItem?)? = nil
}

extension PlayItem {
    /// Directo: el canal con la lista desde la que se abre (para anterior / siguiente).
    /// nil si no se puede abrir (cuenta M3U sin URL o sin servidor).
    static func live(_ s: LiveStream, in list: [LiveStream], api: XtreamAPI?, all: [LiveStream] = []) -> PlayItem? {
        let urlFor: (LiveStream) -> URL? = { c in c.directURL ?? api?.liveURL(c.id) }
        guard let url = urlFor(s) else { return nil }
        var item = PlayItem(url: url, title: s.label.name, isLive: true, liveStreamId: s.directURL == nil ? s.id : nil)
        let playable = list.filter { urlFor($0) != nil }
        item.channels = playable
        item.channelIndex = playable.firstIndex(of: s) ?? 0
        item.channelURL = { c in urlFor(c)! }
        item.allChannels = all
        return item
    }

    /// Película desde `ms`, con lo necesario para "Seguir viendo".
    static func movie(_ m: VodStream, from ms: Int, api: XtreamAPI) -> PlayItem {
        PlayItem(url: api.movieURL(m), title: m.title, startMs: ms,
                 resume: ResumeTarget(type: "movie", name: m.name, itemId: String(m.id)))
    }

    /// Capítulo, con el siguiente ya preparado (siguiente capítulo automático).
    static func episode(series: SeriesItem, ep: Episode, season s: Int, from ms: Int,
                        api: XtreamAPI, info: SeriesInfo?) -> PlayItem {
        var item = PlayItem(url: api.episodeURL(ep), title: series.title,
                            subtitle: "T\(s) · E\(ep.number) · \(ep.title.cleanTitle)", startMs: ms,
                            resume: ResumeTarget(type: "series", name: series.name, itemId: ep.id, season: s, episode: ep.number))
        if let info, let n = info.episode(after: ep, season: s) {
            item.next = { PlayItem.episode(series: series, ep: n.1, season: n.0, from: 0, api: api, info: info) }
        }
        return item
    }
}

struct ResumeTarget {
    let type: String      // "movie" | "series"
    let name: String      // nombre tal cual lo da el proveedor
    let itemId: String
    var season = 0
    var episode = 0
}
