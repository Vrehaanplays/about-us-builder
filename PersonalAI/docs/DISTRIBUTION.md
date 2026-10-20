# Getting the app onto your iPhone 17 without a Mac

Everything below is designed for a Linux-only workflow. The build happens on GitHub's hosted macOS runners; you only ever download a file.

**Honest status:** the CI build and the signing lane are described here as designed. A line is marked ✅ only if it has been observed to work (see `STATUS.md` for what actually ran). I have no access to your Apple account, so the signed/TestFlight lane has **never been run**.

## What Apple requires (no way around it)

| Goal | Apple account | Cost | Limits |
|---|---|---|---|
| Install on your own iPhone for testing, from a file | Free Apple ID | $0 | Signature expires every **7 days** (re-install weekly), max **3** sideloaded apps, **no** "Increased Memory Limit" entitlement (see below), no TestFlight |
| Install via TestFlight | Apple Developer Program | **$99 / year** | Builds last 90 days; internal testers need no App Review; you need an App Store Connect record |
| Install a development build over USB/Wi‑Fi | Apple Developer Program | $99 / year | Needs a signing tool on your computer (Xcode on a Mac, or a Linux sideloader) |

The entitlement `com.apple.developer.kernel.increased-memory-limit` lets iOS give the app more of the 8 GB than the default cap. It is a paid-program capability. Without it a 4B-parameter model plus a long context may be killed by iOS earlier. The in-app **Models → Measure this iPhone** reports the real headroom (`os_proc_available_memory`), so you can see what your install actually gets rather than trusting a guess.

## Route A: free Apple ID, from Linux (fastest to try)

1. In GitHub → *Actions* → the latest **PersonalAI** run → download the artifact **personalai-ios**. It contains `PersonalAI-unsigned.ipa`.
2. On the iPhone: *Settings → Privacy & Security → Developer Mode → On* (reboots the phone).
3. On Linux, sign and install the IPA with a sideloading tool that supports Linux and a free Apple ID. Options that advertise Linux support (I have **not** tested any of them for this app): [Impactor](https://github.com/khcrysalis/Impactor) (MIT, Rust), AltServer‑Linux builds of [AltStore](https://github.com/altstoreio/AltStore), and [SideStore](https://github.com/SideStore/SideStore) (refreshes over Wi‑Fi without a computer after setup). Use an Apple ID you are comfortable giving to such tools; consider a dedicated one.
4. Re-sign every 7 days.

Unsigned builds have no `increased-memory-limit` entitlement, so expect a lower memory ceiling than Route B.

## Route B: paid program + TestFlight, uploaded straight from CI (best experience)

One-time setup (in a browser, no Mac):

1. Enrol in the Apple Developer Program (developer.apple.com/programs).
2. *Certificates, Identifiers & Profiles → Identifiers → +* → App ID with bundle id `com.vrehaanplays.personalai` (change it in `PersonalAI/App/project.yml` if you prefer your own). Enable **Increased Memory Limit**.
3. *App Store Connect → Apps → +* → create the app record (name, bundle id, SKU).
4. *App Store Connect → Users and Access → Integrations → App Store Connect API → Generate API key* with role **App Manager** (or Admin). Download the `.p8` once; note **Key ID** and **Issuer ID**.
5. In GitHub → *Settings → Secrets and variables → Actions* add:
   - `APPLE_TEAM_ID` (10 characters, from your membership page)
   - `ASC_KEY_ID`, `ASC_ISSUER_ID`
   - `ASC_KEY_P8_BASE64` — `base64 -w0 AuthKey_XXXX.p8`
6. GitHub → *Actions → PersonalAI → Run workflow* → tick **sign**. The `testflight` job archives with automatic signing (Xcode creates and manages the certificate and profile through the API key), adds the memory entitlement, and uploads to TestFlight.
7. Install the **TestFlight** app on the iPhone, accept the internal-tester invite from App Store Connect, install the build. New builds arrive as updates; nothing expires weekly.

Costs: $99/year for the program. GitHub Actions on this **public** repository uses free standard runners. On a private repository macOS minutes are metered (`docs/CI.md`).

## Things that can still go wrong (and are not yet verified)

- Automatic signing from the API key needs the key's role to be allowed to create certificates; if the job reports a provisioning error, use *Admin*.
- If you rename the bundle id you must also rename it on the App ID and App Store Connect record.
- A first TestFlight upload can sit in "Processing" for several minutes and may ask about export compliance; the app declares `ITSAppUsesNonExemptEncryption = NO` (it uses only OS-provided HTTPS).
