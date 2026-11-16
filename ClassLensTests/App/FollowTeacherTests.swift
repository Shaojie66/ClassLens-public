import Testing
@testable import ClassLens

@MainActor
struct FollowTeacherTests {
    @Test func pageChangesBeforeAnyEstimateDoNotPause() {
        let model = AppModel()
        model.followTeacher = true
        model.userTurnedPage(to: 1)
        #expect(!model.followPaused)
        #expect(model.isFollowing)
    }

    @Test func turningAwayFromTheTeachersSlidePausesForThisSessionOnly() {
        let model = AppModel()
        model.followTeacher = true
        model.teacherSlide = SlideTracker.Estimate(slide: 21, pages: 46...53, probability: 0.8)
        model.userTurnedPage(to: 53)
        #expect(!model.followPaused, "arriving at the teacher's page is not turning away")
        model.userTurnedPage(to: 10)
        #expect(model.followPaused)
        #expect(model.followTeacher, "the setting itself stays on")
        model.resumeFollowing()
        #expect(model.isFollowing)
        #expect(model.currentPage == 53)
    }
}
