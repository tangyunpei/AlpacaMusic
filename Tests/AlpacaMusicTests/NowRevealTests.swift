import AppKit
import SwiftUI
import Testing
@testable import AlpacaMusic

/// A line that folds away on the Now page gives up its room as it goes:
/// along the fold always, and across it where a column is only as wide as
/// its widest line.
@Suite @MainActor struct NowRevealTests {
    /// A column like the stage's right one: a line that comes and goes over a row that stays.
    private func column(_ amount: CGFloat, foldsAcross: Bool) -> CGSize {
        let view = VStack(alignment: .trailing, spacing: 0) {
            Color.clear.frame(width: 300, height: 20)
                .nowReveal(amount, foldsAcross: foldsAcross, anchor: .topTrailing)
            Color.clear.frame(width: 120, height: 34)
        }
        .fixedSize()
        return NSHostingView(rootView: view).fittingSize
    }

    @Test func aFoldedLineTakesNoRoomInAColumnItWouldWiden() {
        #expect(column(0, foldsAcross: true) == CGSize(width: 120, height: 34))
        #expect(column(1, foldsAcross: true) == CGSize(width: 300, height: 54))
    }

    @Test func theRoomOpensInStepWithTheLine() {
        #expect(column(0.5, foldsAcross: true) == CGSize(width: 150, height: 44))
        #expect(column(0.25, foldsAcross: true) == CGSize(width: 120, height: 39))
    }

    @Test func aLineThatFoldsOnlyAlongKeepsItsWidth() {
        #expect(column(0, foldsAcross: false) == CGSize(width: 300, height: 34))
        #expect(column(0.5, foldsAcross: false) == CGSize(width: 300, height: 44))
    }

    @Test func amountsPastTheEndsStayWithinTheContent() {
        #expect(column(-0.2, foldsAcross: true) == CGSize(width: 120, height: 34))
        #expect(column(1.2, foldsAcross: true) == CGSize(width: 300, height: 54))
    }
}
