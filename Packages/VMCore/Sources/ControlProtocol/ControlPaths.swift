import Foundation

public enum ControlPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VMBox", directoryHint: .isDirectory)
    }

    public static var socketPath: String { appSupport.appending(path: "control.sock").path }
}
