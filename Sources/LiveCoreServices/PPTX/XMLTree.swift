import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A small read-only XML tree. Element names lose their namespace prefix ("p:sp" → "sp");
/// attribute names keep it ("r:embed").
public final class XMLTree {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [XMLTree] = []
    public private(set) var text = ""

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    public static func parse(_ data: Data) -> XMLTree? {
        let builder = Builder()
        let p = XMLParser(data: data)
        p.delegate = builder
        return p.parse() ? builder.root : nil
    }

    public subscript(_ attribute: String) -> String? { attributes[attribute] }
    public func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }
    public func children(_ name: String) -> [XMLTree] { children.filter { $0.name == name } }
    /// Follows a path of child names ("spPr", "xfrm", "off").
    public func at(_ path: String...) -> XMLTree? { path.reduce(self as XMLTree?) { $0?.child($1) } }
    /// First element with this name anywhere below (depth first).
    public func find(_ name: String) -> XMLTree? {
        for c in children { if c.name == name { return c }; if let f = c.find(name) { return f } }
        return nil
    }
    public func double(_ attribute: String) -> Double? { attributes[attribute].flatMap(Double.init) }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let node = XMLTree(name: local, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
