//
//  ContentView.swift
//  OfficeAI
//
//  Created by Christi John Joseph on 20/10/2025.
//

import Foundation
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import FoundationModels
import NaturalLanguage

struct ContentView: View {
    @State private var showingDocumentPicker = false
    @State private var documentURL: URL?
    @State private var extractedText = "" // Preview only
    @State private var textChunks: [String] = [] // For chunking large docs
    @State private var summary = ""
    @State private var isLoading = false
    @State private var extractionProgress = 0.0
    @State private var errorMessage = ""
    @State private var estimatedTokens = 0
    
    private let maxContextTokens = 4096 // Apple Intelligence limit
    private let safePromptTokens = 3000 // Threshold: > this = chunking
    
    var body: some View {
        VStack(spacing: 20) {
            Button("Select PDF") {
                showingDocumentPicker = true
                errorMessage = ""
            }
            .fileImporter(
                isPresented: $showingDocumentPicker,
                allowedContentTypes: [UTType.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    documentURL = urls.first
                    Task {
                        await extractTextFromPDF()
                    }
                case .failure(let error):
                    errorMessage = "File picker error: \(error.localizedDescription)"
                }
            }
            
            if !errorMessage.isEmpty {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            }
            
            if !extractedText.isEmpty {
                Text("Extracted Text Preview: \(extractedText.prefix(200))...")
                Text("Est. Tokens: \(estimatedTokens) / \(maxContextTokens)")
                    .font(.caption)
                    .foregroundColor(estimatedTokens > safePromptTokens ? .orange : .green)
                
                Button("Generate Summary") {
                    Task {
                        await generateSummary()
                    }
                }
                .disabled(isLoading)
                
                if isLoading {
                    ProgressView(value: extractionProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                }
            }
            
            if !summary.isEmpty {
                Text("Summary:")
                    .font(.headline)
                ScrollView {
                    Text(summary)
                        .lineLimit(nil) // Allow unlimited lines
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .shadow(radius: 2) // Optional: Subtle depth
                }
                .frame(maxHeight: 300) // Cap height to avoid dominating screen; adjust as needed
                .frame(maxWidth: .infinity) // Full width
            }
        }
        .padding()
    }
    
    // MARK: - Token Estimator (Rough: 1 token ≈ 4 chars)
    private func estimateTokens(_ text: String) -> Int {
        return Int(Double(text.count) / 4.0) + 200 // Buffer for instructions
    }
    
    // MARK: - Extraction with Chunk Prep
    @MainActor
    private func extractTextFromPDF() async {
        guard let url = documentURL else { return }
        extractedText = ""
        textChunks = []
        errorMessage = ""
        extractionProgress = 0.0
        estimatedTokens = 0
        
        do {
            guard let pdfDocument = PDFDocument(url: url) else {
                throw NSError(domain: "PDFKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load PDF"])
            }
            
            let totalPages = pdfDocument.pageCount
            if totalPages > 150 {
                errorMessage = "PDF too large (\(totalPages) pages). Split into smaller files."
                return
            }
            
            var fullText = ""
            for index in 0..<totalPages {
                if let page = pdfDocument.page(at: index) {
                    fullText += (page.string ?? "")
                }
                extractionProgress = Double(index + 1) / Double(totalPages)
                try await Task.sleep(nanoseconds: 5_000_000) // Yield for UI
            }
            
            // Always chunk for potential use, but set preview/full based on size
            let chunkSizeChars = 8000 // ~2K tokens
            var chunks: [String] = []
            var currentChunk = ""
            let sentences = fullText.components(separatedBy: ". ")
            
            for sentence in sentences {
                if currentChunk.count + sentence.count + 2 > chunkSizeChars {
                    if !currentChunk.isEmpty {
                        chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    currentChunk = sentence + ". "
                } else {
                    currentChunk += sentence + ". "
                }
            }
            if !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            
            textChunks = chunks
            let totalText = chunks.joined(separator: "\n\n")
            estimatedTokens = estimateTokens(totalText)
            
            // Preview: full for small, first chunk for large
            if estimatedTokens <= safePromptTokens {
                extractedText = totalText
            } else {
                extractedText = chunks.first ?? ""
            }
            
            extractionProgress = 1.0
        } catch {
            errorMessage = "Extraction failed: \(error.localizedDescription)."
            extractionProgress = 0.0
        }
    }
    
    // MARK: - Adaptive Summarization: Direct for Small, Chunked for Large
    @MainActor
    private func generateSummary() async {
        isLoading = true
        defer { isLoading = false }
        summary = ""
        extractionProgress = 0.0
        
        guard !textChunks.isEmpty else { return }
        
        let instructions = """
You are a summarization assistant. Read the provided text and generate a short, clear preview. Highlight main ideas, arguments, or takeaways only. Avoid filler, repetition, metadata, tables, or noise. Use concise bullet points.
"""
        
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        guard model.isAvailable else {
            errorMessage = "Model unavailable: Enable Apple Intelligence in Settings > Apple Intelligence & Siri."
            return
        }
        
        do {
            if estimatedTokens <= safePromptTokens {
                // Direct path for small PDFs: Fast & full context
                let totalText = textChunks.joined(separator: "\n\n")
                let prompt = """
Summarize the following content in 3–5 bullet points. Focus on the main message, key arguments, or conclusions. Keep it under 150 words.

Document:
\(totalText)
"""
                
                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt)
                summary = response.content
            } else {
                // Chunked path for large PDFs: Multi-stage
                extractionProgress = 0.0
                let chunkSizeTokens = 1500
                let chunkSizeChars = chunkSizeTokens * 4
                var chunkSummaries: [String] = []
                
                // Stage 1: Summarize tiny word-based sub-chunks
                for (index, chunk) in textChunks.enumerated() {
                    let words = chunk.components(separatedBy: .whitespacesAndNewlines)
                    var currentSubChunk = ""
                    
                    for word in words {
                        let testSubChunk = currentSubChunk + (currentSubChunk.isEmpty ? "" : " ") + word
                        if estimateTokens(testSubChunk) > chunkSizeTokens {
                            if !currentSubChunk.isEmpty {
                                let subPrompt = """
Summarize this short section in 1 bullet point. Key ideas only.

Section:
\(currentSubChunk)
"""
                                if estimateTokens(subPrompt) < safePromptTokens {
                                    let session = LanguageModelSession(model: model, instructions: instructions)
                                    let response = try await session.respond(to: subPrompt)
                                    chunkSummaries.append(response.content)
                                }
                            }
                            currentSubChunk = word
                        } else {
                            currentSubChunk = testSubChunk
                        }
                    }
                    if !currentSubChunk.isEmpty {
                        let subPrompt = """
Summarize this short section in 1 bullet point. Key ideas only.

Section:
\(currentSubChunk)
"""
                        if estimateTokens(subPrompt) < safePromptTokens {
                            let session = LanguageModelSession(model: model, instructions: instructions)
                            let response = try await session.respond(to: subPrompt)
                            chunkSummaries.append(response.content)
                        }
                    }
                    
                    extractionProgress = Double(index + 1) / Double(textChunks.count)
                }
                
                extractionProgress = 0.5
                
                // Stage 2: Group & summarize chunk summaries
                let maxSubChunks = 3
                let subChunkSize = chunkSummaries.count / maxSubChunks
                var level2Summaries: [String] = []
                
                for i in 0..<maxSubChunks {
                    let start = i * subChunkSize
                    let end = min(start + subChunkSize, chunkSummaries.count)
                    let subChunk = chunkSummaries[start..<end].joined(separator: "\n")
                    
                    let subPrompt = """
Combine these bullet points into 1-2 concise bullets. Focus on overarching themes.

Sub-section:
\(subChunk)
"""
                    if estimateTokens(subPrompt) < safePromptTokens {
                        let session = LanguageModelSession(model: model, instructions: instructions)
                        let response = try await session.respond(to: subPrompt)
                        level2Summaries.append(response.content)
                    }
                }
                
                extractionProgress = 0.75
                
                // Stage 3: Final meta-summary
                let combined = level2Summaries.joined(separator: "\n")
                let finalPrompt = """
Summarize these into 3–5 bullet points. Main message, key arguments, conclusions only. Under 150 words.

Final chunks:
\(combined)
"""
                
                if estimateTokens(finalPrompt) > safePromptTokens {
                    summary = "Text too dense for full summary. Quick overview:\n\(combined.prefix(300))..."
                } else {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    let response = try await session.respond(to: finalPrompt)
                    summary = response.content
                }
                
                extractionProgress = 1.0
            }
        } catch {
            summary = "Summarization failed: \(error.localizedDescription)."
            if error.localizedDescription.contains("exceededContextWindowSize") {
                errorMessage = "Unexpected token overflow—try a shorter doc."
            }
        }
    }
}

