import Foundation

public enum SharedFolderNaming {
    /// Etiqueta VirtioFS en invitados Linux.
    public static let linuxTag = "vmbox"
    public static let linuxMountPoint = "/mnt/vmbox"
    public static let macOSMountPoint = "/Volumes/My Shared Files"

    /// Nombre de cada carpeta dentro del share: último componente, con sufijo -2, -3… si se repite.
    public static func shareNames(for folders: [SharedFolder]) -> [String] {
        var used: Set<String> = []
        return folders.enumerated().map { index, folder in
            let base = URL(filePath: folder.path).lastPathComponent.isEmpty ? "carpeta\(index + 1)" : URL(filePath: folder.path).lastPathComponent
            var name = base
            var n = 2
            while used.contains(name) {
                name = "\(base)-\(n)"
                n += 1
            }
            used.insert(name)
            return name
        }
    }

    public static func guestHint(for os: GuestOS) -> String {
        switch os {
        case .linux: "En Ubuntu: sudo mkdir -p \(linuxMountPoint) && sudo mount -t virtiofs \(linuxTag) \(linuxMountPoint)"
        case .macOS: "En macOS aparecen solas en \(macOSMountPoint)"
        }
    }
}
