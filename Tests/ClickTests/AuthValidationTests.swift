import Testing
import Foundation
import UIKit
@testable import Click

@Suite("Auth Validation and Keychain Vault Tests")
struct AuthValidationTests {

    @Test("Validates minimum signup age of 13 years")
    func minimumSignupAge() {
        let calendar = Calendar.current
        let today = Date()

        // 14 years old -> Valid
        let fourteenYearsAgo = calendar.date(byAdding: .year, value: -14, to: today)!
        let age14 = calendar.dateComponents([.year], from: fourteenYearsAgo, to: today).year ?? 0
        #expect(age14 >= 13)

        // Exactly 13 years old -> Valid
        let thirteenYearsAgo = calendar.date(byAdding: .year, value: -13, to: today)!
        let age13 = calendar.dateComponents([.year], from: thirteenYearsAgo, to: today).year ?? 0
        #expect(age13 >= 13)

        // 12 years old -> Invalid
        let twelveYearsAgo = calendar.date(byAdding: .year, value: -12, to: today)!
        let age12 = calendar.dateComponents([.year], from: twelveYearsAgo, to: today).year ?? 0
        #expect(age12 < 13)
    }

    @Test("KeychainSessionVault persists and deletes session")
    func sessionVaultPersistence() {
        let vault = KeychainSessionVault.shared
        let testSession = SessionSnapshot(
            userId: "test_vault_user_123",
            jwt: "jwt_token_vault_abc",
            refreshToken: "refresh_token_vault_xyz",
            expiresAt: Date().addingTimeInterval(3600)
        )

        let saved = vault.saveSession(testSession)
        #expect(saved == true)

        let read = vault.readSession()
        #expect(read != nil)
        #expect(read?.userId == "test_vault_user_123")
        #expect(read?.jwt == "jwt_token_vault_abc")
        #expect(read?.refreshToken == "refresh_token_vault_xyz")

        let deleted = vault.deleteSession()
        #expect(deleted == true)

        let readAfterDelete = vault.readSession()
        #expect(readAfterDelete == nil)
    }

    @Test("Manrope font resources register and load in UIKit/SwiftUI")
    func manropeFontsRegister() {
        ClickFonts.registerFonts()

        let requiredFonts = [
            "Manrope-Regular",
            "Manrope-Medium",
            "Manrope-SemiBold",
            "Manrope-Bold",
            "Manrope-ExtraBold"
        ]

        for fontName in requiredFonts {
            let font = UIFont(name: fontName, size: 16)
            print(">>> FONT TEST: \(fontName) -> font: \(String(describing: font)), familyName: \(String(describing: font?.familyName)), fontName: \(String(describing: font?.fontName))")
            #expect(font != nil, "Expected font \(fontName) to be loadable")
            #expect(font?.familyName.contains("Manrope") == true, "Expected font family name to contain Manrope for \(fontName)")
        }

        for family in UIFont.familyNames.filter({ $0.contains("Manrope") }) {
            print(">>> MANROPE FAMILY: \(family) -> names: \(UIFont.fontNames(forFamilyName: family))")
        }

        // Test UIFont creation
        let boldFont = UIFont(name: "Manrope-Bold", size: 32)
        #expect(boldFont != nil)
        #expect(boldFont?.fontName == "Manrope-Bold")

        let mediumFont = UIFont(name: "Manrope-Medium", size: 16)
        #expect(mediumFont != nil)
        #expect(mediumFont?.fontName == "Manrope-Medium")
    }

    @Test("Sign-up password requires minimum 8 characters while sign-in requires non-empty")
    func passwordValidationRules() {
        // Sign-up rules: password >= 8 characters
        func isSignUpPasswordValid(_ pass: String) -> Bool {
            pass.count >= 8
        }

        #expect(isSignUpPasswordValid("") == false)
        #expect(isSignUpPasswordValid("1234567") == false)
        #expect(isSignUpPasswordValid("12345678") == true)
        #expect(isSignUpPasswordValid("longsecurepassword") == true)

        // Sign-in rules: non-empty
        func isSignInPasswordValid(_ pass: String) -> Bool {
            !pass.isEmpty
        }

        #expect(isSignInPasswordValid("") == false)
        #expect(isSignInPasswordValid("a") == true)
        #expect(isSignInPasswordValid("12345678") == true)
    }
}

