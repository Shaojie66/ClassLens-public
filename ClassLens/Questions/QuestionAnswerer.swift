import Foundation

/// Streams an answer to a class question, grounded in the recent transcript.
struct QuestionAnswerer: Sendable {
    let client: any LLMClient
    let model: String

    /// A question the teacher asked; `slide` is the page the student had open.
    func answer(_ question: ClassQuestion, context: [String], glossary: [String] = [], slide: String? = nil) -> AsyncThrowingStream<String, Error> {
        let asked = question.chinese.isEmpty ? question.english : "\(question.english)（\(question.chinese)）"
        return client.stream(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: QuestionPrompts.answerSystem),
                ChatMessage(role: .user, content: QuestionPrompts.answerUser(question: asked, quote: question.quote, context: context, glossary: glossary, slide: slide)),
            ],
            temperature: 0.3,
            maxTokens: 700
        ))
    }

    /// A question about text the student selected in the slides.
    func answerSelection(question: String, selection: String, page: Int, pageText: String, context: [String], glossary: [String]) -> AsyncThrowingStream<String, Error> {
        client.stream(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: QuestionPrompts.selectionSystem),
                ChatMessage(role: .user, content: QuestionPrompts.selectionUser(question: question, selection: selection, page: page, pageText: pageText, context: context, glossary: glossary)),
            ],
            temperature: 0.3,
            maxTokens: 900
        ))
    }

    /// A question about words the student selected in a caption.
    func answerCaption(question: String, selection: String, sentence: String, translation: String?, around: [String], slide: String?, glossary: [String]) -> AsyncThrowingStream<String, Error> {
        client.stream(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: QuestionPrompts.captionSystem),
                ChatMessage(role: .user, content: QuestionPrompts.captionUser(question: question, selection: selection, sentence: sentence, translation: translation, around: around, slide: slide, glossary: glossary)),
            ],
            temperature: 0.3,
            maxTokens: 700
        ))
    }
}
