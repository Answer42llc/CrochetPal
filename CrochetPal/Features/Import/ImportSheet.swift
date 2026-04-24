import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @State private var urlText = ""
    @State private var patternText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPDFImporter = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    let onImported: (UUID) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Import From Web") {
                    TextField("https://example.com/pattern", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Import URL") {
                        Task { await importFromURL() }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }

                Section("Import From Text") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $patternText)
                            .frame(minHeight: 180)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("patternTextInput")

                        if patternText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Paste the plain pattern text here.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                    Button("Import Text") {
                        Task { await importFromText() }
                    }
                    .disabled(patternText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }

                Section("Import From Image") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose From Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isImporting)

                    if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                        Button("Use Sample Image") {
                            Task { await importSampleImage() }
                        }
                    }
                }

                Section("Import From PDF") {
                    Button {
                        showPDFImporter = true
                    } label: {
                        Label("Choose PDF File", systemImage: "doc.richtext")
                    }
                    .disabled(isImporting)
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Pattern")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("Parsing pattern...")
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task(id: photoItem) {
                guard let photoItem else { return }
                await importFromPhotoPicker(photoItem)
            }
            .fileImporter(
                isPresented: $showPDFImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                Task { await importFromPDFPicker(result) }
            }
        }
    }

    private func importFromURL() async {
        await performImport {
            let record = try await container.repository.importWebPattern(from: urlText)
            onImported(record.project.id)
        }
    }

    private func importFromPhotoPicker(_ item: PhotosPickerItem) async {
        await performImport {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PatternImportFailure.invalidResponse("empty_image_data")
            }
            let fileName = item.supportedContentTypes.first?.preferredFilenameExtension.map { "pattern.\($0)" } ?? "pattern.jpg"
            let record = try await container.repository.importImagePattern(data: data, fileName: fileName)
            onImported(record.project.id)
        }
    }

    private func importFromText() async {
        await performImport {
            let record = try await container.repository.importTextPattern(from: patternText)
            onImported(record.project.id)
        }
    }

    private func importFromPDFPicker(_ result: Result<[URL], Error>) async {
        await performImport {
            let urls = try result.get()
            guard let url = urls.first else {
                throw PatternImportFailure.invalidResponse("empty_pdf_selection")
            }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let fileName = url.lastPathComponent
            let record = try await container.repository.importPDFPattern(data: data, fileName: fileName)
            onImported(record.project.id)
        }
    }

    private func importSampleImage() async {
        await performImport {
            let record = try await container.repository.importImagePattern(
                data: SampleDataFactory.sampleImageData,
                fileName: "sample.png"
            )
            onImported(record.project.id)
        }
    }

    private func performImport(_ block: @escaping () async throws -> Void) async {
        errorMessage = nil
        isImporting = true
        defer { isImporting = false }

        do {
            try await block()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
