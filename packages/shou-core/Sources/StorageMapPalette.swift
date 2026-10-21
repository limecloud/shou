import Foundation

/// Shared type identity for desktop legends, leaf tiles and bridge clients.
/// Directory surfaces are neutral; an extension never implies removability.
public enum StorageMapPalette {
    public static func hex(forExtension suffix: String) -> String {
        switch suffix.lowercased() {
        case "": return "#B96C16"
        case "js", "mjs", "cjs": return "#818990"
        case "dylib", "so", "dll": return "#27AC42"
        case "sqlite", "sqlite3": return "#943DE1"
        case "bin": return "#D23A9D"
        case "db": return "#20B5D9"
        case "json": return "#7060EE"
        case "zip", "gz", "xz", "zst", "7z", "rar": return "#AD70D6"
        case "dmg", "iso": return "#E83C4B"
        case "png", "jpg", "jpeg", "webp", "heic": return "#88AA25"
        case "pack", "pak": return "#B59A29"
        case "map": return "#9D6831"
        case "o", "rlib", "a": return "#51738F"
        case "ts", "tsx": return "#13AFA6"
        case "go": return "#249FCA"
        case "py", "pyc": return "#6089CD"
        case "node": return "#59A650"
        case "html", "css": return "#CF6244"
        case "log", "dat", "asar": return "#76877E"
        default:
            let hash=suffix.lowercased().utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
            let hue=Double(hash % 360)/60, chroma=0.55, base=0.20
            let x=chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
            let rgb: (Double, Double, Double)
            switch Int(hue) {
            case 0: rgb=(chroma,x,0)
            case 1: rgb=(x,chroma,0)
            case 2: rgb=(0,chroma,x)
            case 3: rgb=(0,x,chroma)
            case 4: rgb=(x,0,chroma)
            default: rgb=(chroma,0,x)
            }
            return String(format: "#%02X%02X%02X", Int((rgb.0+base)*255), Int((rgb.1+base)*255), Int((rgb.2+base)*255))
        }
    }
}
