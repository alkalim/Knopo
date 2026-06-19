import Testing

// XCTest-flavoured assertion helpers over Swift Testing's #expect, so call
// sites stay terse and failures point at the caller.

func expectEqual<T: Equatable>(
    _ a: T?, _ b: T?, _ comment: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(a == b, Comment(rawValue: comment), sourceLocation: sourceLocation)
}

func expectTrue(
    _ value: Bool, _ comment: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(value, Comment(rawValue: comment), sourceLocation: sourceLocation)
}

func expectFalse(
    _ value: Bool, _ comment: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!value, Comment(rawValue: comment), sourceLocation: sourceLocation)
}

func expectNil<T>(
    _ value: T?, _ comment: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(value == nil, Comment(rawValue: comment), sourceLocation: sourceLocation)
}

func expectNotNil<T>(
    _ value: T?, _ comment: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(value != nil, Comment(rawValue: comment), sourceLocation: sourceLocation)
}
