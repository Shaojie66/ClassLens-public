import Foundation
import Testing
@testable import ClassLens

struct SummaryNumberCheckTests {
    private let segments = [
        TranscriptSegment(start: 100, end: 106, text: "We have a sample of fifteen students and the mean is seventy nine point five.", isFinal: true),
        TranscriptSegment(start: 130, end: 135, text: "At alpha zero point zero five we reject; one hundred and twenty was the limit.", isFinal: true),
        TranscriptSegment(start: 900, end: 905, text: "So we have 138 experiments.", isFinal: true),
    ]

    @Test func readsSpokenNumbers() {
        func read(_ text: String) -> [String] {
            NumberWords.values(in: text.split(separator: " ").map(String.init)).map { "\($0)" }
        }
        #expect(read("seventy nine point five") == ["79.5"])
        #expect(read("zero point zero five") == ["0.05"])
        #expect(read("one hundred and twenty") == ["120"])
        #expect(read("seventy eight seventy six") == ["78", "76"])
        #expect(read("fifteen") == ["15"])
        #expect(read("two thousand and five") == ["2005"])
        #expect(read("oh the point is") == [])
    }

    @Test func flagsAMisheardNumberStatedAsFact() {
        let summary = """
        ## 分节要点
        - 样本有 50 名学生，均值 79.5 [01:40]
        - 显著性水平 $\\alpha = 0.05$，上限 120 [02:10]
        """
        let missing = SummaryNumberCheck.unsupported(in: summary, segments: segments, slides: "")
        #expect(missing == [.init(number: "50", near: 100)])
    }

    @Test func checksNumbersNearTheCitedTime() {
        // 138 is in the transcript, but 13 minutes away from the time this line cites.
        let summary = "- 一共做了 138 次实验 [01:40]\n- 一共做了 138 次实验 [15:00]"
        #expect(SummaryNumberCheck.unsupported(in: summary, segments: segments, slides: "").map(\.number) == ["138"])
        #expect(SummaryNumberCheck.unsupported(in: "- 一共做了 138 次实验", segments: segments, slides: "").isEmpty)
    }

    @Test func ignoresReferencesSmallIntegersAndNumbersAlreadyFlagged() {
        let summary = """
        ## 分节要点
        ### 1. 检验 H0
        - 第 14 页讲了 n - 1 个自由度，课件第 23 页 [01:40, 课件第 23 页]
        - Week 12 的均值是 50 [01:40]
        - 5% 的显著性水平 [02:10]
        ## 待核对
        - [01:40] 转写为 "fifteen"，可能是 50
        """
        #expect(SummaryNumberCheck.unsupported(in: summary, segments: segments, slides: "").isEmpty)
    }

    @Test func slideNumbersCount() {
        #expect(SummaryNumberCheck.unsupported(in: "- 临界值 1.96 [01:40]", segments: segments, slides: "z = 1.96").isEmpty)
    }

    @Test func appendsUnderTheReviewSection() {
        let summary = "## 分节要点\n- 样本有 50 名学生 [01:40]\n\n## 待核对\n- 第一条\n"
        let annotated = SummaryNumberCheck.annotate(summary, segments: segments, slides: "")
        #expect(annotated.contains("- 第一条\n- 程序核对：") )
        #expect(annotated.contains("`50`（01:40 附近）"))

        let without = SummaryNumberCheck.annotate("## 分节要点\n- 样本有 50 名学生 [01:40]", segments: segments, slides: "")
        #expect(without.hasSuffix("## 待核对\n- 程序核对：下面这些数字在所引时间附近的转写和课件里都找不到原文，可能是推断出来的或识别错误，请对照录音：`50`（01:40 附近）"))
        #expect(SummaryNumberCheck.annotate("- 样本有 15 名学生 [01:40]", segments: segments, slides: "") == "- 样本有 15 名学生 [01:40]")
    }

    @Test func flagsATeenTyTwinNearby() {
        let nearby = [
            TranscriptSegment(start: 3350, end: 3355, text: "Anyone who gets my weight below 50.", isFinal: true),
            TranscriptSegment(start: 3381, end: 3386, text: "Filter value greater than or equal to fifteen and smaller than or equal one hundred and five.", isFinal: true),
        ]
        let summary = "- 过滤标准：保留 50 到 105 公斤之间的值 [55:56]"
        #expect(SummaryNumberCheck.unsupported(in: summary, segments: nearby, slides: "") == [.init(number: "50", near: 3356, twin: "15")])
        #expect(SummaryNumberCheck.annotate(summary, segments: nearby, slides: "").contains("`50`（55:56 附近），转写里也有 15"))
        #expect(SummaryNumberCheck.twin(of: "15") == "50")
        #expect(SummaryNumberCheck.twin(of: "40") == "14")
        #expect(SummaryNumberCheck.twin(of: "20") == nil)
    }
}
