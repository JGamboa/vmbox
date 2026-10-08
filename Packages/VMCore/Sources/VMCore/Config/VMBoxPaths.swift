import Foundation

public enum VMBoxPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VMBox", directoryHint: .isDirectory)
    }
    public static var vms: URL { appSupport.appending(path: "VMs", directoryHint: .isDirectory) }
    public static var cache: URL { appSupport.appending(path: "Cache", directoryHint: .isDirectory) }
    public static var mcpLog: URL { appSupport.appending(path: "mcp.log") }
}
