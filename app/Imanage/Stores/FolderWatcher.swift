import Foundation
import CoreServices

// MARK: - FolderWatcher
// bridge-lite の FolderWatcher を imanage 用に適応したもの。
// FSEvents で監視フォルダへのファイル追加を検出し onChange を呼ぶ。
//
// ライフサイクル: FSEventStream の info ポインタは unretained のため、
// 解放前に必ず stop() を呼ぶこと（WatcherStore が管理）。

@MainActor final class FolderWatcher {

    private var streamRef: FSEventStreamRef?
    private let onChange: ([URL]) -> Void

    init(onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange
    }

    func start(at url: URL) {
        stop()

        let pathsArray = [url.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let createFlags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            nil,
            imanageFolderWatcherCallback,
            &context,
            pathsArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,  // 1秒の latency で連続コピーを1回のコールバックにまとめる
            createFlags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        streamRef = stream
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    // MARK: - C コールバックから呼ばれる

    func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        var added: [URL] = []
        for (path, flag) in zip(paths, flags) {
            guard flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }

            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            guard ImanageExtensions.category(forExtension: ext) != nil else { continue }

            // rename（Finder の移動・コピー完了時）はファイルの存在で in/out を判別
            // imanage はファイル追加のみ反応する
            if FileManager.default.fileExists(atPath: path) {
                added.append(url)
            }
        }
        if !added.isEmpty { onChange(added) }
    }
}

// MARK: - FSEvents C callback (file-scope, @convention(c))

private func imanageFolderWatcherCallback(
    _: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    let flagsArray = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

    Task { @MainActor [weak watcher] in
        watcher?.handleEvents(paths: pathsArray, flags: flagsArray)
    }
}
