import Foundation
import XCTest

final class ActivityTimestampFixtureTests: XCTestCase {
    func testServerFixtureUsesTheCorrectEpoch() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory
            .appending(path: "../Fixtures/activity-state-v2.json")
            .standardizedFileURL
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        let generated = Date(timeIntervalSince1970: fixture.state.generatedAtEpoch)
        let legacyStart = Date(timeIntervalSinceReferenceDate: fixture.state.progressStart)
        let unixStart = Date(timeIntervalSince1970: fixture.state.progressStartEpoch)
        let firstBoundary = try XCTUnwrap(fixture.state.scheduledLinesV2.first)

        XCTAssertEqual(ISO8601DateFormatter().string(from: generated), fixture.expectedGeneratedDate)
        XCTAssertEqual(legacyStart.timeIntervalSince1970, unixStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            firstBoundary.dateEpoch,
            1_700_000_000.25,
            accuracy: 0.001
        )
    }

    private struct Fixture: Decodable {
        let state: State
        let expectedGeneratedDate: String

        struct State: Decodable {
            let generatedAtEpoch: TimeInterval
            let progressStartEpoch: TimeInterval
            let progressStart: TimeInterval
            let scheduledLinesV2: [ScheduledLine]
        }

        struct ScheduledLine: Decodable {
            let dateEpoch: TimeInterval
        }
    }
}
