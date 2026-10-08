/// Practice owns its language. File names take precedence; plain text needs recognizable code syntax.
public enum PracticeLanguage {
    public static func detect(_ text: String, fileName: String? = nil) -> SubMode {
        if let ext = fileName?.split(separator: ".").last?.lowercased(),
           ["c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx"].contains(ext) { return .cpp }
        let source = text.lowercased()
        if source.contains("#include") || source.contains("std::") || source.contains("template<")
            || source.contains("template <") || source.contains("int main(") { return .cpp }
        let declarations = ["int ", "bool ", "auto ", "const ", "void ", "double ", "float ", "char "]
        let hasDeclaration = source.split(separator: "\n").contains { line in
            let trimmed = line.drop(while: \.isWhitespace)
            return declarations.contains { trimmed.hasPrefix($0) }
        }
        let hasCodeStructure = source.contains(";") && (source.contains("=") || source.contains("{"))
        if hasDeclaration && hasCodeStructure { return .cpp }
        if source.contains("{") && source.contains("}") && source.contains(";")
            && ["if (", "if(", "for (", "for(", "while (", "while("].contains(where: source.contains) {
            return .cpp
        }
        return .english
    }
}
