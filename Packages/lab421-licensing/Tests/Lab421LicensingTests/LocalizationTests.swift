import Foundation
import Testing
@testable import Lab421Licensing

struct LocalizationTests {
    @Test func localizedResourcesProvideEveryKey() throws {
        let enBundle = try #require(Bundle(url: Bundle.module.bundleURL.appendingPathComponent("en.lproj")))
        let frBundle = try #require(Bundle(url: Bundle.module.bundleURL.appendingPathComponent("fr.lproj")))
        let esBundle = try #require(Bundle(url: Bundle.module.bundleURL.appendingPathComponent("es.lproj")))
        let deBundle = try #require(Bundle(url: Bundle.module.bundleURL.appendingPathComponent("de.lproj")))
        let itBundle = try #require(Bundle(url: Bundle.module.bundleURL.appendingPathComponent("it.lproj")))

        #expect(enBundle.localizedString(forKey: "license_key_required", value: nil, table: nil) == "Enter a license key.")
        #expect(frBundle.localizedString(forKey: "license_key_required", value: nil, table: nil) == "Saisissez une clé de licence.")
        #expect(esBundle.localizedString(forKey: "license_key_required", value: nil, table: nil) == "Introduce una clave de licencia.")
        #expect(deBundle.localizedString(forKey: "license_key_required", value: nil, table: nil) == "Gib einen Lizenzschlüssel ein.")
        #expect(itBundle.localizedString(forKey: "license_key_required", value: nil, table: nil) == "Inserisci una chiave di licenza.")

        #expect(enBundle.localizedString(forKey: "license_reason_license_expired", value: nil, table: nil) == "This license has expired.")
        #expect(frBundle.localizedString(forKey: "license_reason_license_expired", value: nil, table: nil) == "Cette licence a expiré.")
        #expect(esBundle.localizedString(forKey: "license_reason_license_expired", value: nil, table: nil) == "Esta licencia ha caducado.")
        #expect(deBundle.localizedString(forKey: "license_reason_license_expired", value: nil, table: nil) == "Diese Lizenz ist abgelaufen.")
        #expect(itBundle.localizedString(forKey: "license_reason_license_expired", value: nil, table: nil) == "Questa licenza è scaduta.")
    }

    @Test func licenseManagerErrorProvidesALocalizedDescriptionInEnglish() {
        withLanguageOverride("en") {
            #expect(LicenseManagerError.licenseKeyRequired.localizedDescription == "Enter a license key.")

            let storageMessage = LicenseManagerError.storage(statusCode: -25300, appName: "TestApp").localizedDescription
            #expect(storageMessage.contains("-25300"))
            // The app name appears twice in the English template ("TestApp
            // couldn't … reopen TestApp") — both interpolations must resolve.
            #expect(storageMessage.components(separatedBy: "TestApp").count - 1 == 2)
        }

        let serverError = LicenseAPIError(code: "SEAT_LIMIT_REACHED", message: "No seats left", field: nil)
        // A server-supplied message is passed straight through, not looked up
        // in the bundle — it's already user-facing text from the server, and
        // doesn't depend on the resolved language at all.
        #expect(LicenseManagerError.server(serverError).localizedDescription == "No seats left")
    }

    @Test func licenseManagerErrorProvidesALocalizedDescriptionInFrench() {
        withLanguageOverride("fr") {
            #expect(LicenseManagerError.licenseKeyRequired.localizedDescription == "Saisissez une clé de licence.")

            let storageMessage = LicenseManagerError.storage(statusCode: -25300, appName: "TestApp").localizedDescription
            #expect(storageMessage.contains("-25300"))
            #expect(storageMessage.components(separatedBy: "TestApp").count - 1 == 2)
        }
    }

    @Test func licenseManagerErrorProvidesALocalizedDescriptionInSpanish() {
        withLanguageOverride("es") {
            #expect(LicenseManagerError.licenseKeyRequired.localizedDescription == "Introduce una clave de licencia.")

            let storageMessage = LicenseManagerError.storage(statusCode: -25300, appName: "TestApp").localizedDescription
            #expect(storageMessage.contains("-25300"))
            #expect(storageMessage.components(separatedBy: "TestApp").count - 1 == 2)
        }
    }

    @Test func licenseInvalidReasonProvidesALocalizedDescriptionInEnglish() {
        withLanguageOverride("en") {
            #expect(LicenseInvalidReason.deviceDeactivated.localizedDescription == "This Mac has been deactivated.")
        }
    }

    @Test func licenseInvalidReasonProvidesALocalizedDescriptionInFrench() {
        withLanguageOverride("fr") {
            #expect(LicenseInvalidReason.deviceDeactivated.localizedDescription == "Ce Mac a été désactivé.")
        }
    }

    @Test func licenseInvalidReasonProvidesALocalizedDescriptionInSpanish() {
        withLanguageOverride("es") {
            #expect(LicenseInvalidReason.deviceDeactivated.localizedDescription == "Este Mac ha sido desactivado.")
        }
    }

    @Test func licenseAccessStateProvidesALocalizedTitleAndSubtitleInEnglish() {
        withLanguageOverride("en") {
            #expect(LicenseAccessState.licensed.localizedTitle == "License active")
            #expect(
                LicenseAccessState.licensed.localizedSubtitle(appName: "TestApp", trialDaysRemaining: nil)
                    == "This Mac has an active TestApp license."
            )

            // No cached days-remaining yet (first launch, still verifying)
            // falls back to a generic message rather than a broken "nil
            // days" string.
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: nil)
                    == "Your trial is active on this Mac."
            )
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 1)
                    == "1 day remaining"
            )
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 3)
                    == "3 days remaining"
            )

            #expect(
                LicenseAccessState.invalid(.deviceDeactivated).localizedSubtitle(appName: "TestApp", trialDaysRemaining: nil)
                    == "This Mac has been deactivated."
            )
        }
    }

    @Test func licenseAccessStateProvidesALocalizedTitleAndSubtitleInFrench() {
        withLanguageOverride("fr") {
            #expect(LicenseAccessState.licensed.localizedTitle == "Licence active")
            #expect(
                LicenseAccessState.licensed.localizedSubtitle(appName: "TestApp", trialDaysRemaining: nil)
                    == "Ce Mac possède une licence TestApp active."
            )
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 1)
                    == "1 jour restant"
            )
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 3)
                    == "3 jours restants"
            )
        }
    }

    @Test func licenseAccessStateProvidesALocalizedTitleAndSubtitleInSpanish() {
        withLanguageOverride("es") {
            #expect(LicenseAccessState.licensed.localizedTitle == "Licencia activa")
            #expect(
                LicenseAccessState.licensed.localizedSubtitle(appName: "TestApp", trialDaysRemaining: nil)
                    == "Este Mac tiene una licencia TestApp activa."
            )
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 1)
                    == "1 día restante"
            )
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 3)
                    == "3 días restantes"
            )
        }
    }

    @Test func licenseAccessStateProvidesALocalizedTitleAndSubtitleInGerman() {
        withLanguageOverride("de") {
            #expect(LicenseAccessState.licensed.localizedTitle == "Lizenz aktiv")
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 3)
                    == "Noch 3 Tage"
            )
        }
    }

    @Test func licenseAccessStateProvidesALocalizedTitleAndSubtitleInItalian() {
        withLanguageOverride("it") {
            #expect(LicenseAccessState.licensed.localizedTitle == "Licenza attiva")
            #expect(
                LicenseAccessState.trial.localizedSubtitle(appName: "TestApp", trialDaysRemaining: 3)
                    == "3 giorni rimanenti"
            )
        }
    }
}

/// Pins the package's resolved language for the duration of `body`. Scoped
/// via a task-local, so this can never leak into another test running
/// concurrently in a different task.
private func withLanguageOverride(_ language: String, _ body: () -> Void) {
    PackageLocalization.$languageOverrideForTesting.withValue(language, operation: body)
}
