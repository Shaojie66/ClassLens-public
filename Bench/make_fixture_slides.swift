// Generates Fixtures/slides/hypothesis_testing.pdf: a small synthetic slide deck with real, selectable text.
// Usage: swift Bench/make_fixture_slides.swift Fixtures/slides/hypothesis_testing.pdf
import AppKit
import CoreText

let slides: [(title: String, bullets: [String])] = [
    ("Hypothesis Testing: One Population", [
        "Estimation vs. testing: from a sample mean to statements about the population",
        "Example: guessing the lecturer's weight - is the crowd estimate unbiased?",
        "Parameter of interest θ: a mean μ or a proportion p (e.g. classification accuracy)",
    ]),
    ("Null and Alternative Hypotheses", [
        "Null hypothesis H0: θ = θ0 (no difference, no effect)",
        "Alternative hypothesis H1 (or Ha): θ ≠ θ0, θ > θ0 or θ < θ0",
        "Two-sided vs. one-sided tests",
        "The data generating process defines the population the sample represents",
    ]),
    ("Test Statistic", [
        "One-sample t-test: t0 = (x̄ − μ0) / (s / √n)",
        "Under H0, t0 follows a t distribution with n − 1 degrees of freedom",
        "Reject H0 if |t0| > t(α/2, n−1); otherwise fail to reject H0",
        "Significance level α, critical value, rejection region",
    ]),
    ("p-value", [
        "p-value: probability of a test statistic at least as extreme as observed, assuming H0 is true",
        "Small p-value: data inconsistent with H0",
        "Confidence interval and its relation to the two-sided test",
    ]),
    ("Errors and Power", [
        "Type I error (false positive): rejecting H0 when H0 is true, probability α",
        "Type II error (false negative): failing to reject H0 when H0 is false, probability β",
        "Power (sensitivity) = 1 − β",
        "Effect size, variance and sample size determine power",
    ]),
    ("Sample Size Estimation", [
        "Choose α, desired power and the minimum effect size of interest",
        "Larger effect or smaller variance: fewer samples needed",
        "Statistical power analysis before collecting data",
    ]),
]

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hypothesis_testing.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: 960, height: 540)
guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else { fatalError("cannot create PDF") }

func draw(_ text: String, font: NSFont, at origin: CGPoint, width: CGFloat) -> CGFloat {
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: 400), nil)
    let path = CGPath(rect: CGRect(x: origin.x, y: origin.y - size.height, width: width, height: size.height), transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
    return size.height
}

for (index, slide) in slides.enumerated() {
    context.beginPDFPage(nil)
    var y: CGFloat = 480
    y -= draw(slide.title, font: .boldSystemFont(ofSize: 36), at: CGPoint(x: 60, y: y), width: 840) + 30
    for bullet in slide.bullets {
        y -= draw("•  " + bullet, font: .systemFont(ofSize: 22), at: CGPoint(x: 70, y: y), width: 820) + 16
    }
    _ = draw("STAT 101 · Lecture 7 · \(index + 1)", font: .systemFont(ofSize: 14), at: CGPoint(x: 60, y: 40), width: 400)
    context.endPDFPage()
}
context.closePDF()
print("wrote \(output.path)")
