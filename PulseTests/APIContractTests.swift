import XCTest
@testable import Pulse

final class APIContractTests: XCTestCase {
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
