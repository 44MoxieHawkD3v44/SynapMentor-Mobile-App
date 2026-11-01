//
//  DarwinNotificationCenter.swift
//  ScreenShare
//
//  From LiveKit's Flutter example (livekit_client, example/ios).
//  Created by Alex-Dan Bumbu on 23/03/2021.
//  Copyright © 2021 8x8, Inc. All rights reserved.
//

import Foundation

/// The names livekit_client's BroadcastManager listens for and sends.
enum DarwinNotification: String {
    case broadcastStarted = "iOS_BroadcastStarted"
    case broadcastStopped = "iOS_BroadcastStopped"
    case broadcastRequestStop = "iOS_BroadcastRequestStop"
}

class DarwinNotificationCenter {

    static let shared = DarwinNotificationCenter()

    private let notificationCenter: CFNotificationCenter

    init() {
        notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    }

    func postNotification(_ name: DarwinNotification) {
        CFNotificationCenterPostNotification(notificationCenter, CFNotificationName(rawValue: name.rawValue as CFString), nil, nil, true)
    }
}
