import Foundation
import LedgeCore
import LedgeProviders
import LedgeUI
import Testing

@testable import LedgeShell

/// A provider the test drives by hand.
private final class Pump: ActivityProvider {
    let identifier: String
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    init(identifier: String) { self.identifier = identifier }

    func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { self.continuation = $0 }
    }

    func stop() { continuation?.finish(); continuation = nil }

    func publish(_ activity: Activity) { continuation?.yield(.publish(activity)) }
}

/// A feed that starts speaking in the ears while a paused track sits on the
/// queue.
///
/// The shell opens the island from the resting callback and from nowhere
/// else. A paused track is already "present, not playing", and so is a feed
/// with something for the ears — so when the feed began, neither boolean
/// moved, the callback never came, and the island stayed shut over a feed
/// that had asked for it.
@Suite("A feed speaks up beside a paused track", .timeLimit(.minutes(10)))
@MainActor
struct FeedBesidePausedTrackTests {

    @MainActor
    private final class Harness {
        let presentation = NotchPresentation()
        let activities: ActivityCoordinator
        let media = Pump(identifier: "nowplaying")
        let feeds = Pump(identifier: "feeds")
        /// Whether a feed had the ears each time the shell was told.
        var feedRestingAtFact: [Bool] = []

        init() {
            let preferences = Preferences(store: MemoryPreferenceStore())
            preferences.hasCompletedOnboarding = true
            activities = ActivityCoordinator(
                presentation: presentation,
                preferences: preferences,
                isPermitted: { _ in true }
            )
            activities.onNowPlayingChanged = { [weak self] _, _, _ in
                guard let self else { return }
                self.feedRestingAtFact.append(self.presentation.restingFeed != nil)
            }
            activities.register(ProviderRegistration(
                id: "nowplaying", displayName: "Now Playing", kind: .nowPlaying,
                permission: nil, make: { [media] in media }
            ))
            activities.register(ProviderRegistration(
                id: "feeds", displayName: "Feeds", kind: .feeds,
                permission: nil, make: { [feeds] in feeds }
            ))
            activities.startEnabled()
            activities.start()
        }

        func pausedSong() -> Activity {
            Activity(
                id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"),
                createdAt: 0,
                payload: .nowPlaying(NowPlayingPayload(
                    title: "Song", artist: "Artist", isPlaying: false,
                    sourceName: "Spotify", itemKey: "spotify:track:song"
                ))
            )
        }

        func feed(speaking: Bool) -> Activity {
            Activity(
                id: ActivityID(kind: .feeds, source: "limits"),
                createdAt: 0,
                payload: .feeds(FeedPayload(
                    title: "Limits",
                    compactTrailing: speaking ? "59" : nil,
                    compactTrailingFraction: speaking ? 0.59 : nil,
                    compactInterrupts: speaking ? true : nil,
                    updatedAt: speaking ? 2 : 1
                ))
            )
        }

        @discardableResult
        func settle(until arrived: () -> Bool) async -> Bool {
            while !arrived() {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
            }
            return true
        }

        func idle() async {
            for _ in 0 ..< 200 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @Test("The shell hears that the feed took the ears")
    func theFeedIsARestingFact() async {
        let harness = Harness()
        harness.media.publish(harness.pausedSong())
        #expect(await harness.settle(until: { harness.presentation.nowPlaying != nil }))
        harness.feeds.publish(harness.feed(speaking: false))
        #expect(await harness.settle(until: { harness.presentation.count == 2 }))

        harness.feeds.publish(harness.feed(speaking: true))
        #expect(await harness.settle(until: { harness.presentation.restingFeed != nil }))
        await harness.idle()

        // Told at least once with the feed already in the ears; otherwise the
        // shell still believes nothing new rests and never opens the island.
        #expect(harness.feedRestingAtFact.contains(true))
    }

    @Test("And hears when it stops, so the island can close again")
    func theFeedLeavingIsAFactToo() async {
        let harness = Harness()
        harness.media.publish(harness.pausedSong())
        #expect(await harness.settle(until: { harness.presentation.nowPlaying != nil }))
        harness.feeds.publish(harness.feed(speaking: true))
        #expect(await harness.settle(until: { harness.presentation.restingFeed != nil }))
        await harness.idle()
        let before = harness.feedRestingAtFact.count

        var quiet = harness.feed(speaking: false)
        if case .feeds(var payload) = quiet.payload {
            payload.updatedAt = 3
            quiet.payload = .feeds(payload)
        }
        harness.feeds.publish(quiet)
        #expect(await harness.settle(until: { harness.presentation.restingFeed == nil }))
        await harness.idle()

        #expect(harness.feedRestingAtFact.count > before)
        #expect(harness.feedRestingAtFact.last == false)
    }
}
