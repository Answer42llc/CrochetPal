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
    @State private var isPreparingSource = false
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
                        importFromURL()
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPreparingSource)
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
                        importFromText()
                    }
                    .disabled(patternText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPreparingSource)
                }

                Section("Import From Image") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose From Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isPreparingSource)

                    if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                        Button("Use Sample Image") {
                            Task { await importSampleImage() }
                        }
                        .disabled(isPreparingSource)
                    }
                }

                Section("Import From PDF") {
                    Button {
                        showPDFImporter = true
                    } label: {
                        Label("Choose PDF File", systemImage: "doc.richtext")
                    }
                    .disabled(isPreparingSource)
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
                if isPreparingSource {
                    ProgressView("Preparing source...")
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

    private func importFromURL() {
        startImport {
            try container.repository.startWebImport(from: urlText)
        }
    }

    private func importFromPhotoPicker(_ item: PhotosPickerItem) async {
        await prepareSource {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PatternImportFailure.invalidResponse("empty_image_data")
            }
            let fileName = item.supportedContentTypes.first?.preferredFilenameExtension.map { "pattern.\($0)" } ?? "pattern.jpg"
            return try container.repository.startImageImport(data: data, fileName: fileName)
        }
    }

    private func importFromText() {
        startImport {
            try container.repository.startTextImport(from: patternText)
        }
    }

    private func importFromPDFPicker(_ result: Result<[URL], Error>) async {
        await prepareSource {
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
            return try container.repository.startPDFImport(data: data, fileName: fileName)
        }
    }

    private func importSampleImage() async {
        await prepareSource {
            try container.repository.startImageImport(
                data: SampleDataFactory.sampleImageData,
                fileName: "sample.png"
            )
        }
    }

    private func startImport(_ enqueue: () throws -> UUID) {
        errorMessage = nil
        do {
            let projectID = try enqueue()
            onImported(projectID)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func prepareSource(_ block: @escaping () async throws -> UUID) async {
        errorMessage = nil
        isPreparingSource = true
        defer { isPreparingSource = false }

        do {
            let projectID = try await block()
            onImported(projectID)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
