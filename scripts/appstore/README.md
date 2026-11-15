# App Store screenshots

Repeatable, from staged data: no real members, photos or book covers.

1. `python3 scripts/appstore/make_assets.py`: generates covers (public-domain titles), avatars and a page "photo".
2. Run the dev API locally: `cd API && AZURE_TOKEN_CREDENTIALS=dev ASPNETCORE_ENVIRONMENT=Development dotnet run --no-launch-profile --urls http://0.0.0.0:5235`.
   (`AZURE_TOKEN_CREDENTIALS=dev`: off Azure, DefaultAzureCredential's managed-identity probe otherwise fails blob signing.)
3. `python3 scripts/appstore/stage.py`: a fresh club with members, books and a Moby-Dick discussion (local API only).
4. `scripts/appstore/capture.sh <simulator-udid> <out-dir>`: runs `UITests/AppStoreScreenshots` (skipped unless
   staged), on an iPhone 17 Pro Max (6.9", 1320×2868) or iPad Pro 13" (M5) (2064×2752) simulator. **Restage before each
   capture**: a run reads the chat.
5. `python3 scripts/appstore/compose.py <raw-dir> <out-dir> iphone|ipad`: captions and frames.
6. Upload with `~/.appstoreconnect/ombc-release/screenshots.py`. **Do this before "Add for Review"**: Apple locks a
   version's screenshots while it's READY_FOR_REVIEW (409 STATE_ERROR).
