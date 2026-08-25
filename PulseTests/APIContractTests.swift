import XCTest
@testable import Pulse

final class APIContractTests: XCTestCase {
    func testCelebrityTankBattleFixtureUsesOriginalCreationPromptAndBundledImages() throws {
        let prompt = "生成一个各种名人头像的坦克大战"
        let fileNames = ["abraham-lincoln", "nikola-tesla", "ada-lovelace", "william-shakespeare"]
        let fixtureBundle = Bundle(for: Self.self)

        XCTAssertFalse(prompt.isEmpty)
        XCTAssertEqual(Set(fileNames).count, 4)
        for fileName in fileNames {
            let url = try XCTUnwrap(fixtureBundle.url(forResource: fileName, withExtension: "jpg"), "Missing test fixture: \(fileName).jpg")
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 10_000)
        }
    }

    func testGenerationJobDecodesGoIDKeysAndEmptyCollections() throws {
        let data = Data(#"""
        {
          "id":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
          "workId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "runId":"f9a75473-b507-4e3c-b66a-8d56b796c0dc",
          "instruction":"Build a neon planet",
          "assetIds":[],
          "creationMode":"original",
          "stage":"succeeded",
          "statusMessage":"ready",
          "verificationGrade":"verified",
          "planId":"be4f0389-1009-4f57-86dc-b7e263c9874c",
          "artifactId":"30b86b66-7fd2-4cdc-9dc2-0733f4e64c25",
          "verificationId":"3327fcbc-d936-4279-a5ed-e6083d52a540",
          "retryable":false,
          "createdAt":"2026-08-20T08:09:06Z",
          "updatedAt":"2026-08-20T08:09:07Z",
          "terminalAt":"2026-08-20T08:09:07Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let job = try decoder.decode(GenerationJob.self, from: data)

        XCTAssertEqual(job.workID.uuidString.lowercased(), "59bcc7cc-7363-4413-8b79-b700667f2dde")
        XCTAssertEqual(job.runID.uuidString.lowercased(), "f9a75473-b507-4e3c-b66a-8d56b796c0dc")
        XCTAssertTrue(job.assetIDs.isEmpty)
        XCTAssertEqual(job.planID?.uuidString.lowercased(), "be4f0389-1009-4f57-86dc-b7e263c9874c")
    }

    func testInteractionKindPreservesServerExtensions() throws {
        let interaction = try JSONDecoder().decode(InteractiveApp.InteractionKind.self, from: Data("\"touch-garden\"".utf8))
        XCTAssertEqual(interaction.rawValue, "touch-garden")
    }

    func testResourceLibraryDecodesPublicBGMAndLegacyPrivateAsset() throws {
        let publicData = Data(#"""
        {
          "id":"10000000-0000-4000-8000-000000000003",
          "owner":"pulse-official",
          "library":"public",
          "source":"official",
          "kind":"audio",
          "displayName":"Arcade Rush BGM",
          "fileName":"arcade-rush.mp3",
          "mediaType":"audio/mpeg",
          "sizeBytes":0,
          "status":"ready",
          "summary":"High-energy loop",
          "license":"Pulse Official",
          "deliveryUrl":"https://cdn.ai.lovetalk.chat/public/assets/v1/arcade-rush.mp3"
        }
        """#.utf8)
        let publicAsset = try JSONDecoder().decode(GenerationAsset.self, from: publicData)
        XCTAssertEqual(publicAsset.library, .public)
        XCTAssertEqual(publicAsset.source, .official)
        XCTAssertEqual(publicAsset.kind, .audio)
        XCTAssertEqual(publicAsset.iconName, "music.note")
        XCTAssertEqual(publicAsset.deliveryURL?.host, "cdn.ai.lovetalk.chat")

        let legacyData = Data(#"""
        {
          "id":"9a910ce7-b47a-45df-9ff7-84639a806865",
          "owner":"you",
          "fileName":"portrait.png",
          "mediaType":"image/png",
          "sizeBytes":128,
          "status":"ready"
        }
        """#.utf8)
        let legacyAsset = try JSONDecoder().decode(GenerationAsset.self, from: legacyData)
        XCTAssertEqual(legacyAsset.library, .private)
        XCTAssertEqual(legacyAsset.source, .upload)
        XCTAssertEqual(legacyAsset.kind, .image)
        XCTAssertEqual(legacyAsset.displayName, "portrait.png")
        XCTAssertNil(legacyAsset.deliveryURL)
    }

    func testPublishedWorkDecodesArtifactPlayerContract() throws {
        let data = Data(#"""
        {
          "id":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "title":"Neon Snake",
          "creator":"you",
          "prompt":"生成疯狂版本的贪吃蛇",
          "theme":"Hyper arcade",
          "tint":"lime",
          "interaction":"game",
          "creationMode":"original",
          "rootWorkId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "originalCreator":"you",
          "allowRemix":true,
          "status":"published",
          "verificationGrade":"degraded",
          "generationJobId":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
          "artifactId":"30b86b66-7fd2-4cdc-9dc2-0733f4e64c25",
          "artifactEntryUrl":"/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html",
          "likes":0,
          "comments":0,
          "remixes":0,
          "viewerHasLiked":false
        }
        """#.utf8)

        let work = try JSONDecoder().decode(InteractiveApp.self, from: data)

        XCTAssertEqual(work.artifactID?.uuidString.lowercased(), "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25")
        XCTAssertEqual(work.artifactEntryURL, "/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html")
    }

    func testArtifactURLResolutionStaysOnAPIOrigin() throws {
        let client = PulseAPIClient(baseURL: try XCTUnwrap(URL(string: "http://localhost:8787/v1")))
        let relative = "/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html"

        let artifactID = try XCTUnwrap(UUID(uuidString: "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25"))
        XCTAssertEqual(client.resolveArtifactEntryURL(relative, artifactID: artifactID)?.absoluteString, "http://localhost:8787/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html")
        XCTAssertNil(client.resolveArtifactEntryURL("https://attacker.example/game.html", artifactID: artifactID))
        XCTAssertNil(client.resolveArtifactEntryURL("/v1/feed", artifactID: artifactID))
    }

    func testCommentMapsWorkID() throws {
        let data = Data(#"""
        {
          "id":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
          "workId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "author":"you",
          "score":5,
          "body":"Alive and responsive",
          "status":"published",
          "createdAt":"2026-08-20T08:09:07Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let comment = try decoder.decode(AppComment.self, from: data)

        XCTAssertEqual(comment.workID.uuidString.lowercased(), "59bcc7cc-7363-4413-8b79-b700667f2dde")
    }
}
