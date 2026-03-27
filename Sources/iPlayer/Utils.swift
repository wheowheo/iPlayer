import Foundation

func log(_ message: String) {
    fputs("\(message)\n", stderr)
}
