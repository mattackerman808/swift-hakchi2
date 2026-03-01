import Foundation

/// Represents an hmod package (hakchi module)
struct HmodPackage: Identifiable, Hashable {
    let id: String  // hmod name (e.g., "retroarch")
    var name: String
    var version: String
    var creator: String
    var category: String
    var description: String
    var filePath: String?  // local path to .hmod file/directory

    var isInstalled: Bool = false

    init(id: String, name: String = "", version: String = "", creator: String = "",
         category: String = "", description: String = "", filePath: String? = nil) {
        self.id = id
        self.name = name.isEmpty ? id : name
        self.version = version
        self.creator = creator
        self.category = category
        self.description = description
        self.filePath = filePath
    }
}
