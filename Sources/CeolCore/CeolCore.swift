import Foundation

/// Placeholder, so the target has a source file and the package builds before
/// anything has been moved into it. Step 1 of the plan is to confirm both apps
/// still build with CeolCore attached and empty — if that fails, it is the
/// package wiring at fault and not the refactor.
///
/// Delete this once Models.swift lands.
public enum CeolCore {
    public static let marker = "CeolCore attached"
}
