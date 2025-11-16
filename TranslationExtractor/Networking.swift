//
//  Networking.swift
//  TranslationExtractor
//
//  Created by אהרן שלמה אדלמן on 13/11/2025.
//

import Foundation

// MARK: - Source selection
enum TranslationSource: String, CaseIterable, Identifiable {
    case wikipedia
    case wiktionary
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .wikipedia: return "Wikipedia"
        case .wiktionary: return "Wiktionary"
        }
    }
}

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

// MARK: - Lightweight HTML helpers for Wiktionary parsing
private extension String {
    /// Very conservative HTML text stripping for small snippets.
    func htmlStripped() -> String {
        var s = self
        // Remove tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode a couple of common entities
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&apos;", with: "'")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        // Convert non-breaking space entity to a unique marker we can trim on later
        s = s.replacingOccurrences(of: "&#160;", with: "\u{00A0}")
        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }
}

private extension String {
    /// Removes common Wiktionary adornments like IPA, gender markers, and parenthetical notes.
    func strippedOfWiktionaryAdornments() -> String {
        var s = self
        // Truncate at first NBSP (often separates headword from gloss/notes)
        if let nb = s.firstIndex(of: "\u{00A0}") {
            s = String(s[..<nb])
        }
        // Remove IPA between slashes or brackets: /.../ or [ ... ]
        s = s.replacingOccurrences(of: "/[^/]+/", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[[^\\]]+\\]", with: "", options: .regularExpression)
        // Remove parenthetical notes like (f), (m), (plural), (transliteration), (pronunciation)
        s = s.replacingOccurrences(of: "\\([^\\)]*\\)", with: "", options: .regularExpression)
        // Remove common gender/grammar abbreviations when left hanging at start/end
        s = s.replacingOccurrences(of: "\\b(m|f|n|pl|sg|masc|fem|neut)\\b\\.*$", with: "", options: [.regularExpression, .caseInsensitive])
        // Collapse punctuation artifacts and whitespace
        s = s.replacingOccurrences(of: "[•··]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func wiktionaryAdjust(term: String, forLangCode code: String) -> String {
    var t = term
    // Remove redundant label for Mandarin in cmn entries
    if code.lowercased() == "cmn" {
        t = t.replacingOccurrences(of: "^Mandarin:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Wiktionary network function
/// Fetches translations from Wiktionary by parsing the Translations section.
/// Returns a map of [langCode: term]. This is a best-effort parser and may not catch all layouts.
func fetchWiktionaryTranslations(for pageTitle: String, languageCode: String) async throws -> [String: String] {
    let endpoint = "https://\(languageCode).wiktionary.org/w/api.php"
    guard var components = URLComponents(string: endpoint) else { throw WikiFetchError.invalidURL }

    components.queryItems = [
        URLQueryItem(name: "action", value: "parse"),
        URLQueryItem(name: "page", value: pageTitle),
        URLQueryItem(name: "prop", value: "text"),
        URLQueryItem(name: "format", value: "json")
    ]
    guard let url = components.url else { throw WikiFetchError.invalidURL }

    print("[DEBUG] Wiktionary Request URL:", url.absoluteString)

    do {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WikiFetchError.httpError(statusCode: http.statusCode)
        }
        guard data.count > 0 else { throw WikiFetchError.noData }

        // The parse response is `{ parse: { text: { "*": "<html>..." } } }`.
        struct ParseText: Codable { let text: [String:String]? }
        struct ParseResponse: Codable { let parse: ParseText? }

        do {
            let decoder = JSONDecoder()
            let parsed = try decoder.decode(ParseResponse.self, from: data)
            guard let html = parsed.parse?.text?["*"] else { throw WikiFetchError.pageNotFound }

            // Heuristic: find a block that looks like the Translations section.
            // We look for an h2/h3 with id or span containing "Translations" and then scan following list items.
            var results: [String:String] = [:]

            // Narrow to the translations area if possible
            let lower = html.lowercased()
            let anchors = ["id=\"translations\"", ">translations<", ">translation<"]
            var startIndex = lower.startIndex
            for a in anchors {
                if let r = lower.range(of: a) {
                    startIndex = r.lowerBound
                    break
                }
            }
            let tail = String(html[startIndex...])

            // Extract list items within a reasonable window to avoid parsing whole page
            // This regex finds list items like <li>xx: term</li> or with <span lang="xx">term</span>
            let liRegex = try? NSRegularExpression(pattern: "<li[ ^>]*>(.*?)</li>", options: [.dotMatchesLineSeparators, .caseInsensitive])
            let fullRange = NSRange(location: 0, length: (tail as NSString).length)
            let matches = liRegex?.matches(in: tail, options: [], range: fullRange) ?? []

            for m in matches.prefix(400) { // limit scanning
                let liHTML = (tail as NSString).substring(with: m.range(at: 1))

                // Try to capture explicit lang code attributes first
                if let langAttr = try? NSRegularExpression(pattern: "lang=\\\"([a-zA-Z-]{2,})\\\"", options: .caseInsensitive),
                   let lm = langAttr.firstMatch(in: liHTML, options: [], range: NSRange(location: 0, length: (liHTML as NSString).length)) {
                    let code = (liHTML as NSString).substring(with: lm.range(at: 1)).lowercased()
                    let text = liHTML.htmlStripped()
                    // Often the line starts with language name; attempt to split on ':' if present
                    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    let term = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : text
                    var cleaned = term.strippedOfWiktionaryAdornments()
                    cleaned = wiktionaryAdjust(term: cleaned, forLangCode: code)
                    if !cleaned.isEmpty { results[code] = cleaned }
                    continue
                }

                // Fallback: look for pattern like "xx: term"
                if let colon = liHTML.htmlStripped().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).map(String.init) as [String]? , colon.count == 2 {
                    let keyCandidate = colon[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let value = colon[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    // Accept two/three-letter codes heuristically
                    if keyCandidate.count <= 5 && keyCandidate.range(of: "^[a-z-]{2,5}$", options: .regularExpression) != nil {
                        var cleaned = value.strippedOfWiktionaryAdornments()
                        cleaned = wiktionaryAdjust(term: cleaned, forLangCode: keyCandidate)
                        if !cleaned.isEmpty { results[keyCandidate] = cleaned }
                    }
                }
            }

            // Include the input title for the source language and drop Simple English
            results[languageCode] = pageTitle
            results["simple"] = nil

            // Postprocess like Wikipedia path if available
            var cleaned: [String:String] = [:]
            for (k,v) in results { cleaned[k] = v.postprocessed(key: k) }
            return cleaned
        } catch {
            throw WikiFetchError.decodingError(underlying: error)
        }
    } catch {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotFindHost {
            throw WikiFetchError.cannotFindHost(original: ns)
        } else {
            throw WikiFetchError.other(original: error)
        }
    }
}

// MARK: - Network function
/// Fetches translations from Wikipedia API and returns [langCode: title].
func fetchWikipediaTranslations(for pageTitle: String, languageCode: String) async throws -> [String: String] {
    let endpoint = "https://\(languageCode).wikipedia.org/w/api.php"
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
            map[languageCode] = pageTitle
            map["simple"] = nil // We don’t want a Simple English translation
            
            for key in map.keys {
                map[key] = map[key]?.postprocessed(key: key)
            }
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

// MARK: - Unified fetcher
func fetchTranslations(from source: TranslationSource, pageTitle: String, languageCode: String, capitalize: Bool = false) async throws -> [String:String] {
    let dict: [String:String]
    switch source {
    case .wikipedia:
        dict = try await fetchWikipediaTranslations(for: pageTitle, languageCode: languageCode)
    case .wiktionary:
        dict = try await fetchWiktionaryTranslations(for: pageTitle, languageCode: languageCode)
    }
    if capitalize {
        var capped: [String:String] = [:]
        for (k,v) in dict { capped[k] = v.capitalized }
        return capped
    } else {
        return dict
    }
}

