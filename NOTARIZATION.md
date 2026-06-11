# Signing & Notarization

Ship Cookie Monster **signed + notarized** so users never see the Gatekeeper
"Apple could not verify…" warning. This requires the **paid Apple Developer
Program** and a **Developer ID Application** certificate.

Your Team ID: **`29T68WB833`**.

## One-time setup

### 1. Create a Developer ID Application certificate
You currently have an *Apple Development* cert, which can't sign for distribution.
Create the distribution one in **Xcode → Settings… → Accounts** → select your
Apple ID → your team → **Manage Certificates… → ＋ → Developer ID Application**.
It installs into your login keychain. Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# → "Developer ID Application: David Pflugpeil (29T68WB833)"
```
(Or create it at <https://developer.apple.com/account/resources/certificates>.)

### 2. Create an app-specific password
At <https://appleid.apple.com> → **Sign-In & Security → App-Specific Passwords →
＋**. Name it `notarytool` and copy the `xxxx-xxxx-xxxx-xxxx` value.

### 3. Store notarization credentials locally
```bash
xcrun notarytool store-credentials "CookieMonster" \
  --apple-id "you@example.com" \
  --team-id  "29T68WB833" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

## Build a notarized release locally
```bash
export SIGN_IDENTITY="Developer ID Application: David Pflugpeil (29T68WB833)"
export NOTARY_PROFILE="CookieMonster"
./release.sh
```
This compiles, signs (hardened runtime), notarizes, staples, and writes a
notarized `dist/Cookie-Monster-<version>.dmg` + `.zip`. The closing `spctl`
check should print **accepted … source=Notarized Developer ID**.

## Automated releases (GitHub Actions)
The **Release** workflow signs + notarizes automatically on a `vX.Y.Z` tag push —
once you add these repository secrets (**Settings → Secrets and variables →
Actions → New repository secret**):

| Secret | Value |
|--------|-------|
| `MACOS_CERT_P12_BASE64` | base64 of your exported Developer ID cert (`.p12`) |
| `MACOS_CERT_PASSWORD`   | the password you set when exporting the `.p12` |
| `MACOS_SIGN_IDENTITY`   | `Developer ID Application: David Pflugpeil (29T68WB833)` |
| `APPLE_ID`              | your Apple ID email |
| `APPLE_TEAM_ID`         | `29T68WB833` |
| `APPLE_APP_PASSWORD`    | the app-specific password |

Export the `.p12` from **Keychain Access**: find *Developer ID Application…* under
**login → My Certificates**, right-click → **Export…**, save as `.p12` with a
password, then:
```bash
base64 -i developer-id.p12 | pbcopy   # → paste into MACOS_CERT_P12_BASE64
```

If the signing secrets are absent, the workflow falls back to an **unsigned**
build, so tagging never hard-fails.

## After your first notarized release
Once releases are notarized, simplify the "First launch" Gatekeeper step in
[`README.md`](README.md) — notarized downloads open with a normal double-click.
