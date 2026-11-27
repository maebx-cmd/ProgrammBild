import Photos

/// Alles, was die Mediathek verändert. In iOS liegen Fotos immer in der Mediathek;
/// Alben sind Verweise. „Verschieben“ heißt hier: ins Zielalbum aufnehmen und
/// optional aus anderen eigenen Alben entfernen bzw. ausblenden.
enum PhotoLibrary {

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func userAlbums() -> [PHAssetCollection] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let res = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts)
        var out: [PHAssetCollection] = []
        res.enumerateObjects { c, _, _ in if c.canPerform(.addContent) { out.append(c) } }
        return out
    }

    static func fetchMedia(since: Date?, includeVideos: Bool) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var preds: [NSPredicate] = [includeVideos
            ? NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let since { preds.append(NSPredicate(format: "creationDate >= %@", since as NSDate)) }
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        let res = PHAsset.fetchAssets(with: opts)
        var out: [PHAsset] = []
        out.reserveCapacity(res.count)
        res.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    static func assets(_ ids: [String]) -> [PHAsset] {
        let res = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out: [PHAsset] = []
        res.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    /// Löscht aus der Mediathek. iOS zeigt dazu selbst einen Bestätigungsdialog;
    /// die Fotos landen in „Zuletzt gelöscht“ (dort 30 Tage, manuell leeren –
    /// Apps haben darauf keinen Zugriff).
    static func delete(_ ids: [String]) async throws {
        let list = assets(ids)
        guard !list.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(list as NSArray)
        }
    }

    struct MoveOptions {
        var removeFromOtherAlbums = false
        var hide = false
    }

    enum Target { case existing(PHAssetCollection), new(String) }

    static func move(_ ids: [String], to target: Target, options: MoveOptions) async throws {
        let assets = assets(ids)
        guard !assets.isEmpty else { return }

        // 1) Zielalbum auflösen/anlegen
        let album: PHAssetCollection
        switch target {
        case .existing(let c):
            album = c
        case .new(let name):
            var placeholder: PHObjectPlaceholder?
            try await PHPhotoLibrary.shared().performChanges {
                placeholder = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: name)
                    .placeholderForCreatedAssetCollection
            }
            guard let id = placeholder?.localIdentifier,
                  let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
            else { throw CocoaError(.fileWriteUnknown) }
            album = c
        }

        // 2) Andere eigene Alben ermitteln, aus denen entfernt werden soll
        var removals: [(PHAssetCollection, [PHAsset])] = []
        if options.removeFromOtherAlbums {
            var map: [String: (PHAssetCollection, [PHAsset])] = [:]
            for a in assets {
                let containing = PHAssetCollection.fetchAssetCollectionsContaining(a, with: .album, options: nil)
                containing.enumerateObjects { c, _, _ in
                    guard c.localIdentifier != album.localIdentifier,
                          c.assetCollectionSubtype == .albumRegular,
                          c.canPerform(.removeContent) else { return }
                    map[c.localIdentifier, default: (c, [])].1.append(a)
                }
            }
            removals = Array(map.values)
        }

        // 3) Eine Transaktion → ein Bestätigungsdialog von iOS
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
            for (c, list) in removals {
                PHAssetCollectionChangeRequest(for: c)?.removeAssets(list as NSArray)
            }
            if options.hide {
                for a in assets { PHAssetChangeRequest(for: a).isHidden = true }
            }
        }
    }
}
