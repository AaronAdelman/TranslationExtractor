//
//  StringExtensions.swift
//  TranslationExtractor
//
//  Created by אהרן שלמה אדלמן on 13/11/2025.
//

import Foundation

extension String {
    var preprocessed: String {
        
        return self.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
    }
    
    func postprocessed(key: String) -> String {
        switch key {
        case "he":
            let result = self.replacingOccurrences(of: "הבין-לאומי", with: "הבינלאומי").replacingOccurrences(of: "-", with: "־").replacingOccurrences(of: "'", with: "׳").replacingOccurrences(of: "\"", with: "״")
            return result

        default:
            let result = self.replacingOccurrences(of: "'", with: "’")
            return result
        }
    }
}
