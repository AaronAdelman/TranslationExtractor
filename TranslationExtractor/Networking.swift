//
//  Networking.swift
//  TranslationExtractor
//
//  Created by אהרן שלמה אדלמן on 13/11/2025.
//

import Foundation


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
