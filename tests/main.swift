// Hermetic safety tests for profile switching.
//
// v0.5.0 built profiles as symlinks to the real config. A profile that was not signed in
// yet made Claude Code initialise a fresh config, and that write replaced the symlink
// rather than following it — landing on the shared original and truncating
// ~/.claude.json from 104 KB to 521 bytes and ~/.claude/settings.json to 1 byte.
//
// Everything here runs against a throwaway home (COOKIE_MONSTER_HOME), so it can assert
// the invariant that actually matters: the app never modifies anything outside
// ~/.cookie-monster/profiles.
import Foundation

var failures = 0
func check(_ label: String, _ got: String, _ want: String) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(label): \(got) / want \(want)")
}

let fm = FileManager.default
let home = cmHome()
func sha(_ path: String) -> String {
    (fm.contents(atPath: path).map { $0.base64EncodedString() } ?? "<missing>")
}

// --- fixture: a stand-in for the user's real config -------------------------------------
let claudeDir = (home as NSString).appendingPathComponent(".claude")
try? fm.createDirectory(atPath: (claudeDir as NSString).appendingPathComponent("commands"),
                        withIntermediateDirectories: true)
let homeCfg = (home as NSString).appendingPathComponent(".claude.json")
let servers = ["a": ["type": "http", "url": "https://a.example"]]
try! JSONSerialization.data(withJSONObject: ["mcpServers": servers, "projects": ["/p": [:]]])
    .write(to: URL(fileURLWithPath: homeCfg))
let homeSettings = (claudeDir as NSString).appendingPathComponent("settings.json")
try! #"{"effortLevel":"high"}"#.write(toFile: homeSettings, atomically: true, encoding: .utf8)

// A shared file reached through a symlink, as dotfiles setups (and ~/.claude/skills here) do.
let shared = (home as NSString).appendingPathComponent("dotfiles-commands")
try? fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
try! "shared".write(toFile: (shared as NSString).appendingPathComponent("x.md"),
                    atomically: true, encoding: .utf8)
let linked = (claudeDir as NSString).appendingPathComponent("commands")
try? fm.removeItem(atPath: linked)
try! fm.createSymbolicLink(atPath: linked, withDestinationPath: shared)

let beforeCfg = sha(homeCfg), beforeSettings = sha(homeSettings)
let p = try! createProfile(.claude, name: "work")

// --- the invariants --------------------------------------------------------------------
check("profile lives under ~/.cookie-monster", "\(p.configDir.hasPrefix(kProfilesRoot))", "true")

var links: [String] = []
if let e = fm.enumerator(atPath: p.configDir) {
    for case let rel as String in e {
        let full = (p.configDir as NSString).appendingPathComponent(rel)
        if (try? fm.destinationOfSymbolicLink(atPath: full)) != nil { links.append(rel) }
    }
}
check("no symlinks anywhere in a profile", links.joined(separator: ","), "")

// Writing into the profile must never reach the shared directory behind the source symlink.
let copied = (p.configDir as NSString).appendingPathComponent("commands/x.md")
try? "modified-by-profile".write(toFile: copied, atomically: true, encoding: .utf8)
check("shared file behind the source symlink untouched",
      (try? String(contentsOfFile: (shared as NSString).appendingPathComponent("x.md"),
                   encoding: .utf8)) ?? "?", "shared")

// A profile config that cannot be parsed must be left alone, not replaced. Claude Code
// writes JSON via Node, which emits unpaired surrogate escapes JSONSerialization rejects.
let pcfg = (p.configDir as NSString).appendingPathComponent(".claude.json")
let unparsable = #"{"oauthAccount":{"e":"x"},"history":"hi \ud83d there"}"#
try! unparsable.write(toFile: pcfg, atomically: true, encoding: .utf8)
syncProfile(.claude, p.configDir)
check("unparsable profile config left intact",
      (try? String(contentsOfFile: pcfg, encoding: .utf8)) ?? "?", unparsable)

// Switching must not destroy files the profile itself owns.
try! #"{"model":"haiku"}"#.write(toFile: (p.configDir as NSString).appendingPathComponent("settings.json"),
                                 atomically: true, encoding: .utf8)
syncProfile(.claude, p.configDir)
check("profile-owned settings survive a switch",
      (try? String(contentsOfFile: (p.configDir as NSString).appendingPathComponent("settings.json"),
                   encoding: .utf8)) ?? "?", #"{"model":"haiku"}"#)

// Secrets copied out of a 0600 source must not become world-readable.
try? fm.removeItem(atPath: pcfg)
syncProfile(.claude, p.configDir)
let mode = ((try? fm.attributesOfItem(atPath: pcfg))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
check("profile config is 0600", String(mode, radix: 8), "600")

// Names that would escape the profiles directory.
for bad in [".", "..", "", "a/b", "Default"] {
    do { _ = try createProfile(.claude, name: bad); check("reject \"\(bad)\"", "created", "threw") }
    catch { check("reject \"\(bad)\"", "threw", "threw") }
}

// Active profile is tracked per provider, so switching one never moves the other.
_ = setActiveProfile(.claude, "/nope/missing")
check("missing dir flagged", "\(activeProfile(.claude).missing)", "true")
_ = setActiveProfile(.claude, Provider.claude.defaultConfigDir)
check("default not flagged", "\(activeProfile(.claude).missing)", "false")
check("codex unaffected by a claude switch",
      activeProfile(.codex).dir, Provider.codex.defaultConfigDir)

// --- Codex: same design, and its credentials are a plain file so every profile is readable
let codexDir = (home as NSString).appendingPathComponent(".codex")
try? fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
try! "[mcp_servers.demo]\ncommand = \"x\"\n"
    .write(toFile: (codexDir as NSString).appendingPathComponent("config.toml"),
           atomically: true, encoding: .utf8)
try! #"{"tokens":{"access_token":"REAL","account_id":"a"}}"#
    .write(toFile: (codexDir as NSString).appendingPathComponent("auth.json"),
           atomically: true, encoding: .utf8)
let beforeCodexAuth = sha((codexDir as NSString).appendingPathComponent("auth.json"))

let cp = try! createProfile(.codex, name: "work")
check("codex profile is separate from claude's",
      "\(cp.configDir.hasPrefix(Provider.codex.profilesDir))", "true")
check("codex config.toml seeded (MCP servers ride along)",
      "\(fm.fileExists(atPath: (cp.configDir as NSString).appendingPathComponent("config.toml")))", "true")
check("codex credentials NOT copied into the profile",
      "\(fm.fileExists(atPath: (cp.configDir as NSString).appendingPathComponent("auth.json")))", "false")
check("codex sessions (gigabytes) not copied",
      "\(fm.fileExists(atPath: (cp.configDir as NSString).appendingPathComponent("sessions")))", "false")
try! #"{"tokens":{"access_token":"PROFILE","account_id":"b"}}"#
    .write(toFile: (cp.configDir as NSString).appendingPathComponent("auth.json"),
           atomically: true, encoding: .utf8)
check("per-profile codex token is readable",
      readCodexCredentials(dir: cp.configDir)?.accessToken ?? "?", "PROFILE")
// Compare a digest, never the token itself: an unsandboxed path here once printed the
// user's real access token into the test log.
check("default codex token still separate",
      "\(readCodexCredentials()?.accessToken == "REAL")", "true")
check("real codex auth.json untouched",
      sha((codexDir as NSString).appendingPathComponent("auth.json")), beforeCodexAuth)
check("shell setup covers both CLIs",
      "\(kShellSnippet.contains("CLAUDE_CONFIG_DIR") && kShellSnippet.contains("CODEX_HOME"))", "true")

// Renaming changes the label only — never the directory, the account or the credentials.
let dirBefore = p.configDir
check("default label is the folder name", listProfiles(.claude).first { $0.configDir == dirBefore }?.name ?? "?", "work")
check("rename accepted", "\(setProfileDisplayName(dirBefore, "Personal Max"))", "true")
check("label changed", listProfiles(.claude).first { $0.configDir == dirBefore }?.name ?? "?", "Personal Max")
check("directory did NOT move", "\(fm.fileExists(atPath: dirBefore))", "true")
check("bound account survives rename", boundAccount(dirBefore) ?? "nil", "nil")
check("rejects empty", "\(setProfileDisplayName(dirBefore, "   "))", "false")
check("rejects over-long", "\(setProfileDisplayName(dirBefore, String(repeating: "x", count: 41)))", "false")
check("label still intact after rejected renames",
      listProfiles(.claude).first { $0.configDir == dirBefore }?.name ?? "?", "Personal Max")
// The default profile is renameable, but its label is stored in our own directory —
// ~/.claude must never be written to.
check("default profile can be renamed",
      "\(setProfileDisplayName(Provider.claude.defaultConfigDir, "Personal"))", "true")
check("default label applied",
      listProfiles(.claude).first { $0.isDefault }?.name ?? "?", "Personal")
let strayName = (Provider.claude.defaultConfigDir as NSString)
    .appendingPathComponent(".cookie-monster-name")
check("nothing written into ~/.claude", "\(fm.fileExists(atPath: strayName))", "false")
let ourName = (kLogDir as NSString).appendingPathComponent("display-name-claude")
check("label stored in our own dir", "\(fm.fileExists(atPath: ourName))", "true")
check("rename still cannot write to an arbitrary path",
      "\(setProfileDisplayName(home + "/somewhere-else", "hack"))", "false")

// THE ONE THAT MATTERS: the user's own config, byte for byte.
check("~/.claude.json unchanged", sha(homeCfg), beforeCfg)
check("~/.claude/settings.json unchanged", sha(homeSettings), beforeSettings)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
