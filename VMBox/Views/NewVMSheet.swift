import SwiftUI
import UniformTypeIdentifiers
import VMCore

struct NewVMSheet: View {
    enum Step { case system, resources, name, progress }
    enum Source: Hashable { case latest, localFile }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.system
    @State private var os = GuestOS.linux
    @State private var source = Source.latest
    @State private var localFile: URL?
    @State private var showingImporter = false
    @State private var config = VMConfig.defaults(for: .linux, name: "")
    @State private var phase: CreationPhase?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    private let maxCPU = ProcessInfo.processInfo.processorCount
    private let maxMemoryGiB = Int(ProcessInfo.processInfo.physicalMemory / .gib) - 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .system: systemStep
            case .resources: resourcesStep
            case .name: nameStep
            case .progress: progressStep
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [mediaType]) { result in
            if case .success(let url) = result { localFile = url }
        }
    }

    private var mediaType: UTType {
        os == .macOS ? (UTType(filenameExtension: "ipsw") ?? .data) : (UTType(filenameExtension: "iso") ?? .data)
    }

    private var systemStep: some View {
        Group {
            Text("1. Sistema").font(.headline)
            Picker("Sistema", selection: $os) {
                ForEach(GuestOS.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Origen", selection: $source) {
                Text(os == .macOS ? "Última versión compatible" : "Última LTS (\(UbuntuRelease.version))").tag(Source.latest)
                Text(os == .macOS ? "IPSW propio…" : "ISO propio…").tag(Source.localFile)
            }
            .pickerStyle(.radioGroup)
            if source == .localFile {
                HStack {
                    Text(localFile?.lastPathComponent ?? "Ningún archivo").foregroundStyle(.secondary)
                    Button("Elegir…") { showingImporter = true }
                }
            }
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Siguiente") {
                    let name = model.suggestedName(for: os)
                    config = VMConfig.defaults(for: os, name: name)
                    step = .resources
                }
                .disabled(source == .localFile && localFile == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var resourcesStep: some View {
        Group {
            Text("2. Recursos").font(.headline)
            Stepper("CPU: \(config.cpuCount)", value: $config.cpuCount, in: 1...maxCPU)
            Stepper("Memoria: \(config.memoryBytes / .gib) GB",
                    value: Binding(get: { Int(config.memoryBytes / .gib) }, set: { config.memoryBytes = UInt64($0) * .gib }),
                    in: 2...max(2, maxMemoryGiB))
            Stepper("Disco: \(config.diskBytes / .gib) GB",
                    value: Binding(get: { Int(config.diskBytes / .gib) }, set: { config.diskBytes = UInt64($0) * .gib }),
                    in: 20...1000, step: 10)
            HStack {
                Button("Atrás") { step = .system }
                Spacer()
                Button("Siguiente") { step = .name }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var nameStep: some View {
        Group {
            Text("3. Nombre").font(.headline)
            TextField("Nombre", text: $config.name)
            HStack {
                Button("Atrás") { step = .resources }
                Spacer()
                Button("Crear") { create() }
                    .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var progressStep: some View {
        Group {
            Text("Creando «\(config.name)»").font(.headline)
            switch phase {
            case .preparing, nil: ProgressView("Preparando…")
            case .downloading(let f): ProgressView("Descargando…", value: f)
            case .installing(let f): ProgressView("Instalando macOS…", value: f)
            case .finished: Text("Lista.")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if errorMessage != nil {
                    Button("Cerrar") { dismiss() }
                } else {
                    Button("Cancelar") { task?.cancel() }
                }
            }
        }
    }

    private func create() {
        step = .progress
        let config = self.config
        let file = source == .localFile ? localFile : nil
        task = Task {
            do {
                try await model.createVM(config: config, localFile: file) { phase = $0 }
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
