//
//  Playlist.swift
//  RWFramework
//
//  Created by Robert Snead on 6/26/18.
//  Copyright © 2018 Roundware. All rights reserved.
//

import Foundation
import CoreLocation
import AVKit
import StreamingKit
import Promises
import SceneKit

struct UserAssetData {
    let lastListen: Date
}

/// TODO: Make each of these optional and provide a default constructor
struct StreamParams {
    let location: CLLocation
    let minDist: Double?
    let maxDist: Double?
    let heading: Double?
    let angularWidth: Double?
}

class Playlist {
    // server communication
    private var lastUpdate: Date? = nil
    private var updateTimer: Timer? = nil
    private(set) var currentParams: StreamParams? = nil
    private(set) var startTime = Date()

    // assets and filters

    private var playlistFilter: AllAssetFilters
    private var trackFilters: [TrackFilter]
    private var sortMethods: [SortMethod]
    private var allAssets = [Asset]()
    private var filteredAssets = [Asset]()
    private var currentAsset: Asset? = nil
    /// Map asset ID to data like last listen time.
    private(set) var userAssetData = [Int: UserAssetData]()

    // audio tracks, background and foreground
    private(set) var speakers = [Speaker]()
    private(set) var tracks = [AudioTrack]()

    private var demoStream: STKAudioPlayer? = nil
    private var demoLooper: LoopAudio? = nil

    private(set) var project: Project!

//    let scene = SCNScene()
    let audioEngine = AVAudioEngine()
    let audioMixer = AVAudioEnvironmentNode()

    init(filters: [AssetFilter], trackFilters: [TrackFilter], sortBy: [SortMethod]) {
        self.playlistFilter = AllAssetFilters(filters)
        self.trackFilters = trackFilters
        self.sortMethods = sortBy

        // Setup audio engine & mixer
        audioEngine.attach(audioMixer)
        audioEngine.connect(audioMixer, to: audioEngine.outputNode, format: nil)
        try! audioEngine.start()
    }
}

extension Playlist {
    func apply(filter: AssetFilter) {
        playlistFilter.filters.append(filter)
    }
    func apply(filter: TrackFilter) {
        self.trackFilters.append(filter)
    }
    
    func lastListenDate(for asset: Asset) -> Date? {
        return self.userAssetData[asset.id]?.lastListen
    }
    
    /// Prepares all the speakers for this project.
    private func updateSpeakers() -> Promise<[Speaker]> {
        return RWFramework.sharedInstance.apiGetSpeakers([
            "project_id": String(project.id),
            "activeyn": "true"
        ]).then { speakers in
            print("playing \(speakers.count) speakers")
            self.speakers = speakers
            self.updateSpeakerVolumes()
        }
    }

    /**
     Update the volumes of all speakers depending on our proximity to each one.
     If the distance to the nearest speaker > outOfRangeDistance, then play demo stream.
    */
    private func updateSpeakerVolumes() {
        print("params = \(self.currentParams)")
        if let params = self.currentParams {
            var playDemo = true
            for speaker in self.speakers {
                let vol = speaker.updateVolume(at: params.location)
                if vol > 0.001 {
                    playDemo = false
                }
            }

            if playDemo {
                self.playDemoStream()
            }
        }
    }

    private func playDemoStream() {
        if currentParams == nil {
            return
        }

        let distToSpeaker = self.speakers.lazy.map {
            $0.distance(to: self.currentParams!.location)
        }.min() ?? 0

        print("dist to nearest speaker: \(distToSpeaker)")
        if distToSpeaker > project.out_of_range_distance {
            if demoStream == nil {
                demoStream = STKAudioPlayer()
            }

            // Only play the out-of-range stream if
            // we're a sufficient distance from all speakers
            if demoStream!.state != .playing {
                demoLooper = LoopAudio(project.out_of_range_url)
                demoStream!.delegate = demoLooper
                demoStream!.play(project.out_of_range_url)
                // TODO: Show a message here telling the user they're out of project range.
                print("out of range")
                RWFramework.sharedInstance.rwUpdateStatus("Out of range!")
            }
        } else if let demoStream = self.demoStream {
            print("demo stream is \(demoStream.state)")
            if demoStream.state == .playing {
                demoLooper = nil
                demoStream.stop()
            }
        }
    }
    
    /// Picks the next-up asset to play on the given track.
    /// Applies all the playlist-level and track-level filters to make the decision.
    func next(forTrack track: AudioTrack) -> Asset? {
        let filteredAssets = self.filteredAssets.filter { asset in
            self.trackFilters.allSatisfy { filter in
                filter.keep(asset, playlist: self, track: track) != .discard
            }
        }

        let next = filteredAssets.first

        // If we've heard them all, play the least recently played.
        // TODO: Or play none here. Depends on project settings, right?
//        if next == nil {
//            next = filteredAssets.min { a, b in
//                if let dataA = userAssetData[a.id], let dataB = userAssetData[b.id] {
//                    // Previously listened to.
//                    return dataA.lastListen < dataB.lastListen
//                    //                    let timeAgo = userData.lastListen.timeIntervalSinceNow
//                    //                    let bannedAge = 60.0 * 20.0 // assets listened within 20 minutes banned
//                    //                    if timeAgo < bannedAge {
//                    //                        return false
//                    //                    }
//                }
//                return true
//            }
//        }
        
        if let next = next {
            userAssetData.updateValue(UserAssetData(lastListen: Date()), forKey: next.id)
        }
        print("picking asset: " + next.debugDescription)
        return next
    }
    
    /// Grab the list of `AudioTrack`s for the current project.
    private func updateTracks() {
        if (self.tracks.isEmpty) {
            let rw = RWFramework.sharedInstance
            
            rw.apiGetAudioTracks([
                "project_id": String(project.id)
            ]).then { data in
                print("assets: using " + data.count.description + " tracks")
                self.tracks = data
                self.tracks.forEach { it in
                    // TODO: Try to remove playlist dependency. Maybe pass into method?
                    it.playlist = self
//                    self.scene.rootNode.addChildNode(it.node)
                    self.audioEngine.attach(it.player)
                    self.audioEngine.connect(it.player, to: self.audioMixer, format: AVAudioFormat(standardFormatWithSampleRate: 96000, channels: 1))
                    it.playNext(premature: false)
                }
            }.catch { err in }
        } else {
            self.tracks.forEach { it in
                if it.currentAsset == nil {
                    it.playNext(premature: false)
                } else {
                    it.updateParams(currentParams!)
                }
            }
        }
    }
    
    /// Retrieve audio assets stored on the server.
    /// At the start of a session, gets all the assets.
    /// After that, only adds the assets uploaded since the last call of this function.
    private func updateAssets() -> Promise<Void> {
        let rw = RWFramework.sharedInstance
        
        var opts = [
            "project_id": String(project.id),
            "media_type": "audio",
            "language": "en",
            "submitted": "true"
        ]
        // Only grab assets added since the last update
        if let date = lastUpdate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dateFormatter.locale = Locale.init(identifier: "en_US_POSIX")
            opts["created__gte"] = dateFormatter.string(from: date)
        }
        
        return rw.apiGetAssets(opts).then { data -> () in
            self.lastUpdate = Date()
            self.allAssets.append(contentsOf: data)
        }.catch { err in }
    }
    
    /// Framework should call this when stream parameters are updated.
    func updateParams(_ opts: StreamParams) {
        if project == nil {
            return
        }

        print("assets: updating params")
        self.currentParams = opts
        self.updateParams()

        if let heading = opts.heading {
            print("current heading angle: \(heading)")
            self.audioMixer.listenerAngularOrientation = AVAudio3DAngularOrientation(
                yaw: Float(heading),
                pitch: 0,
                roll: 0
            )
        }
        let pos = opts.location.toAudioPoint()
        self.audioMixer.listenerPosition = pos
        self.audioMixer.position = pos
        print("current listener position: \(pos)")
    }
    
    private func updateParams() {
        let prevFiltered = filteredAssets
        
        print("assets: updating speakers")
        updateSpeakerVolumes()

        var filtered = Array(allAssets.lazy.map { item in
            (item, self.playlistFilter.keep(item, playlist: self))
        }.filter { (item, rank) in
            rank != .discard
        })
        for sortMethod in sortMethods {
            filtered.sort(by: { a, b in
                sortMethod.sortRanking(for: a.0, in: self) < sortMethod.sortRanking(for: b.0, in: self)
            })
        }
        filtered.sort { a, b in a.1.rawValue < b.1.rawValue }

        filteredAssets = filtered.map { x in x.0 }
        print("[assets] filtered: \(filteredAssets.count), total: \(allAssets.count)")
        
        // Clear data for assets we've moved away from.
        prevFiltered.forEach { a in
            if (!filteredAssets.contains { b in a.id == b.id }) {
                userAssetData.removeValue(forKey: a.id)
                // stop a playing asset if we move away from it.
               self.tracks.first { it in
                   it.currentAsset?.id == a.id
               }?.playNext(premature: true)
            }
        }
        
        // Tell our tracks to play any new assets.
        self.updateTracks()
    }
    
    /// Periodically check for newly published assets
    @objc private func heartbeat() {
        self.updateAssets().then {
            // Update filtered assets given any newly uploaded assets
            self.updateParams()

            let locRequested = RWFramework.sharedInstance.requestWhenInUseAuthorizationForLocation()
            print("location requested? \(locRequested)")
        }
    }
    
    func start() {
        // Starts a session and retrieves project-wide config.
        RWFramework.sharedInstance.apiStartForClientMixing().then { project in
            self.project = project
            print("project settings: \(project)")
            self.useProjectDefaults()
            self.afterSessionInit()
        }
    }

    private func useProjectDefaults() {
        switch project.ordering {
        case "random":
            self.sortMethods = [SortRandomly()]
        case "by_weight":
            self.sortMethods = [SortByWeight()]
        default: break
        }
    }
    
    /**
     * Retrieve tags to filter by for the current project.
     * Setup the speakers for background audio.
     * Retrieve the list of all assets and check for new assets every few minutes.
    **/
    private func afterSessionInit() {
        // Mark start of the session
        startTime = Date()
        
        // Start playing background music from speakers.
        updateSpeakers()
        
        updateTimer = Timer(
            timeInterval: project.asset_refresh_interval,
            target: self,
            selector: #selector(self.heartbeat),
            userInfo: nil,
            repeats: true
        )
        // Initial grab of assets and speakers.
        updateTimer?.fire()

        RWFramework.sharedInstance.isPlaying = true
    }
    
    func pause() {
        RWFramework.sharedInstance.isPlaying = false
        for s in speakers { s.pause() }
        for t in tracks { t.pause() }
        if demoLooper != nil {
            demoStream?.pause()
        }
    }
    
    func resume() {
        RWFramework.sharedInstance.isPlaying = true
        for s in speakers { s.resume() }
        for t in tracks { t.resume() }
        if demoLooper != nil {
            demoStream?.resume()
        }
    }
    
    func skip() {
        // Fade out the currently playing assets on all tracks.
        for t in tracks {
            t.playNext(premature: true)
        }
    }
}


extension CLLocation {
    func bearingToLocationRadian(_ destinationLocation: CLLocation) -> Double {
        
        let lat1 = self.coordinate.latitude.degreesToRadians
        let lon1 = self.coordinate.longitude.degreesToRadians
        
        let lat2 = destinationLocation.coordinate.latitude.degreesToRadians
        let lon2 = destinationLocation.coordinate.longitude.degreesToRadians
        
        let dLon = lon2 - lon1
        
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)
        
        return radiansBearing
    }
    
    func bearingToLocationDegrees(_ destinationLocation: CLLocation) -> Double {
        return bearingToLocationRadian(destinationLocation).radiansToDegrees
    }

    func toAudioPoint() -> AVAudio3DPoint {
        let coord = self.coordinate
        let mult = 1.0
        return AVAudio3DPoint(
            x: Float(coord.longitude * mult),
            y: 0.0,
            z: -Float(coord.latitude * mult)
        )
    }
}

extension Double {
    var degreesToRadians: Double { return self * .pi / 180 }
    var radiansToDegrees: Double { return self * 180 / .pi }
}
