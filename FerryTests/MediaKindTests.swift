import AVFoundation
import XCTest
@testable import Ferry

/// PLAN §2.6 media table, DESIGN §6.3–6.8. Real fixtures: the backfilled reel and its resolve edit (M2/S3), the
/// photo + voice note sent through Instagram in M5 (`event_photo_incoming`, `event_voice_incoming`, the own copies in
/// `events_m5_tamo_own_media`, and the bridged `voice_sample.ogg`), and the phone samples shared from the IG app
/// (M2 part 2: `event_reel_live`, `event_reel_live_landscape`, `event_story_live`, `event_post_live`,
/// `event_voice_igapp`; its `voice_igapp.ogg` is a text-to-speech stand-in in the same format: stereo Opus in Ogg, 7 s).
/// Still hand-made from the bridge source (mautrix/meta v0.2609.0
/// `pkg/msgconv/igconv/xma.go`, `from-instagram.go`): the private-account reel, an expired story, a link preview,
/// view-once, and a captioned XMA; each says which function it mirrors.
final class MediaKindTests: XCTestCase {

    // MARK: Real events

    func testRealUnresolvedReelAndItsResolveEdit() throws {
        let unresolved = try Fixture.event("event_reel_unresolved")
        XCTAssertEqual(MessageKind(type: unresolved.type, content: unresolved.content), .share(.reel, .unresolved))
        let preview = MediaInfo(content: unresolved.content)
        XCTAssertEqual(preview.previewURL, "mxc://igm.home.arpa/rjDVCqAboxCeGbrIeHzoHEgy")  // an m.image previews itself
        XCTAssertFalse(preview.isVideo)

        let edit = try XCTUnwrap(Fixture.event("event_reel_resolve_edit").content["m.new_content"])
        XCTAssertEqual(MessageKind(type: "m.room.message", content: edit), .share(.reel, .ready))
        let video = MediaInfo(content: edit)
        XCTAssertTrue(video.isVideo)
        XCTAssertEqual(video.url, "mxc://igm.home.arpa/qfzfnZlXNGlgiHYGVUpxmyYw")
        XCTAssertEqual(video.mimetype, "video/mp4")
        XCTAssertEqual(video.size, 29_429_419)
        XCTAssertEqual(video.width, 720)
        XCTAssertEqual(video.height, 1280)
        XCTAssertEqual(video.previewURL, "mxc://igm.home.arpa/rjDVCqAboxCeGbrIeHzoHEgy")  // the old preview, kept as thumbnail
        XCTAssertNil(video.duration)  // the bridge doesn't say how long a reel is
        XCTAssertEqual(video.externalURL?.host(), "www.instagram.com")
    }

    /// M5 live "Load video" on kivostudio's own backfilled reel: the bridge sends the edit through the double puppet
    /// (`@me`, `fi.mau.double_puppet_source`), so it passes the same-sender rule and swaps the card in place, unlabelled.
    func testRealOwnReelResolvedThroughTheDoublePuppet() throws {
        let events = try Fixture.events("events_m5_kivo_own_resolve")
        XCTAssertEqual(Timeline.reduce([events[0]], me: Fixture.me).first?.kind, .share(.reel, .unresolved))
        let messages = Timeline.reduce(events, me: Fixture.me)
        XCTAssertEqual(messages.count, 1)
        let reel = try XCTUnwrap(messages.first)
        XCTAssertEqual(reel.kind, .share(.reel, .ready))
        XCTAssertTrue(reel.isOwn)
        XCTAssertFalse(reel.isEdited)
        XCTAssertEqual(MediaInfo(content: reel.content).url, "mxc://igm.home.arpa/KCQEYOLketrXHGoZFDTWGEeT")
    }

    /// A backfilled reel has only the link in its caption (S3): no author, no caption text.
    func testRealBackfilledCaptionIsJustTheLink() throws {
        let content = try Fixture.event("event_reel_unresolved").content
        XCTAssertEqual(ShareCaption(html: content["formatted_body"]?.string), ShareCaption())
    }

    /// M5: a JPEG sent from tamoveska's room, as it came back from Instagram into kivostudio's room.
    func testRealBridgedPhoto() throws {
        let event = try Fixture.event("event_photo_incoming")
        XCTAssertEqual(MessageKind(type: event.type, content: event.content), .image)
        let info = MediaInfo(content: event.content)
        XCTAssertEqual(info.previewURL, info.url)
        XCTAssertEqual(info.width, 1200)
        XCTAssertEqual(info.height, 900)
        XCTAssertEqual(info.mimetype, "image/jpeg")
    }

    /// M5 (spike S4): an AAC voice note sent from Matrix comes back from Instagram as Ogg/Opus with an empty waveform,
    /// and its `info.size` is the size *before* the bridge's conversion (32 428 vs 76 974 bytes downloaded).
    func testRealBridgedVoiceNote() throws {
        let event = try Fixture.event("event_voice_incoming")
        XCTAssertEqual(MessageKind(type: event.type, content: event.content), .voice)
        let info = MediaInfo(content: event.content)
        XCTAssertEqual(info.mimetype, "audio/ogg")
        XCTAssertEqual(info.duration, 7291)
        XCTAssertEqual(event.content["org.matrix.msc1767.audio"]?["waveform"]?.array, [])
    }

    /// Our own sends keep what we sent (audio/mp4 voice, the JPEG), so own cards get the same kinds.
    func testRealOwnMediaKinds() throws {
        let messages = Timeline.reduce(try Fixture.events("events_m5_tamo_own_media"), me: Fixture.me)
        XCTAssertEqual(messages.map(\.kind), [.image, .voice])
        XCTAssertEqual(messages.map(\.status), [.delivered, .delivered])
        XCTAssertEqual(MediaInfo(content: messages[1].content).mimetype, "audio/mp4")
    }

    // MARK: Live shares from the IG app (M2 part 2)

    /// Live shares are fetched at once (`disable_xma_always: false`): every one arrives ready, as the media itself, with
    /// the preview image as its thumbnail.
    func testRealLiveSharesArriveReady() throws {
        func kind(_ event: Event) -> MessageKind { MessageKind(type: event.type, content: event.content) }

        let reel = try Fixture.event("event_reel_live")
        XCTAssertEqual(kind(reel), .share(.reel, .ready))
        let reelInfo = MediaInfo(content: reel.content)
        XCTAssertTrue(reelInfo.isVideo)
        XCTAssertEqual(reelInfo.size, 9_919_668)  // 65.6 s, H.264 720×1280 + HE-AAC (ffprobe)
        XCTAssertEqual(reelInfo.previewURL, "mxc://igm.home.arpa/EMxiFthAXmieYXCpJdYWMcRP")
        XCTAssertNil(reel.content["fi.mau.instagram.xma_fetch_status"])

        // A landscape reel: the video is 1276×718 but its preview is portrait (744×1320); the card keeps the reel frame.
        let landscape = try Fixture.event("event_reel_live_landscape")
        XCTAssertEqual(kind(landscape), .share(.reel, .ready))
        XCTAssertEqual(MediaInfo(content: landscape.content).aspect ?? 0, 718.0 / 1276, accuracy: 0.001)

        // A story is a video too (a still story with music: 45 s at 1 fps), with `reel_id`/`reel_owner_id`.
        let story = try Fixture.event("event_story_live")
        XCTAssertEqual(kind(story), .share(.story, .ready))
        XCTAssertTrue(MediaInfo(content: story.content).isVideo)

        // A post is the image itself; for a carousel the bridge picks the shared child (`carousel_share_child_media_id`).
        let post = try Fixture.event("event_post_live")
        XCTAssertEqual(kind(post), .share(.post, .ready))
        let postInfo = MediaInfo(content: post.content)
        XCTAssertFalse(postInfo.isVideo)
        XCTAssertEqual(postInfo.previewURL, postInfo.url)
        XCTAssertEqual(postInfo.aspect ?? 0, 4096.0 / 3075, accuracy: 0.001)
    }

    /// DESIGN §16 Q1, answered by the live samples: the bridge ignores IG's `header_title_text` (the author), so a reel
    /// has no author or caption at all; a post's title is "<handle> <caption…>" (`title_text`, cut at 100 chars); a
    /// story's author is in its URL.
    func testRealLiveCaptions() throws {
        let reel = ShareCaption(content: try Fixture.event("event_reel_live").content)
        XCTAssertEqual(reel, ShareCaption())
        XCTAssertNil(reel.author)

        let story = ShareCaption(content: try Fixture.event("event_story_live").content)
        XCTAssertEqual(story.author, "sample.stories")
        XCTAssertNil(story.caption)

        let post = ShareCaption(content: try Fixture.event("event_post_live").content)
        XCTAssertEqual(post.author, "sample.photos")
        XCTAssertNil(post.title)
        let caption = try XCTUnwrap(post.caption)
        XCTAssertTrue(caption.hasPrefix("Morning light over the harbour"), caption)
        XCTAssertTrue(caption.hasSuffix("Walking the old qu…"), caption)

        // Regression: the HTML alone (as before the live samples) can't tell the handle from the caption.
        let htmlOnly = ShareCaption(html: try Fixture.event("event_post_live").content["formatted_body"]?.string)
        XCTAssertNil(htmlOnly.author)
        XCTAssertTrue(htmlOnly.title?.hasPrefix("sample.photos Morning") == true)
    }

    /// A voice note recorded in the IG app: Ogg/Opus **stereo** 48 kHz (M5's CLI-sent note came back mono), 7.0 s.
    /// `info.size` (35 539) is again the size before the bridge's conversion: the file is 58 368 bytes.
    func testRealIGAppVoiceNotePlays() async throws {
        let event = try Fixture.event("event_voice_igapp")
        XCTAssertEqual(MessageKind(type: event.type, content: event.content), .voice)
        let info = MediaInfo(content: event.content)
        XCTAssertEqual(info.mimetype, "audio/ogg")
        XCTAssertEqual(info.duration, 6997)
        XCTAssertEqual(info.size, 35_539)

        let url = try Fixture.url("voice_igapp", ext: "ogg")
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, 47_997)  // the stand-in, not the event's file
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 7.0, accuracy: 0.05)
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        for _ in 0..<50 where item.status == .unknown { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(item.status, .readyToPlay, item.error.map { "\($0)" } ?? "")
        await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600))
        XCTAssertEqual(player.currentTime().seconds, 4, accuracy: 0.1)
    }

    // MARK: Shares (hand-made from the bridge source)

    /// `wrapXMAItem` + `wrapXMACaption` with every text field filled. Live reels never look like this (they carry only
    /// the link, `testRealLiveCaptions`); it covers XMA kinds that do send `title_text`/`caption_body_text`.
    static let captionedReel: JSON = [
        "msgtype": "m.video",
        "body": "**tidepool.films**\nGolden hour on the reef.\n\n[https://www.instagram.com/reel/DAbc123/](https://www.instagram.com/reel/DAbc123/?id=1_2)",
        "format": "org.matrix.custom.html",
        "formatted_body": "<strong>tidepool.films</strong><p>Golden hour on the reef.<br/>No lights &amp; no &#34;filters&#34;.</p><p><a href=\"https://www.instagram.com/reel/DAbc123/?id=1_2\">https://www.instagram.com/reel/DAbc123/</a></p>",
        "external_url": "https://www.instagram.com/reel/DAbc123/?id=1_2",
        "url": "mxc://igm.home.arpa/handmadeLiveReel",
        "info": ["mimetype": "video/mp4", "size": 12_000_000, "w": 720, "h": 1280,
                 "thumbnail_url": "mxc://igm.home.arpa/handmadeLivePreview", "thumbnail_info": ["mimetype": "image/jpeg", "w": 950, "h": 1688]],
    ]

    /// `fetchXMA` when the fetch fails (a private account the receiver doesn't follow): the preview part stays, with
    /// the failure in `xma_fetch_status`. Still unobserved live (M2 part 2's samples were all public).
    static let privateReel: JSON = [
        "msgtype": "m.image",
        "body": "**wave.house**\nSunset sets at Playa Grande",
        "format": "org.matrix.custom.html",
        "formatted_body": "<strong>wave.house</strong><p>Sunset sets at Playa Grande</p><p><a href=\"https://www.instagram.com/reel/DPriv99/?id=3_4\">https://www.instagram.com/reel/DPriv99/</a></p>",
        "external_url": "https://www.instagram.com/reel/DPriv99/?id=3_4",
        "fi.mau.instagram.xma_fetch_status": "fetch fail",
        "url": "mxc://igm.home.arpa/handmadePrivatePreview",
        "info": ["mimetype": "image/jpeg", "w": 640, "h": 1136],
    ]

    /// `fetchXMAStory` succeeded with a photo story (the live sample was a video story): the URL ends in the numeric
    /// media ID and carries `reel_id` (`isStory`).
    static let story: JSON = [
        "msgtype": "m.image",
        "body": "story",
        "external_url": "https://www.instagram.com/stories/priya.mixes/3456789012345678901?reel_id=4242",
        "url": "mxc://igm.home.arpa/handmadeStory",
        "info": ["mimetype": "image/jpeg", "w": 1080, "h": 1920],
    ]

    func testShareStates() {
        func kind(_ content: JSON) -> MessageKind { MessageKind(type: "m.room.message", content: content) }
        XCTAssertEqual(kind(Self.captionedReel), .share(.reel, .ready))
        XCTAssertEqual(kind(Self.privateReel), .share(.reel, .unavailable))
        // "reupload fail": over the bridge's/homeserver's size cap (S3).
        XCTAssertEqual(kind(Self.privateReel.setting(["fi.mau.instagram.xma_fetch_status"], "reupload fail")), .share(.reel, .tooLarge))
        // "skip" alone isn't a failure (it always comes with unresolved_media; without it there's nothing to resolve).
        XCTAssertEqual(kind(Self.privateReel.setting(["fi.mau.instagram.xma_fetch_status"], "skip")), .share(.reel, .ready))

        XCTAssertEqual(kind(Self.story), .share(.story, .ready))
        // Expired: `fetchXMAStory` can't find the item any more.
        XCTAssertEqual(kind(Self.story.setting(["fi.mau.instagram.xma_fetch_status"], "item not found in response")), .share(.story, .unavailable))

        // A post (`/p/`): an image post, and a video post that plays like a reel.
        let post = Self.privateReel.setting(["fi.mau.instagram.xma_fetch_status"], nil)
            .setting(["external_url"], "https://www.instagram.com/p/DPost42/?id=5_6")
        XCTAssertEqual(kind(post), .share(.post, .ready))
        XCTAssertEqual(kind(post.setting(["msgtype"], "m.video")), .share(.post, .ready))

        // Anything else the bridge can't fetch (a profile, music…): `fetchXMA` says "unrecognized type". Not a
        // "video unavailable": it's shown as what it is, the preview and the link.
        let profile = Self.privateReel.setting(["external_url"], "https://www.instagram.com/tidepool.films/")
            .setting(["fi.mau.instagram.xma_fetch_status"], "unrecognized type")
        XCTAssertEqual(kind(profile), .share(.other, .ready))
    }

    // MARK: Notices and links (hand-made from from-instagram.go)

    func testNoticesTheBridgeSendsInsteadOfMedia() {
        func notice(_ body: String) -> MessageKind { MessageKind(type: "m.room.message", content: ["msgtype": "m.notice", "body": .string(body)]) }
        // `errorToNotice` with ErrTooLargeFile.
        XCTAssertEqual(notice("Too large attachment"), .tooLarge)
        // `makeViewOnceError`: "This %s can only be %s once. Use the Instagram app to view." (viewed / replayed).
        XCTAssertEqual(notice("This image can only be viewed once. Use the Instagram app to view."), .viewOnce)
        XCTAssertEqual(notice("This video can only be replayed once. Use the Instagram app to view."), .viewOnce)
        // Counter-cases: the bridge's other notices stay notices.
        XCTAssertEqual(notice("Failed to transfer attachment"), .notice)
        XCTAssertEqual(notice("Unsupported message. Use the Instagram app to view."), .notice)
    }

    /// `wrapLinkPreview`: a text with a `com.beeper.linkpreviews` entry (keys from mautrix-go `BeeperLinkPreview`).
    func testLinkPreview() throws {
        let content: JSON = [
            "msgtype": "m.text", "body": "https://lowtide.band/annex",
            "com.beeper.linkpreviews": [[
                "matched_url": "https://lowtide.band/annex", "og:url": "https://lowtide.band/annex",
                "og:title": "Lowtide live at The Annex, Nov 14", "og:description": "Tickets",
                "og:image": "mxc://igm.home.arpa/handmadeLinkImage", "og:image:width": 1200, "og:image:height": "630",
            ]],
        ]
        XCTAssertEqual(MessageKind(type: "m.room.message", content: content), .link)
        let preview = try XCTUnwrap(LinkPreview(content: content))
        XCTAssertEqual(preview.url.host(), "lowtide.band")
        XCTAssertEqual(preview.title, "Lowtide live at The Annex, Nov 14")
        XCTAssertEqual(preview.imageURL, "mxc://igm.home.arpa/handmadeLinkImage")
        XCTAssertEqual(preview.aspect ?? 0, 630.0 / 1200, accuracy: 0.001)  // IntOrString: either form
        // Counter-case: an empty list is a plain text.
        let empty = content.setting(["com.beeper.linkpreviews"], [])
        XCTAssertEqual(MessageKind(type: "m.room.message", content: empty), .text)
        XCTAssertNil(LinkPreview(content: empty))
    }

    // MARK: Caption (DESIGN §16 Q1; `wrapXMACaption`, every part optional)

    func testCaptionPartsAndUnescaping() {
        let full = "<blockquote>Reel</blockquote><strong>tidepool.films</strong><br>Original audio<p>Line one<br/>A &amp; B &lt;3 &#39;x&#39;</p><p><a href=\"https://www.instagram.com/reel/X/?id=1\">https://www.instagram.com/reel/X/</a></p>"
        let caption = ShareCaption(html: full)
        XCTAssertEqual(caption.eyebrow, "Reel")
        XCTAssertEqual(caption.title, "tidepool.films")
        XCTAssertEqual(caption.subtitle, "Original audio")
        XCTAssertEqual(caption.caption, "Line one\nA & B <3 'x'")
        XCTAssertEqual(caption.author, "tidepool.films")

        let captioned = ShareCaption(content: Self.captionedReel)
        XCTAssertEqual(captioned.author, "tidepool.films")
        XCTAssertEqual(captioned.caption, "Golden hour on the reef.\nNo lights & no \"filters\".")
        XCTAssertNil(captioned.subtitle)
    }

    /// Outside posts and stories, only a title that is a handle counts as the author; any other title is text.
    func testTitleThatIsNotAHandleIsNoAuthor() {
        let caption = ShareCaption(html: "<strong>Sunset at Playa Grande</strong><p><a href=\"https://www.instagram.com/reel/Y/\">https://www.instagram.com/reel/Y/</a></p>")
        XCTAssertEqual(caption.title, "Sunset at Playa Grande")
        XCTAssertNil(caption.author)
        XCTAssertNil(caption.caption)
        XCTAssertEqual(ShareCaption(html: nil), ShareCaption())
        // A post title that doesn't start with a handle-shaped word stays a title.
        let post: JSON = ["formatted_body": "<strong>¡Hola! from the reef</strong>", "external_url": "https://www.instagram.com/p/Z/"]
        XCTAssertNil(ShareCaption(content: post).author)
        XCTAssertEqual(ShareCaption(content: post).title, "¡Hola! from the reef")
        // A story URL without a handle segment gives no author.
        XCTAssertNil(ShareCaption(content: ["external_url": "https://www.instagram.com/stories/"]).author)
    }

    // MARK: Inbox preview names the author when it's known (mockups: "Sent a reel by @tidepool.films")

    func testPreviewSaysWhoMadeTheShare() throws {
        let room = try InboxTests.portal("!p", receiver: Fixture.kivoLogin)
        func last(_ event: Event, sender: String, ts: Int64) -> String? {
            var event = event
            event.sender = sender
            event.originServerTS = ts
            room.apply(JoinedRoom(timeline: .init(events: [event], limited: false)))
            return Inbox.preview(of: room, me: Fixture.me)?.text
        }
        // A live reel has no author (the bridge drops it).
        XCTAssertEqual(last(try Fixture.event("event_reel_live"), sender: Fixture.tamoGhost, ts: 5), "Sent a reel")
        XCTAssertEqual(last(try Fixture.event("event_story_live"), sender: Fixture.me, ts: 6), "You sent a story by @sample.stories")
        XCTAssertEqual(last(try Fixture.event("event_post_live"), sender: Fixture.tamoGhost, ts: 7), "Sent a post by @sample.photos")
    }

    // MARK: Cache file names (PLAN §2.7: the extension matters to AVFoundation)

    func testCacheFileNames() {
        XCTAssertEqual(MediaCache.fileName(url: "mxc://igm.home.arpa/qfzfnZlXNGlgiHYGVUpxmyYw", mimetype: "video/mp4"), "qfzfnZlXNGlgiHYGVUpxmyYw.mp4")
        XCTAssertEqual(MediaCache.fileName(url: "mxc://igm.home.arpa/RoueWLJThuRbDiYWLaeDolTg", mimetype: "audio/ogg"), "RoueWLJThuRbDiYWLaeDolTg.ogg")
        XCTAssertEqual(MediaCache.fileName(url: "mxc://igm.home.arpa/a", mimetype: "audio/mp4"), "a.m4a")
        XCTAssertEqual(MediaCache.fileName(url: "mxc://igm.home.arpa/a", mimetype: "image/jpeg"), "a.jpg")
        XCTAssertEqual(MediaCache.fileName(url: "mxc://igm.home.arpa/a", mimetype: "audio/ogg; codecs=opus"), "a.ogg")
        XCTAssertEqual(MediaCache.fileName(url: "mxc://igm.home.arpa/a", mimetype: nil), "a.bin")
        // Instagram's CDN links: their file name (the fixtures' fake host, P0).
        XCTAssertEqual(MediaCache.fileName(url: "https://scontent.example.invalid/v/f003.jpg?oe=6AD83F0F", mimetype: "image/jpeg"), "f003.jpg")
        XCTAssertEqual(MediaCache.fileName(url: "https://scontent.example.invalid/v/f012.mp4", mimetype: "audio/mp4"), "f012.m4a")
        // Never a path outside the cache folder, nor a scheme that isn't media.
        XCTAssertNil(MediaCache.fileName(url: "http://igm.home.arpa/a", mimetype: "image/png"))
        XCTAssertNil(MediaCache.fileName(url: "local:1234", mimetype: "image/png"))
        XCTAssertNil(MediaCache.fileName(url: "https://scontent.example.invalid/v/..", mimetype: "image/png"))
        XCTAssertNil(MediaCache.fileName(url: "mxc://igm.home.arpa/../x", mimetype: "image/png"))
        XCTAssertNil(MediaCache.fileName(url: "mxc://igm.home.arpa/", mimetype: "image/png"))
    }

    /// M7: a Matrix sign-out empties `Caches/media`, so the next user can't open this one's downloads. (The test
    /// host is the app, so this also empties the simulator app's cache: it's a cache.)
    @MainActor
    func testClearEmptiesTheMediaFolder() throws {
        try FileManager.default.createDirectory(at: MediaCache.directory, withIntermediateDirectories: true)
        let file = MediaCache.directory.appending(path: "m7test.ogg")
        try Data([1, 2, 3]).write(to: file)
        let cache = MediaCache()
        XCTAssertEqual(cache.localFile("mxc://igm.home.arpa/m7test", mimetype: "audio/ogg"), file)
        cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path()))
        XCTAssertNil(cache.localFile("mxc://igm.home.arpa/m7test", mimetype: "audio/ogg"))
    }

    /// A video or voice note we just uploaded moves into the cache under its `mxc://`, so it opens without a download.
    @MainActor
    func testSentFileMovesIntoTheCache() throws {
        let sent = FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: sent)
        let cache = MediaCache()
        cache.store(file: sent, url: "mxc://igm.home.arpa/m40test", mimetype: "video/quicktime")
        let stored = try XCTUnwrap(cache.localFile("mxc://igm.home.arpa/m40test", mimetype: "video/quicktime"))
        defer { try? FileManager.default.removeItem(at: stored) }
        XCTAssertEqual(stored.lastPathComponent, "m40test.mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sent.path()))
    }

    // MARK: Voice playback on the real bridged file (PLAN P3, spike S4)

    func testRealBridgedVoicePlaysWithAVFoundation() async throws {
        let url = try Fixture.url("voice_sample", ext: "ogg")
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 7.2, accuracy: 0.1)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(Double(file.length) / 48_000, 7.2, accuracy: 0.1)

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        // Ready within a second here and usually on CI, but GitHub's Xcode 27 runner twice left it loading past 5 s with
        // no error (2026-10-21, the test at 10 s and 43 s). With no audio output it never leaves `.unknown` (CLAUDE.md,
        // simulator audio), which says nothing about the file: the checks above decoded it. A real failure is `.failed`.
        for _ in 0..<200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(100)) }
        if item.status == .unknown { throw XCTSkip("AVPlayerItem still loading after 20 s: the host's audio output may not have started") }
        XCTAssertEqual(item.status, .readyToPlay, item.error.map { "\($0)" } ?? "")
        await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600))
        XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.1)
    }
}
