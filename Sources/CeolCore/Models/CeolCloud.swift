import Foundation

/// The one name both apps must agree on for iCloud to join them up.
///
/// A CloudKit container identifier is *not* derived from the bundle
/// identifier. Two apps share data only if both ask for the same container by
/// name — and if they don't, nothing fails: each syncs happily with itself and
/// the two libraries stay separate, which is the hardest kind of bug to
/// notice because everything appears to work.
///
/// It lives in CeolCore so there is one string, not two that have to be kept
/// identical by hand. Changing it after either app has shipped strands
/// everything already in the old container, so it does not change.
public enum CeolCloud {
    public static let container = "iCloud.com.glenachulish.fonn"
}
