import Foundation
import os

enum StudioLog {
  private static let subsystem = Bundle.main.bundleIdentifier!
  static let agent = Logger(subsystem: subsystem, category: "agent")
  static let workspace = Logger(subsystem: subsystem, category: "workspace")
  static let terminal = Logger(subsystem: subsystem, category: "terminal")
  static let persistence = Logger(subsystem: subsystem, category: "persistence")

  static func agentState(questionID: UUID, runID: UUID, state: AgentRunState) {
    switch state {
    case .requesting:
      agent.info(
        "event=request_state state=requesting question=\(questionID.uuidString, privacy: .public) run=\(runID.uuidString, privacy: .public)"
      )
    case .completed:
      agent.info(
        "event=request_completed question=\(questionID.uuidString, privacy: .public) run=\(runID.uuidString, privacy: .public)"
      )
    case .failed:
      agent.error(
        "event=request_failed question=\(questionID.uuidString, privacy: .public) run=\(runID.uuidString, privacy: .public)"
      )
    case .cancelled:
      agent.info(
        "event=request_cancelled question=\(questionID.uuidString, privacy: .public) run=\(runID.uuidString, privacy: .public)"
      )
    }
  }
}
