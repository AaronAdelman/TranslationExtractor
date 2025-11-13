//
//  ContentView.swift
//  TranslationExtractor
//
//  Created by אהרן שלמה אדלמן on 28/09/2025.
//

import SwiftUI
import SwiftData
import Foundation



// MARK: - SwiftUI View
struct ContentView: View {
    @State private var pageTitle: String = "Earth Hour"
    @State private var languageCode: String = "en"
    @State private var jsonOutput: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wikipedia Translations")
                .font(.title2)
                .bold()
            
            TextField("Enter page title (e.g. Earth Hour)", text: $pageTitle)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .submitLabel(.go)
                .onSubmit {
                    // Only trigger if not currently loading and input isn't empty
                    if !isLoading && !pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        extract()
                    }
                }
            
            TextField("Enter language code (e.g. en)", text: $languageCode)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            HStack {
                Button(action: extract) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(minWidth: 80)
                    } else {
                        Text("Extract")
                            .frame(minWidth: 80)
                    }
                }
                .disabled(isLoading || pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
                
                Button(action: copyToClipboard) {
                    Text("Copy JSON")
                }
                .disabled(jsonOutput.isEmpty)
            }
            
            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Text("Result (JSON):")
                .font(.headline)
            
            TextEditor(text: $jsonOutput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                .disabled(true)
            
            Spacer()
        }
        .padding()
    }
    
    private func extract() {
        errorMessage = nil
        jsonOutput = ""
        isLoading = true
        
        Task {
            do {
                let dict = try await fetchWikipediaTranslations(for: pageTitle.preprocessed, languageCode: languageCode)
                // Serialize to pretty-printed JSON sorted by key for copy-paste
                let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [
//                    .prettyPrinted,
                        .sortedKeys])
                if let s = String(data: jsonData, encoding: .utf8) {
                    jsonOutput = s
                } else {
                    jsonOutput = "{}"
                }
            } catch let wikiError as WikiFetchError {
                errorMessage = wikiError.errorDescription ?? "Unknown error"
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
    
    private func copyToClipboard() {
        guard !jsonOutput.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonOutput, forType: .string)
    }
}



#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
