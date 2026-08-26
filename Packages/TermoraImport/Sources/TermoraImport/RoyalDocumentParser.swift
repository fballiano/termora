//
//  RoyalDocumentParser.swift
//  TermoraImport
//

import Foundation

public enum RoyalParseError: Error, LocalizedError, Equatable {
    case cannotReadFile(String)
    case notARoyalDocument
    case malformedXML(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotReadFile(path):
            "Termora could not read \(path)."
        case .notARoyalDocument:
            "This file is not a Royal TSX document. Termora expects an .rtsz file that holds XML."
        case let .malformedXML(detail):
            "The Royal TSX document is damaged. \(detail)"
        }
    }
}

/// Reads a Royal TSX document.
///
/// The document is XML: one `RTSZDocument` element whose children are the
/// objects, each holding simple text fields. A compressed `.rtsz` is not
/// supported, because Royal TSX writes plain XML for a document that has no
/// document password.
public final class RoyalDocumentParser: NSObject {
    private var objects: [RoyalObject] = []
    private var currentType: String?
    private var currentFields: [String: String] = [:]
    private var currentField: String?
    private var currentText = ""
    private var depth = 0
    private var failure: RoyalParseError?

    public override init() { super.init() }

    public func parse(contentsOf url: URL) throws -> [RoyalObject] {
        guard let data = try? Data(contentsOf: url) else {
            throw RoyalParseError.cannotReadFile(url.path)
        }
        return try parse(data: data)
    }

    public func parse(data: Data) throws -> [RoyalObject] {
        objects = []
        failure = nil

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            if let failure { throw failure }
            let reason = parser.parserError?.localizedDescription ?? "Unknown reason."
            throw RoyalParseError.malformedXML(reason)
        }
        if let failure { throw failure }
        guard !objects.isEmpty else { throw RoyalParseError.notARoyalDocument }
        return objects
    }
}

extension RoyalDocumentParser: XMLParserDelegate {
    public func parser(_ parser: XMLParser, didStartElement elementName: String,
                       namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String]) {
        depth += 1
        switch depth {
        case 1:
            // The root must be RTSZDocument.
            if elementName != "RTSZDocument" {
                failure = .notARoyalDocument
                parser.abortParsing()
            }
        case 2:
            currentType = elementName
            currentFields = [:]
        case 3:
            currentField = elementName
            currentText = ""
        default:
            // Royal nests a few structures, such as iTermTriggers. Their text
            // is not needed, and ignoring them keeps the parser working when
            // Royal adds more.
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard depth == 3 else { return }
        currentText += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard depth == 3 else { return }
        currentText += String(decoding: CDATABlock, as: UTF8.self)
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String,
                       namespaceURI: String?, qualifiedName: String?) {
        switch depth {
        case 2:
            if let currentType {
                objects.append(RoyalObject(type: currentType, fields: currentFields))
            }
            currentType = nil
            currentFields = [:]
        case 3:
            if let currentField {
                currentFields[currentField] = currentText
            }
            currentField = nil
            currentText = ""
        default:
            break
        }
        depth -= 1
    }
}
