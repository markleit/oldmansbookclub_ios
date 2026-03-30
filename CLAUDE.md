# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

iOS book club app built with SwiftUI + MVVM. Early-stage scaffold — no persistence or networking yet, all data is hardcoded in-memory samples.

- **Deployment target:** iOS 16.0+
- **Bundle ID:** `com.example.oldmansbookclub` (placeholder — needs replacing before distribution)

## Build

Requires macOS with Xcode installed.

```bash
brew install xcodegen
xcodegen generate                    # regenerate .xcodeproj from project.yml
open OldMansBookClub.xcodeproj
```

CI builds via GitHub Actions (`.github/workflows/ci.yml`) on push to `main` and PRs — installs XcodeGen, generates project, builds for iOS simulator.

## Architecture

**MVVM with TabView navigation.**

- `App/OldMansBookClubApp.swift` — `@main` entry point
- `App/ContentView.swift` — root `TabView` (Clubs / Events / Profile tabs)
- `App/Models/Models.swift` — `Club`, `Book`, `Event`, `User` as `Codable` + `Identifiable` structs
- `App/ViewModels/` — `ObservableObject` classes with `@Published` properties; sample data is hardcoded in initializers
- `App/Views/` — SwiftUI views using `@StateObject` to own their ViewModels

Data flows one way: ViewModels hold state → Views observe via `@Published` → no persistence layer exists yet.

## Key gaps (next implementation steps per README)

1. Replace bundle ID and configure signing
2. Add Core Data model for persistence
3. Add networking layer for real data
