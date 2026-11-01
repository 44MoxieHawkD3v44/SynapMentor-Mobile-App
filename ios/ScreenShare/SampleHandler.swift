//
//  SampleHandler.swift
//  ScreenShare
//
//  From LiveKit's Flutter example (livekit_client, example/ios), created by
//  Alex-Dan Bumbu on 04.06.2021. Sends the iPhone's screen to the app, which
//  shares it in the session.
//

import ReplayKit
import OSLog

let broadcastLogger = OSLog(subsystem: "com.synapmentor.screenshare", category: "Broadcast")

class SampleHandler: RPBroadcastSampleHandler {

    private var clientConnection: SocketConnection?
    private var uploader: SampleUploader?

    /// The App Group shared with the app (RTCAppGroupIdentifier in this
    /// extension's Info.plist, the same as the app's).
    private var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String
    }

    var socketFilePath: String {
        guard let group = appGroupIdentifier,
              let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return "" }
        return sharedContainer.appendingPathComponent("rtc_SSFD").path
    }

    override init() {
        super.init()
        if let connection = SocketConnection(filePath: socketFilePath) {
            clientConnection = connection
            setupConnection()

            uploader = SampleUploader(connection: connection)
        }
        observeStopRequest()
        os_log(.debug, log: broadcastLogger, "%{public}s", socketFilePath)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // User has requested to start the broadcast. Setup info from the UI extension can be supplied but optional.
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
        openConnection()
    }

    override func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
    }

    override func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
    }

    override func broadcastFinished() {
        // User has requested to finish the broadcast.
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        clientConnection?.close()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case RPSampleBufferType.video:
            uploader?.send(sample: sampleBuffer)
        default:
            break
        }
    }
}

private extension SampleHandler {

    func setupConnection() {
        clientConnection?.didClose = { [weak self] error in
            os_log(.debug, log: broadcastLogger, "client connection did close \(String(describing: error))")
            self?.finish(error: error)
        }
    }

    func openConnection() {
        let queue = DispatchQueue(label: "broadcast.connectTimer")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard self?.clientConnection?.open() == true else {
                return
            }

            timer.cancel()
        }

        timer.resume()
    }

    /// The app asked to stop sharing (its Stop button, or the session ended).
    func observeStopRequest() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.clientConnection?.close()
                handler.finish(error: nil)
            },
            DarwinNotification.broadcastRequestStop.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Ends the broadcast and tells the app, so it knows sharing stopped
    /// whichever side ended it.
    func finish(error: Error?) {
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        if let error = error {
            finishBroadcastWithError(error)
        } else {
            // the displayed failure message is more user friendly when using NSError instead of Error
            let screenSharingStopped = 10001
            let customError = NSError(
                domain: RPRecordingErrorDomain,
                code: screenSharingStopped,
                userInfo: [NSLocalizedDescriptionKey: "Screen sharing stopped"]
            )
            finishBroadcastWithError(customError)
        }
    }
}
