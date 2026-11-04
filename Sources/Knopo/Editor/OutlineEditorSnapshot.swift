import Foundation
import KnopoCore

/// Editor-only data that cannot be recovered from the stored block properties.
struct OutlineEditorSnapshot {
    var id: UUID
    var text: String
    var numberingSnapshot: [BlockProperty]
    var selection: NSRange

    init(block: Block, selection: NSRange) {
        id = block.id
        text = block.editableSource
        numberingSnapshot = block.numberingProperties
        self.selection = selection
    }
}

struct OutlineEditorUndo {
    weak var owner: OutlineEditorController?
    var page: String
    var before: OutlineEditorSnapshot?
    var after: OutlineEditorSnapshot?
    var restore: ((OutlineEditorSnapshot?) -> Void)?
}
