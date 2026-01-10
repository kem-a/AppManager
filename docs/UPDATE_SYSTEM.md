# AppManager Update System Architecture

## Overview

The AppManager update system provides automatic and manual update checking for installed AppImages. It supports multiple update sources and runs both interactively and in the background.

---

## File Structure

```
src/core/
├── updater.vala              # Core update logic
├── update_sources.vala       # Update source type definitions
├── background_update_service.vala  # Background/autostart updates
├── installation_record.vala  # App metadata storage (incl. update tracking fields)
├── installer.vala            # Install/upgrade operations
└── version_utils.vala        # Version comparison utilities

src/windows/
├── main_window.vala          # UI: batch update check, update all
└── details_window.vala       # UI: single app update check/install

src/
└── application.vala          # CLI entry point for --background-update
```

---

## Class Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│                        UpdateSource                              │
│                      (abstract base)                             │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  DirectUrlSource │  │  GithubSource   │  │  GitlabSource   │
│                  │  │ (ReleaseSource) │  │ (ReleaseSource) │
│  - url           │  │  - owner        │  │  - host         │
│                  │  │  - repo         │  │  - project_path │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

---

## Data Types

### Enums

| Enum | Values | Description |
|------|--------|-------------|
| `UpdateStatus` | `UPDATED`, `SKIPPED`, `FAILED` | Result of an update operation |
| `UpdateSkipReason` | `NO_UPDATE_URL`, `UNSUPPORTED_SOURCE`, `ALREADY_CURRENT`, `MISSING_ASSET`, `API_UNAVAILABLE`, `NO_TRACKING_HEADERS` | Why an update was skipped |

### Result Classes

| Class | Purpose |
|-------|---------|
| `UpdateResult` | Full update operation result (record, status, message, new_version) |
| `UpdateProbeResult` | Check-only result (record, has_update, available_version) |
| `UpdateCheckInfo` | UI-friendly check result (has_update, latest_version, current_version) |

---

## Update Source Resolution

The `resolve_update_source()` method in `Updater` determines which update strategy to use:

```
URL Input
    │
    ▼
┌───────────────────────────────┐
│  normalize_update_url()       │  Truncates full download URLs to project base
│  e.g., github.com/user/repo/  │
│  releases/download/v1/App     │
│  → github.com/user/repo       │
└───────────────────────────────┘
    │
    ▼
┌───────────────────────────────┐
│  Try GithubSource.parse()     │  host == "github.com"?
└───────────────────────────────┘
    │ No
    ▼
┌───────────────────────────────┐
│  Try GitlabSource.parse()     │  host contains "gitlab"?
└───────────────────────────────┘
    │ No
    ▼
┌───────────────────────────────┐
│  DirectUrlSource.parse()      │  Any http/https URL
└───────────────────────────────┘
```

---

## Update Strategies

### 1. GitHub Releases

**Source Detection:** `host == "github.com"`

**API Endpoint:** `https://api.github.com/repos/{owner}/{repo}/releases?per_page=10`

**Flow:**
```
fetch_github_release()
    │
    ├─► GET releases API (JSON)
    │
    ├─► For each release:
    │       parse_github_release() → ReleaseInfo
    │       select_appimage_asset() → Find .AppImage matching system arch
    │
    └─► Return first release with matching AppImage asset
```

**Version Comparison:**
1. Compare `release.version` vs `record.version` using semantic versioning
2. Fallback: Compare `release.tag_name` vs `record.last_release_tag`

---

### 2. GitLab Releases

**Source Detection:** `host.contains("gitlab")`

**API Endpoint:** `https://{host}/api/v4/projects/{url-encoded-path}/releases?per_page=10`

**Flow:**
```
fetch_gitlab_release()
    │
    ├─► GET releases API (JSON)
    │
    ├─► For each release:
    │       parse_gitlab_release() → ReleaseInfo
    │       - Assets from: release.assets.links[]
    │       - URLs: direct_asset_url or url field
    │
    └─► Return first release with matching AppImage asset
```

**Version Comparison:** Same as GitHub

---

### 3. Direct URL

**Source Detection:** Any `http://` or `https://` URL not matching GitHub/GitLab

**Change Detection:** HTTP `Last-Modified` + `Content-Length` headers

```
build_direct_fingerprint(message)
    │
    ├─► If Last-Modified exists:
    │       return "{Last-Modified}|{Content-Length}"
    │       e.g., "Wed, 10 Dec 2025 12:39:35 GMT|336828920"
    │
    └─► Fallback: return "size:{Content-Length}"
```

**Why not ETag?**
Mirror-based CDNs (KDE, GIMP, etc.) generate different ETags per mirror server. `Last-Modified` and `Content-Length` are consistent across all mirrors.

**Storage:** `InstallationRecord.last_modified` and `InstallationRecord.content_length`

---

## Architecture Matching

The `select_appimage_asset()` function finds the right AppImage for the system:

```
System Arch     Patterns Matched
───────────     ────────────────
x86_64          x86_64, x86-64, amd64, x64
aarch64         aarch64, arm64
armv7l          armv7l, armhf, arm32
i686/i386       i686, i386, x86, ia32
```

**Priority:**
1. Asset with explicit architecture match in filename
2. Asset with no architecture in filename (assumes x86_64)
3. Single AppImage (if only one exists)

---

## Function Dependency Graph

### Updater Class - Public API

```
┌────────────────────────────────────────────────────────────────────┐
│                         PUBLIC METHODS                              │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  probe_updates()  ──────► probe_updates_parallel() ──► probe_record()
│  probe_single()   ──────────────────────────────────► probe_record()
│                                                                     │
│  update_all()     ──────► update_records_parallel() ─► update_record()
│  update_single()  ──────────────────────────────────► update_record()
│                                                                     │
│  check_for_update_async() ──────────────────────────► check_for_update()
│                                                                     │
│  get_update_url() ─────────────────────────────────► read_update_url()
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### Internal Flow

```
probe_record() / update_record() / check_for_update()
    │
    ├─► read_update_url(record)
    │       └─► record.get_effective_update_link() or desktop file
    │
    ├─► resolve_update_source(url, version)
    │       ├─► normalize_update_url()
    │       ├─► GithubSource.parse()
    │       ├─► GitlabSource.parse()
    │       └─► DirectUrlSource.parse()
    │
    └─► Branch by source type:
            │
            ├─► DirectUrlSource:
            │       probe_direct() / update_direct() / check_direct_update()
            │           ├─► send_head(url)
            │           ├─► build_direct_fingerprint()
            │           ├─► get_stored_fingerprint()
            │           └─► store_fingerprint() [on update]
            │
            └─► ReleaseSource (GitHub/GitLab):
                    fetch_latest_release()
                        ├─► fetch_github_release()
                        │       └─► parse_github_release()
                        └─► fetch_gitlab_release()
                                └─► parse_gitlab_release()
                    │
                    select_appimage_asset()
                        ├─► matches_system_arch()
                        └─► has_any_arch_in_name()
                    │
                    compare_versions() via VersionUtils
                    │
                    download_file() [on update]
                    │
                    installer.upgrade()
```

---

## Update Triggers

### 1. Manual Check (Main Window)

**Trigger:** User clicks "Check for Updates" button or presses `Ctrl+U`

**File:** `src/windows/main_window.vala`

```
on_check_updates_accel()
    │
    └─► start_update_check() [async]
            │
            ├─► updater.probe_updates()  ─► Returns UpdateProbeResult[]
            │
            └─► UI: Show update badges on app rows
```

### 2. Manual Check (Details Window)

**Trigger:** User opens app details, or clicks "Check" button

**File:** `src/windows/details_window.vala`

```
check_update_requested signal
    │
    └─► main_window.start_single_probe() [async]
            │
            ├─► updater.check_for_update_async()
            │
            └─► details_window.set_update_available(result.has_update)
```

### 3. Manual Update (Single App)

**Trigger:** User clicks "Update" button in details window

```
update_requested signal
    │
    └─► main_window.trigger_single_update() [async]
            │
            ├─► updater.update_single()
            │
            └─► Refresh UI
```

### 4. Update All

**Trigger:** User clicks "Update All" in main window

```
start_update_install() [async]
    │
    ├─► updater.update_all()  ─► Returns UpdateResult[]
    │
    └─► Show results dialog
```

### 5. Background Update

**Trigger:** System autostart (`~/.config/autostart/com.github.AppManager.desktop`)

**Command:** `app-manager --background-update`

**File:** `src/application.vala`, `src/core/background_update_service.vala`

```
main() → Application.command_line()
    │
    └─► opt_background_update = true
            │
            └─► run_background_update()
                    │
                    └─► bg_update_service.perform_background_check() [async]
                            │
                            ├─► Check: settings.auto-check-updates enabled?
                            ├─► Check: should_check_now()? (interval elapsed?)
                            │
                            └─► updater.update_all()
                                    │
                                    └─► Log results to ~/.local/share/app-manager/updates.log
```

**Interval Check:**
```vala
should_check_now() {
    last_check = settings.get_int64("last-update-check")
    interval = settings.get_int("update-check-interval")  // seconds
    return (now - last_check) >= interval
}
```

---

## Signals (Updater)

```vala
signal record_checking(InstallationRecord record);    // Started checking
signal record_downloading(InstallationRecord record); // Downloading new version
signal record_succeeded(InstallationRecord record);   // Update completed
signal record_failed(InstallationRecord record, string reason);
signal record_skipped(InstallationRecord record, UpdateSkipReason reason);
```

Used by UI to show progress feedback.

---

## Data Persistence

### InstallationRecord Fields (update-related)

| Field | Type | Purpose |
|-------|------|---------|
| `version` | `string?` | App version from `.desktop` `X-AppImage-Version` |
| `last_modified` | `string?` | HTTP Last-Modified header (direct URL tracking) |
| `content_length` | `int64` | HTTP Content-Length (direct URL tracking) |
| `last_release_tag` | `string?` | GitHub/GitLab release tag (version-less apps) |
| `original_update_link` | `string?` | Update URL from AppImage's `.desktop` |
| `custom_update_link` | `string?` | User-overridden update URL |

### Update URL Resolution

```vala
get_effective_update_link() {
    if (custom_update_link == CLEARED_VALUE) return null;
    return custom_update_link ?? original_update_link;
}
```

---

## Logging

Update events are logged to: `~/.local/share/app-manager/updates.log`

Format: `{timestamp} [{STATUS}] {app_name}: {detail}`

Example:
```
2026-01-10T09:57:21+0200 [SKIP] Krita: fingerprint unchanged
2026-01-10T10:15:03+0200 [UPDATED] GIMP: direct url fingerprint=Wed, 05 Oct 2025 19:42:41 GMT|165247480
2026-01-10T10:15:05+0200 [FAILED] SomeApp: Download failed (404)
```

---

## Parallelization

Batch operations use a `ThreadPool` with `MAX_PARALLEL_JOBS = 5`:

```vala
probe_updates_parallel() / update_records_parallel()
    │
    └─► ThreadPool<RecordTask>
            ├─► Task 1: probe_record(records[0])
            ├─► Task 2: probe_record(records[1])
            ├─► Task 3: probe_record(records[2])
            ├─► Task 4: probe_record(records[3])
            └─► Task 5: probe_record(records[4])
            ... (remaining queued)
```

---

## Error Handling

| Error Condition | Result |
|-----------------|--------|
| No update URL configured | `SKIPPED` with `NO_UPDATE_URL` |
| URL doesn't match any source | `SKIPPED` with `UNSUPPORTED_SOURCE` |
| API request fails | `SKIPPED` with `API_UNAVAILABLE` |
| No AppImage for architecture | `SKIPPED` with `MISSING_ASSET` |
| No tracking headers (direct) | `SKIPPED` with `NO_TRACKING_HEADERS` |
| Download/install error | `FAILED` with error message |
| Already up to date | `SKIPPED` with `ALREADY_CURRENT` |

---

## Sequence Diagrams

### Manual Update Check (Main Window)

```
┌────────┐     ┌────────────┐     ┌─────────┐     ┌──────────┐
│  User  │     │ MainWindow │     │ Updater │     │ HTTP/API │
└───┬────┘     └─────┬──────┘     └────┬────┘     └────┬─────┘
    │                │                  │               │
    │ Click "Check"  │                  │               │
    │───────────────>│                  │               │
    │                │ probe_updates()  │               │
    │                │─────────────────>│               │
    │                │                  │ HEAD/GET      │
    │                │                  │──────────────>│
    │                │                  │    Response   │
    │                │                  │<──────────────│
    │                │ UpdateProbeResult[]              │
    │                │<─────────────────│               │
    │ Show badges    │                  │               │
    │<───────────────│                  │               │
```

### Background Update

```
┌──────────┐     ┌─────────────┐     ┌───────────────────────┐     ┌─────────┐
│ Autostart│     │ Application │     │ BackgroundUpdateService│     │ Updater │
└────┬─────┘     └──────┬──────┘     └───────────┬───────────┘     └────┬────┘
     │                  │                        │                      │
     │ --background-update                       │                      │
     │─────────────────>│                        │                      │
     │                  │ perform_background_check()                    │
     │                  │───────────────────────>│                      │
     │                  │                        │ should_check_now()?  │
     │                  │                        │──────┐               │
     │                  │                        │<─────┘ Yes           │
     │                  │                        │ update_all()         │
     │                  │                        │─────────────────────>│
     │                  │                        │                      │ ... updates ...
     │                  │                        │  UpdateResult[]      │
     │                  │                        │<─────────────────────│
     │                  │                        │ Log results          │
     │                  │      Exit              │                      │
     │                  │<───────────────────────│                      │
```
