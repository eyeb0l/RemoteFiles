import Foundation
import Testing

@testable import Textual

private func isMainThread() -> Bool { Thread.isMainThread }

struct RenderingWarmUpTests {
  @Test
  func preparesEveryTypeOffTheMainThreadAndRepeats() async {
    let (first, second, onMain) = await Task.detached {
      (StructuredText.prepareRendering(), StructuredText.prepareRendering(), isMainThread())
    }.value

    #expect(!onMain)
    #expect(first == RenderingWarmUp.viewTypes.count + RenderingWarmUp.modifierTypes.count)
    #expect(second == first)
  }

  @Test
  func stopsBetweenTypesWhenAskedTo() {
    var checks = 0
    let prepared = StructuredText.prepareRendering {
      checks += 1
      return checks <= 2
    }

    #expect(prepared == 2)
    #expect(StructuredText.prepareRendering(shouldContinue: { false }) == 0)
  }
}
