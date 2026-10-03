import Foundation
import Testing

@testable import Web_Studio

struct WorkspaceCompactTests {
  @Test func layoutSamplesKeepBothWidePanelsAvailable() {
    for width in [1440.0, 1920.0] {
      let plan = StudioLayoutPlan.resolve(
        windowWidth: width, sidebarWidth: 220, agentsWidth: 300,
        sidebarVisible: true, agentsVisible: true)
      #expect(!plan.isCompactMode)
      #expect(plan.contentVisible)
      #expect(plan.questionsVisible)
      #expect(plan.sidebarWidth == 220)
      #expect(plan.agentsWidth == 300)
    }
  }

  @Test @MainActor func compactChoiceDoesNotChangeSavedQuestionPreference() {
    let model = StudioModel(launchTerminalProcesses: false)
    #expect(model.agentsVisible)
    model.updateCompactMode(for: 900)
    #expect(!model.questionPanelVisible)
    model.showQuestionPanel()
    #expect(model.questionPanelVisible)
    #expect(model.agentsVisible)
    model.hideQuestionPanel()
    #expect(!model.questionPanelVisible)
    #expect(model.agentsVisible)
    model.updateCompactMode(for: 1440)
    #expect(model.questionPanelVisible)
    #expect(model.agentsVisible)
  }

  @Test @MainActor func compactSwitchKeepsDraftLayoutAndRuntimeIdentity() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    model.newTerminal(directory: "/tmp")
    let terminalID = model.selectedTabID
    let runtimeID = try #require(model.webRuntimes.records[terminalID]?.runtimeInstanceID)
    let factoryCount = model.webRuntimes.terminalFactoryCreationCount
    model.newTab()
    let secondID = model.selectedTabID
    model.layout = WorkspaceLayout(
      primary: PaneState(id: UUID(), resourceID: terminalID, isFocused: false),
      secondary: PaneState(id: UUID(), resourceID: secondID, isFocused: true),
      splitRatio: 0.35)
    model.agentController.question = "保留中的问题草稿"
    let layout = model.layout

    model.updateCompactMode(for: 900)
    model.showQuestionPanel()
    model.hideQuestionPanel()
    model.toggleQuestionPanel()
    model.updateCompactMode(for: 1440)

    #expect(model.layout == layout)
    #expect(model.agentController.question == "保留中的问题草稿")
    #expect(model.webRuntimes.records[terminalID]?.runtimeInstanceID == runtimeID)
    #expect(model.webRuntimes.terminalFactoryCreationCount == factoryCount)
  }

  @Test @MainActor func hiddenWidePreferenceSurvivesCompactPresentation() {
    let model = StudioModel(launchTerminalProcesses: false)
    model.agentsVisible = false
    model.updateCompactMode(for: 900)
    model.showQuestionPanel()
    #expect(model.questionPanelVisible)
    #expect(!model.agentsVisible)
    model.updateCompactMode(for: 1440)
    #expect(!model.questionPanelVisible)
    #expect(!model.agentsVisible)
  }
}
