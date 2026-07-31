import MarkdownUI
import XCTest

final class MarkdownRenderingTests: XCTestCase {
    // Verifies that the answer renderer's GFM parser preserves every required block structure.
    func testStructuredMarkdownProducesDistinctHTMLBlocks() {
        let source = """
        # Heading

        - one
        - two

        > quote

        | A | B |
        | - | - |
        | 1 | 2 |

        ```swift
        let value = 1
        ```
        """

        let html = MarkdownContent(source).renderHTML()

        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
    }

    // Documents why exported files use a native action instead of a sanitized Markdown file URL.
    func testMarkdownParserSanitizesFileURL() {
        let html = MarkdownContent(
            "[pi-session.html](file:///tmp/Quick%20Pi/pi-session.html)"
        ).renderHTML()

        XCTAssertTrue(html.contains("href=\"\""))
        XCTAssertTrue(html.contains(">pi-session.html</a>"))
    }
}
