// pdf_pages.swift: write each page of a PDF as a JPEG, for visual review on macOS.
//
// Usage: swift pdf_pages.swift <file.pdf> <output directory> <width in pixels>
// Reads the PDF and writes page-001.jpg, page-002.jpg, ... into the directory.
// Prints the page count. Used when poppler's pdftoppm is not installed.

import AppKit
import Foundation
import PDFKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let width = Double(arguments[3]), width > 0 else {
    fail("usage: pdf_pages.swift <file.pdf> <output directory> <width in pixels>")
}
guard let document = PDFDocument(url: URL(fileURLWithPath: arguments[1])) else {
    fail("cannot open PDF: \(arguments[1])")
}

for index in 0..<document.pageCount {
    guard let page = document.page(at: index) else { fail("cannot read page \(index + 1)") }
    let box = page.bounds(for: .mediaBox)
    let size = NSSize(width: CGFloat(width), height: box.height * CGFloat(width) / box.width)
    let image = page.thumbnail(of: size, for: .mediaBox)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    else { fail("cannot render page \(index + 1)") }
    let path = String(format: "%@/page-%03d.jpg", arguments[2], index + 1)
    do {
        try jpeg.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("cannot write \(path): \(error)")
    }
}
print(document.pageCount)
