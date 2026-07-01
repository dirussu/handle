import AppKit

enum FileToolError: LocalizedError {
    case outsideWorkspace(String)
    case fileNotFound(String)
    case fileExists(String)
    case decodeFailed(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let p): return "Path \(p) is not in an allowed folder (workspace, Desktop, Documents, Downloads, or a folder the user added in Settings). Use pick_file to ask the user to grant one-shot access."
        case .fileNotFound(let p):     return "File not found: \(p)"
        case .fileExists(let p):       return "File already exists: \(p) (set overwrite: true to replace)"
        case .decodeFailed(let s):     return "Tool input invalid: \(s)"
        case .ioFailed(let s):         return s
        }
    }
}

// MARK: - Decodable inputs

struct WriteFileInput: Decodable {
    let path: String
    let content: String
    let overwrite: Bool?
}
struct ReadFileInput: Decodable { let path: String }
struct ListFilesInput: Decodable { let path: String? }
struct DeleteFileInput: Decodable { let path: String }
struct MoveFileInput: Decodable { let src: String; let dst: String }
struct CreateFolderInput: Decodable { let path: String }
struct OpenFileInput: Decodable { let path: String }
struct OpenURLInput: Decodable { let url: String }
struct PickFileInput: Decodable {
    let type_hint: String?
    let starting_directory: String?
    let prompt: String?
}

@MainActor
final class FileTools {
    static let shared = FileTools()
    private init() {}

    static var tools: [Tool] {
        [
            writeFileTool, readFileTool, listFilesTool, createFolderTool,
            deleteFileTool, moveFileTool,
            openFileTool, openURLTool,
            pickFileTool, recaptureScreenTool,
        ]
    }

    // MARK: - Tool definitions

    static let writeFileTool = Tool(
        name: "write_file",
        description: """
        Write text content to a file. The path can be inside any allowed folder: the Akari workspace, \
        Desktop, Documents, Downloads, or any other folder the user added in Settings. Relative paths \
        resolve against the workspace root. Absolute paths (~/Desktop/foo.html, /Users/.../bar.txt) work \
        too if they're inside an allowed folder. Parent folders are created automatically. To replace \
        an existing file, pass overwrite: true (the user is asked to confirm overwrites). Paths outside \
        all allowed folders are refused.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "File path. Relative (resolved against workspace) or absolute (e.g. '~/Desktop/notes.md'). Must be inside an allowed folder."],
                "content": ["type": "string", "description": "Text content to write."],
                "overwrite": ["type": "boolean", "description": "Replace existing file. Default false; user is asked to confirm if true and a file already exists."]
            ],
            "required": ["path", "content"]
        ],
        confirmation: .confirm   // preview-diff: the user sees the path + content before any file mutation (PRODUCT.md safety principle)
    )

    static let readFileTool = Tool(
        name: "read_file",
        description: """
        Read a file's content from any allowed folder (workspace, Desktop, Documents, Downloads, or a \
        folder the user added). Content-type-aware: text files return as text; PDFs return as a document \
        block (Anthropic parses them natively); images return as an image block. Use when the user \
        references a file by name/path (e.g. "summarize the PDF on my Desktop called contract.pdf"). \
        For files outside allowed folders, use pick_file to ask the user to grant one-shot access.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "File path. Relative (resolved against workspace) or absolute (e.g. '~/Desktop/contract.pdf')."]
            ],
            "required": ["path"]
        ],
        confirmation: .auto
    )

    static let listFilesTool = Tool(
        name: "list_files",
        description: """
        List the contents of a folder in any allowed location. With no path, lists the workspace root. \
        Returns file and folder names (one per line).
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Folder path. Relative (workspace) or absolute (e.g. '~/Desktop'). Defaults to workspace root."]
            ]
        ],
        confirmation: .auto
    )

    static let createFolderTool = Tool(
        name: "create_folder",
        description: "Create a folder (and any missing parents) at the given path. Must be inside an allowed folder.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Folder path. Relative or absolute."]
            ],
            "required": ["path"]
        ],
        confirmation: .auto
    )

    static let deleteFileTool = Tool(
        name: "delete_file",
        description: """
        Move a file or folder to the user's Trash (recoverable). Always asks the user to confirm. \
        Path must be inside an allowed folder.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "File or folder path."]
            ],
            "required": ["path"]
        ],
        confirmation: .confirm
    )

    static let moveFileTool = Tool(
        name: "move_file",
        description: """
        Move or rename a file. Always asks the user to confirm. Both source and destination must be \
        inside allowed folders (this lets you move e.g. ~/Desktop/foo.txt → ~/Documents/foo.txt).
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "src": ["type": "string", "description": "Source path."],
                "dst": ["type": "string", "description": "Destination path."]
            ],
            "required": ["src", "dst"]
        ],
        confirmation: .confirm
    )

    static let openFileTool = Tool(
        name: "open_file",
        description: """
        Open a file in its default app (Safari for HTML, Preview for images, etc.). Useful right after \
        write_file to show the user what you built. Path can be in any allowed folder.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "File path."]
            ],
            "required": ["path"]
        ],
        confirmation: .auto
    )

    static let recaptureScreenTool = Tool(
        name: "recapture_screen",
        description: """
        Take a fresh full-screen screenshot of what the user sees right now. Use this whenever the \
        screen state has changed since the original capture and you need an up-to-date view. Common cases:
        - You (or the user) just deleted, moved, or created a file — the Finder/Desktop has updated
        - You opened or closed a window/app via run_applescript
        - The user mentions scrolling or switching windows
        - You're about to call point_at and aren't sure the original screenshot still matches reality

        After this tool runs, the new screenshot REPLACES the active reference for point_at coordinates. \
        The dimensions of the new image are stated in the tool's text result — use those for any \
        subsequent point_at calls. Always recapture before pointing if anything visible has changed.
        """,
        inputSchema: [
            "type": "object",
            "properties": [:]
        ],
        confirmation: .auto
    )

    static let pickFileTool = Tool(
        name: "pick_file",
        description: """
        Open a macOS file picker so the user picks a file for you to read. Use this when:
        - The user mentions a file but doesn't give an exact path you can resolve.
        - The file lives outside the allowed folders (workspace, Desktop, Documents, Downloads, or user-added folders).
        - You need to ask the user to choose between several candidates.

        The dialog itself IS the user's consent — they grant access to that one file by picking it. \
        Returned with content-type detection: PDF → document block, image → image block, text → text content. \
        After the file loads, summarize / answer based on what you got.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "type_hint": [
                    "type": "string",
                    "enum": ["any", "pdf", "image", "text"],
                    "description": "Filter the picker by content type. Use 'any' if unsure. Default 'any'."
                ],
                "starting_directory": [
                    "type": "string",
                    "description": "Where to open the dialog (e.g. '~/Desktop'). Defaults to home folder."
                ],
                "prompt": [
                    "type": "string",
                    "description": "Optional short prompt shown in the dialog title (e.g. 'Choose the contract PDF')."
                ]
            ]
        ],
        confirmation: .auto
    )

    static let openURLTool = Tool(
        name: "open_url",
        description: """
        Open a URL in the user's default browser. Use to direct the user to a relevant external page \
        you found via web_search.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "Full URL including scheme (https://...)."]
            ],
            "required": ["url"]
        ],
        confirmation: .auto
    )

    // MARK: - Decoding helpers

    func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw FileToolError.decodeFailed("not UTF-8")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Execution

    /// Returns the URL written to (for displaying the result).
    @discardableResult
    func writeFile(input: WriteFileInput) throws -> URL {
        let url = WorkspaceManager.shared.resolve(input.path)
        try requireAllowed(url)
        try WorkspaceManager.shared.ensureWorkspaceExists()
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: url.path), input.overwrite != true {
            throw FileToolError.fileExists(url.lastPathComponent)
        }
        do {
            try input.content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw FileToolError.ioFailed("Couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return url
    }

    func readFile(input: ReadFileInput) throws -> String {
        let url = WorkspaceManager.shared.resolve(input.path)
        try requireAllowed(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileToolError.fileNotFound(url.path)
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try Latin-1 as a fallback for non-UTF-8 content.
            if let data = FileManager.default.contents(atPath: url.path),
               let s = String(data: data, encoding: .isoLatin1) {
                return s
            }
            throw FileToolError.ioFailed("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func listFiles(input: ListFilesInput) throws -> [String] {
        let url: URL
        if let path = input.path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            url = WorkspaceManager.shared.resolve(path)
        } else {
            url = try WorkspaceManager.shared.ensureWorkspaceExists()
        }
        try requireAllowed(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileToolError.fileNotFound(url.path)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        return names
    }

    func createFolder(input: CreateFolderInput) throws -> URL {
        let url = WorkspaceManager.shared.resolve(input.path)
        try requireAllowed(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func deleteFile(input: DeleteFileInput) throws -> URL {
        let url = WorkspaceManager.shared.resolve(input.path)
        try requireAllowed(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileToolError.fileNotFound(url.path)
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw FileToolError.ioFailed("Couldn't move to Trash: \(error.localizedDescription)")
        }
        return url
    }

    func moveFile(input: MoveFileInput) throws -> (src: URL, dst: URL) {
        let src = WorkspaceManager.shared.resolve(input.src)
        let dst = WorkspaceManager.shared.resolve(input.dst)
        try requireAllowed(src)
        try requireAllowed(dst)
        let parent = dst.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            throw FileToolError.ioFailed("Couldn't move: \(error.localizedDescription)")
        }
        return (src, dst)
    }

    @discardableResult
    func openFile(input: OpenFileInput) throws -> URL {
        let url = WorkspaceManager.shared.resolve(input.path)
        try requireAllowed(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileToolError.fileNotFound(url.path)
        }
        NSWorkspace.shared.open(url)
        return url
    }

    @discardableResult
    func openURL(input: OpenURLInput) throws -> URL {
        guard let url = URL(string: input.url) else {
            throw FileToolError.ioFailed("Invalid URL: \(input.url)")
        }
        NSWorkspace.shared.open(url)
        return url
    }

    // MARK: - Helpers

    private func requireAllowed(_ url: URL) throws {
        guard WorkspaceManager.shared.isAllowed(url) else {
            throw FileToolError.outsideWorkspace(url.path)
        }
    }
}
