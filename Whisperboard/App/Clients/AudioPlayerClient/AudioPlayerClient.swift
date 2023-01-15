//
// AudioPlayerClient.swift
//

import Dependencies
import Foundation
import XCTestDynamicOverlay

// MARK: - AudioPlayerClient

struct AudioPlayerClient {
  var play: @Sendable (URL) async throws -> Bool
}

// MARK: TestDependencyKey

extension AudioPlayerClient: TestDependencyKey {
  static let previewValue = Self(
    play: { _ in
      try await Task.sleep(nanoseconds: NSEC_PER_SEC * 5)
      return true
    }
  )

  static let testValue = Self(
    play: unimplemented("\(Self.self).play")
  )
}

extension DependencyValues {
  var audioPlayer: AudioPlayerClient {
    get { self[AudioPlayerClient.self] }
    set { self[AudioPlayerClient.self] = newValue }
  }
}
