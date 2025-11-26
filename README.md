# OldMansBookClub (scaffold)

This repository contains a minimal scaffold for an iOS app called `OldMansBookClub`.

What I created
- `project.yml` — XcodeGen project specification (run `xcodegen` to generate `.xcodeproj`).
- `App/OldMansBookClubApp.swift` and `App/ContentView.swift` — minimal SwiftUI app skeleton.
- `.github/workflows/ci.yml` — GitHub Actions workflow that generates the Xcode project and builds for the iOS simulator on macOS runners.
- `.gitignore` — standard Xcode ignores.

Quickstart
1. Install Xcode and command-line tools.
2. (Optional) Install `xcodegen`:

```powershell
brew install xcodegen
```

3. Generate the Xcode project (from repo root):

```powershell
xcodegen generate
```

4. Open the generated project:

```powershell
open OldMansBookClub.xcodeproj
```

5. Select a simulator and run the app in Xcode.

Notes
- The `project.yml` uses placeholder bundle id `com.example.oldmansbookclub`. Replace it with your App ID and Apple Team settings in `project.yml` or in Xcode after generating the project.
- To enable CI/TestFlight and automated signing, you will need an Apple Developer Team ID and to configure code signing secrets.

Next steps I can do after you confirm:
- Replace the placeholder bundle id & Apple Team ID and set up automatic code signing (Fastlane or GitHub Actions secrets).
- Add Core Data model, networking layer scaffold, and CI tests.
- Create a new remote repository and push the scaffold.

If you want me to continue scaffolding (commit, push, configure signing), say which steps to take and provide repo/access details.
