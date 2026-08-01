import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AttachmentLoader {
    private static let maximumAttachmentBytes = 10 * 1_024 * 1_024
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "xml", "yaml", "yml",
        "js", "jsx", "ts", "tsx", "py", "java", "go", "rs", "c", "h",
        "cpp", "hpp", "css", "html", "sql",
    ]

    // Loads one selected image, PDF, DOCX, or UTF-8 text document into Pi-ready content.
    static func load(url: URL) throws -> PendingAttachment {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw QuickPiError.message("只能添加普通文件")
        }
        guard fileSize <= maximumAttachmentBytes else {
            throw QuickPiError.message("附件 \(url.lastPathComponent) 超过 10 MB")
        }

        let fileExtension = url.pathExtension.lowercased()
        if UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true {
            guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
                throw QuickPiError.message("无法读取图片：\(url.lastPathComponent)")
            }
            return PendingAttachment(
                id: UUID(),
                name: url.lastPathComponent,
                content: .image(
                    data: try normalizedJPEG(source: source, name: url.lastPathComponent),
                    mimeType: "image/jpeg"
                )
            )
        }

        let text: String
        if fileExtension == "pdf" {
            guard let document = PDFDocument(url: url), let extracted = document.string else {
                throw QuickPiError.message("无法读取 PDF：\(url.lastPathComponent)")
            }
            text = extracted
        } else if fileExtension == "docx" {
            text = try docxText(url: url)
        } else if textExtensions.contains(fileExtension) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            throw QuickPiError.message("不支持读取 \(url.lastPathComponent)")
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuickPiError.message("附件 \(url.lastPathComponent) 没有可读取的文本")
        }
        guard text.count <= 200_000 else {
            throw QuickPiError.message("附件 \(url.lastPathComponent) 的文本超过 200,000 字符")
        }
        return PendingAttachment(id: UUID(), name: url.lastPathComponent, content: .text(text))
    }

    // Clipboard TIFF/bitmap payloads can be large even when their normalized JPEG is small.
    static func loadImage(data: Data, name: String) throws -> PendingAttachment {
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else {
            throw QuickPiError.message("无法读取图片：\(name)")
        }
        let jpeg = try normalizedJPEG(source: source, name: name)
        guard jpeg.count <= maximumAttachmentBytes else {
            throw QuickPiError.message("附件 \(name) 超过 10 MB")
        }
        return PendingAttachment(
            id: UUID(),
            name: name,
            content: .image(data: jpeg, mimeType: "image/jpeg")
        )
    }

    // Converts a decoded image to a bounded JPEG accepted by image-capable Provider APIs.
    private static func normalizedJPEG(source: NSImage, name: String) throws -> Data {
        let scale = min(1, 2_048 / max(source.size.width, source.size.height))
        let size = NSSize(
            width: max(1, floor(source.size.width * scale)),
            height: max(1, floor(source.size.height * scale))
        )
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
            throw QuickPiError.message("无法转换图片：\(name)")
        }
        return jpeg
    }

    // Extracts visible WordprocessingML text from a DOCX using the system archive utility.
    private static func docxText(url: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let xml = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw QuickPiError.message(detail)
        }

        let delegate = DOCXTextParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else {
            guard let parserError = parser.parserError else {
                throw QuickPiError.message("DOCX 文本解析失败")
            }
            throw parserError
        }
        return delegate.text
    }
}

private final class DOCXTextParser: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private var readingText = false

    // Starts Word text capture and preserves explicit tab characters.
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "w:t" {
            readingText = true
        } else if elementName == "w:tab" {
            text.append("\t")
        }
    }

    // Ends text capture and keeps Word paragraph boundaries.
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "w:t" {
            readingText = false
        } else if elementName == "w:p" {
            text.append("\n")
        }
    }

    // Appends character data only while parsing a visible Word text element.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingText {
            text.append(string)
        }
    }
}
