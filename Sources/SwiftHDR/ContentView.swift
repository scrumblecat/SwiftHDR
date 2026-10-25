import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: ConverterViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    dropZone
                    if !viewModel.jobs.isEmpty { queue }
                    lookSelection
                    destination
                    if !viewModel.isCheckingTools && (!viewModel.ffmpegAvailable || !viewModel.hardwareEncoderAvailable) {
                        availabilityNote
                    }
                }
                .padding(32)
                .frame(maxWidth: 840)
                .frame(maxWidth: .infinity)
            }
            Divider()
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.accentColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SwiftHDR")
                .font(.system(size: 28, weight: .semibold))
            Text("Convert your videos to HDR")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            if viewModel.jobs.isEmpty {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop your videos here")
                    .font(.headline)
                Text("MP4, MOV or M4V · SDR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.chooseInputFiles()
            } label: {
                Label(viewModel.jobs.isEmpty ? "Choose Videos…" : "Add Videos…", systemImage: "plus")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, viewModel.jobs.isEmpty ? 30 : 16)
        .background(
            viewModel.isDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    viewModel.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isDropTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url {
                        Task { @MainActor in viewModel.addFiles([url]) }
                    }
                }
            }
            return !providers.isEmpty
        }
    }

    private var lookSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Look").font(.headline)
            Picker("Look", selection: $viewModel.preset) {
                ForEach(HDRPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .disabled(viewModel.isConverting)

            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.preset.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text("≈\(viewModel.preset.peakNits) nits")
                    .monospacedDigit()
                    .help("Nominal peak on a 1,000-nit reference HLG display. Actual brightness adapts to your display.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var destination: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Save to").font(.callout.weight(.medium))
                Text(viewModel.outputFolder?.path ?? "Same folder as each original")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.outputFolder?.path ?? "An HDR copy is saved beside each source video.")
            }
            Spacer(minLength: 0)
            Button("Choose…") { viewModel.chooseOutputFolder() }
                .disabled(viewModel.isConverting)
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(viewModel.jobs.count) video\(viewModel.jobs.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                if viewModel.jobs.contains(where: { [.complete, .failed, .cancelled].contains($0.state) }) {
                    Button("Clear Finished") { viewModel.clearFinished() }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.isConverting)
                }
            }
            VStack(spacing: 0) {
                ForEach(viewModel.jobs) { job in
                    jobRow(job)
                    if job.id != viewModel.jobs.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func jobRow(_ job: VideoJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stateIcon(job.state)
                .frame(width: 18, height: 18)
                .accessibilityLabel(job.state.label)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.inputURL.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.inputURL.path)
                Text(job.detail)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if job.state == .converting {
                    ProgressView(value: job.progress)
                        .accessibilityLabel("Conversion progress")
                        .accessibilityValue("\(Int(job.progress * 100)) percent")
                }
            }
            Spacer(minLength: 8)
            if job.state == .converting {
                Text(job.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            } else if job.state == .complete {
                Button { viewModel.reveal(job) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(job.inputURL.lastPathComponent) in Finder")
            } else if !viewModel.isConverting {
                Button { viewModel.remove(job.id) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove video")
                .accessibilityLabel("Remove \(job.inputURL.lastPathComponent)")
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func stateIcon(_ state: JobState) -> some View {
        switch state {
        case .inspecting, .converting:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "film").foregroundStyle(.secondary)
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var availabilityNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(viewModel.ffmpegStatus, systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
            Text(viewModel.ffmpegAvailable
                 ? "SwiftHDR requires Apple hardware for 10-bit HEVC. Close other video exports, then try again."
                 : "Install FFmpeg with the required video filters: brew install ffmpeg-full")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                if !viewModel.ffmpegAvailable {
                    Button("Copy Install Command") { viewModel.copyInstallCommand() }
                }
                Button("Check Again") { viewModel.refreshFFmpeg() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.isCheckingTools ? "Preparing…" : viewModel.isConverting ? "Creating HDR…" : "10-bit HLG · Apple hardware")
                    .font(.callout.weight(.medium))
                Text("Originals stay untouched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if viewModel.isConverting {
                Button("Stop") { viewModel.cancelConversion() }
                    .controlSize(.large)
            } else {
                Button("Convert to HDR") { viewModel.startConversion() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!viewModel.canConvert)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .background(.bar)
    }
}
