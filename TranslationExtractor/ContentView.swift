//
//  ContentView.swift
//  TranslationExtractor
//
//  Created by אהרן שלמה אדלמן on 28/09/2025.
//

import SwiftUI
import SwiftData

//struct ContentView: View {
//    @Environment(\.modelContext) private var modelContext
//    @Query private var items: [Item]
//
//    var body: some View {
//        NavigationSplitView {
//            List {
//                ForEach(items) { item in
//                    NavigationLink {
//                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
//                    } label: {
//                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
//                    }
//                }
//                .onDelete(perform: deleteItems)
//            }
//#if os(macOS)
//            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
//#endif
//            .toolbar {
//#if os(iOS)
//                ToolbarItem(placement: .navigationBarTrailing) {
//                    EditButton()
//                }
//#endif
//                ToolbarItem {
//                    Button(action: addItem) {
//                        Label("Add Item", systemImage: "plus")
//                    }
//                }
//            }
//        } detail: {
//            Text("Select an item")
//        }
//    }
//
//    private func addItem() {
//        withAnimation {
//            let newItem = Item(timestamp: Date())
//            modelContext.insert(newItem)
//        }
//    }
//
//    private func deleteItems(offsets: IndexSet) {
//        withAnimation {
//            for index in offsets {
//                modelContext.delete(items[index])
//            }
//        }
//    }
//}

import SwiftUI
import Foundation
//import UIKit // remove if targeting macOS

// MARK: - Models
struct WikipediaAPIResponse: Codable {
    let query: Query?
}

struct Query: Codable {
    let pages: [String: Page]?
}

struct Page: Codable {
    let langlinks: [LangLink]?
}

struct LangLink: Codable {
    let lang: String
    let title: String
    
    enum CodingKeys: String, CodingKey {
        case lang
        case title = "*"
    }
}

// MARK: - Errors
enum WikiFetchError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int)
    case noData
    case decodingError(underlying: Error)
    case pageNotFound
    case cannotFindHost(original: NSError)
    case other(original: Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .httpError(let code):
            return "HTTP error: \(code)."
        case .noData:
            return "No data returned from server."
        case .decodingError(let e):
            return "Failed parsing response: \(e.localizedDescription)"
        case .pageNotFound:
            return "Page not found in API response."
        case .cannotFindHost(let ns):
            return "Cannot find host — DNS or network issue. (\(ns.code)): \(ns.localizedDescription)"
        case .other(let e):
            return e.localizedDescription
        }
    }
}

// MARK: - Network function
/// Fetches translations from Wikipedia API and returns [langCode: title].
func fetchWikipediaTranslations(for pageTitle: String) async throws -> [String: String] {
    let endpoint = "https://en.wikipedia.org/w/api.php"
    guard var components = URLComponents(string: endpoint) else {
        throw WikiFetchError.invalidURL
    }
    
    components.queryItems = [
        URLQueryItem(name: "action", value: "query"),
        URLQueryItem(name: "titles", value: pageTitle),
        URLQueryItem(name: "prop", value: "langlinks"),
        URLQueryItem(name: "lllimit", value: "500"),
        URLQueryItem(name: "format", value: "json")
    ]
    
    guard let url = components.url else {
        throw WikiFetchError.invalidURL
    }
    
    // Debug: print the final URL you will request
    print("[DEBUG] Request URL:", url.absoluteString)
    
    do {
        let (data, response) = try await URLSession.shared.data(from: url)
        
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WikiFetchError.httpError(statusCode: http.statusCode)
        }
        
        guard data.count > 0 else {
            throw WikiFetchError.noData
        }
        
        do {
            let decoder = JSONDecoder()
            let api = try decoder.decode(WikipediaAPIResponse.self, from: data)
            guard let pages = api.query?.pages, let page = pages.values.first else {
                throw WikiFetchError.pageNotFound
            }
            
            var map: [String: String] = [:]
            if let links = page.langlinks {
                for l in links {
                    map[l.lang] = l.title
                }
            }
            // Always include the input English title as "en"
            map["en"] = pageTitle
            return map
        } catch {
            throw WikiFetchError.decodingError(underlying: error)
        }
    } catch {
        // Convert known networking errors to friendlier variants
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotFindHost {
            throw WikiFetchError.cannotFindHost(original: ns)
        } else {
            throw WikiFetchError.other(original: error)
        }
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @State private var pageTitle: String = "Earth Hour"
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
                let dict = try await fetchWikipediaTranslations(for: pageTitle)
                // Serialize to pretty-printed JSON sorted by key for copy-paste
                let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
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
//        UIPasteboard.general.string = jsonOutput
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonOutput, forType: .string)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
