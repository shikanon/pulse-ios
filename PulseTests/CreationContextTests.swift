import Foundation
import XCTest
@testable import Pulse

final class CreationContextTests: XCTestCase {
    private func asset(mediaType: String = "image/png") throws -> GenerationAsset {
        let json: [String: Any] = ["id": UUID().uuidString, "owner": "pulse.e2e", "fileName": "cat.png", "mediaType": mediaType, "sizeBytes": 200, "status": "ready"]
        return try JSONDecoder().decode(GenerationAsset.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testMaterialDirectionTravelsWithTheRequestAndCanBePresentedWithoutTechnicalContext() throws {
        let image = try asset()
        let context = CreationContext(preserve: "Keep scoring", materials: [.init(id: image.id, name: image.displayName, role: .reaction, placement: "Show beside the board for 1 second after clearing a line")])
        let payload = context.selected(for: [image]).instruction(for: "Make the cat celebrate")
        XCTAssertTrue(payload.contains(image.id.uuidString))
        XCTAssertTrue(payload.contains("reaction"))
        XCTAssertTrue(payload.contains("clearing a line"))
        let parsed = CreationContext.parse(payload)
        XCTAssertEqual(parsed.message, "Make the cat celebrate")
        XCTAssertEqual(parsed.context, context)
        XCTAssertTrue(payload.contains("must not block controls"))
        for _ in 0..<20 {
            XCTAssertEqual(context.instruction(for: "Make the cat celebrate"), payload, "Unchanged requests must keep a stable idempotency payload")
        }
    }

    func testRemovedMaterialsAreNotResubmittedAndAudioCannotUseImageRoles() throws {
        let image = try asset()
        let audio = try asset(mediaType: "audio/mpeg")
        let context = CreationContext(materials: [
            .init(id: image.id, name: "old", role: .reaction, placement: "clear"),
            .init(id: audio.id, name: "audio", role: .character, placement: "while playing")
        ])
        let selected = context.selected(for: [audio])
        XCTAssertEqual(selected.materials.count, 1)
        XCTAssertEqual(selected.materials.first?.id, audio.id)
        XCTAssertEqual(selected.materials.first?.role, .music)
        XCTAssertFalse(selected.instruction(for: "Change music").contains(image.id.uuidString))
    }

    func testReferenceOnlyDirectionIsDistinctFromEmbeddingAndLegacyInstructionsAreUnchanged() throws {
        let image = try asset()
        let context = CreationContext(materials: [.init(id: image.id, name: "style", role: .reference, placement: "Use warm colors")])
        let instruction = context.instruction(for: "A calm garden")
        XCTAssertTrue(instruction.contains("do not embed it in the runtime"))
        XCTAssertEqual(CreationContext.parse(instruction).context?.materials.first?.role, .reference)
        let legacy = "Keep this literal\n\n--- Pulse creation context ---\nnot JSON"
        XCTAssertEqual(CreationContext.parse(legacy).message, legacy)
        XCTAssertNil(CreationContext.parse(legacy).context)
        XCTAssertEqual(CreationContext().instruction(for: "Original idea"), "Original idea")
    }

    func testDraftPersistsMaterialDirectionAndDecodesOlderDrafts() throws {
        var draft = ComposerDraft.fresh(ownerID: "author-a", parentWorkID: UUID(), instruction: "Next change", assetIDs: [])
        draft.creationContext = CreationContext(preserve: "Keep movement")
        let data = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(ComposerDraft.self, from: data), draft)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "creationContext")
        let restored = try JSONDecoder().decode(ComposerDraft.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.creationContext)
        XCTAssertEqual(restored.instruction, "Next change")
        XCTAssertEqual(restored.ownerID, "author-a")
    }
}
