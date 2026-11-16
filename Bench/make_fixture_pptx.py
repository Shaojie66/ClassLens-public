"""Writes Fixtures/slides/hypothesis_testing.pptx, the PowerPoint twin of the sample PDF deck.

Usage: Bench/.venv/bin/python -I Bench/make_fixture_pptx.py Fixtures/slides/hypothesis_testing.pptx [tag]
A tag adds a closing slide with that text, giving a valid file with a new fingerprint for conversion
tests. (Appending bytes to a .pptx corrupts the zip and makes PowerPoint open it in repair mode.)
"""
import sys

from pptx import Presentation
from pptx.util import Inches, Pt

SLIDES = [
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

deck = Presentation()
deck.slide_width, deck.slide_height = Inches(13.333), Inches(7.5)
layout = deck.slide_layouts[1]
for title, bullets in SLIDES:
    slide = deck.slides.add_slide(layout)
    slide.shapes.title.text = title
    body = slide.placeholders[1].text_frame
    body.text = bullets[0]
    for bullet in bullets[1:]:
        body.add_paragraph().text = bullet
    for paragraph in body.paragraphs:
        for run in paragraph.runs:
            run.font.size = Pt(24)
if len(sys.argv) > 2:
    closing = deck.slides.add_slide(deck.slide_layouts[5])
    closing.shapes.title.text = f"Test copy {sys.argv[2]}"
deck.save(sys.argv[1])
print("wrote", sys.argv[1])
