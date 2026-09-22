import Foundation

/// Shorthand for NSLocalizedString. The strings live in
/// `Resources/en.lproj/Localizable.strings`; another language means adding
/// a `<code>.lproj` next to it with the same keys.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
