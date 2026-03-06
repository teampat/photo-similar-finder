# Photo Similar Finder

A macOS app that groups similar photos and burst shots from your camera, making it easy to review duplicates, select the ones to remove, and free up storage space.

> 🇹🇭 [ภาษาไทย](README.th.md)

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Arch](https://img.shields.io/badge/arch-Apple%20Silicon-black)

![App Screenshot](app-screenshot.webp)

---

## Features

### Photo Grouping
- **Same filename** — Files sharing the same filename (e.g. `IMG_0001.JPG` + `IMG_0001.CR3`) are merged as one shot.
- **Visual similarity (Neural Engine)** — Uses Apple's Vision framework to compute AI feature prints and group visually similar photos, even with different filenames.

### Supported Formats

| Type | Extensions |
|------|-----------|
| JPEG | `.jpg`, `.jpeg` |
| Modern | `.heic`, `.heif`, `.webp` |
| Other | `.png`, `.tiff`, `.tif`, `.bmp`, `.gif` |
| Canon RAW | `.cr2`, `.cr3` |
| Nikon RAW | `.nef`, `.nrw` |
| Sony RAW | `.arw`, `.srf`, `.sr2` |
| Adobe DNG | `.dng` |
| Fujifilm | `.raf` |
| Olympus/OM | `.orf` |
| Panasonic | `.rw2`, `.rwl` |
| Pentax | `.pef`, `.ptx` |
| Phase One | `.iiq`, `.cap` |
| Others | `.3fr`, `.fff`, `.erf`, `.mef`, `.mos`, `.mrw`, `.rwz`, `.x3f`, `.srw` |

### Hardware Acceleration (Apple Silicon)

| Chip | Framework | Role |
|------|-----------|------|
| **Media Engine** | `QuickLookThumbnailing` | Decode thumbnails for all formats including RAW |
| **GPU — Metal** | `CoreImage` + `Metal` | Render full-resolution images via Metal pipeline |
| **Neural Engine** | `Vision` | Compute feature prints to measure visual similarity |

### UI & Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `←` / `→` | Navigate photos within a group |
| `↑` / `↓` | Previous / next group |
| `D` | Toggle mark/unmark photo for deletion |
| `Esc` | Close preview |

- Click a photo card to open full-screen preview
- The film strip at the bottom shows all files in the group — click to jump to that photo
- Photos marked for deletion show a 🗑 icon and red border
- Press **"Delete N photo(s)"** to move marked files to Trash (recoverable)

---

## Requirements

- **macOS 14 Sonoma** or later
- **Apple Silicon** (M1 / M2 / M3 / M4 or newer)
- Swift 5.9+ / Xcode 15+ or Command Line Tools

---

## Installation & Build

### Clone

```bash
git clone <repo-url>
cd photo-similar-finder-mac/PhotoSimilarFinder
```

### Build (Swift Package Manager)

```bash
# Debug build
./build.sh

# Release build
./build.sh release
```

### Build & Run in one step

```bash
./run.sh
```

### Build via Xcode

```bash
open PhotoSimilarFinder.xcodeproj
```

Then press `⌘R` to build and run.

> **Note:** On first run you may need to set a Development Team in Xcode  
> (Signing & Capabilities → Team) for the hardened runtime.

---

## Project Structure

```
PhotoSimilarFinder/
├── Package.swift                    # Swift Package Manager config
├── build.sh                         # Script: build only
├── run.sh                           # Script: build + run
├── PhotoSimilarFinder.xcodeproj/    # Xcode project
└── PhotoSimilarFinder/
    ├── PhotoSimilarFinderApp.swift  # App entry point (@main)
    ├── ContentView.swift            # Root UI: NavigationSplitView + sidebar
    ├── GroupGridView.swift          # Group photo grid (LazyVGrid)
    ├── PreviewView.swift            # Full preview + film strip
    ├── Models.swift                 # ImageFile, ImageGroup, ImageScanner
    ├── AppState.swift               # @MainActor ObservableObject: shared state
    ├── ImageProcessor.swift         # Hardware-accelerated: Metal / QL / Vision
    ├── Info.plist
    └── PhotoSimilarFinder.entitlements
```

### Architecture

```
AppState (ObservableObject, @MainActor)
    │
    ├─ scanWithVision() ──► ImageScanner
    │                         ├─ makeStemShots()            # Merge JPG+RAW pairs → one shot each
    │                         ├─ computeFeaturePrint()      # Vision Neural Engine (concurrent)
    │                         └─ clusterShotsBySimilarity() # O(n²) pairwise cosine + Union-Find
    │
    ├─ UI ──► ContentView
    │             ├─ SidebarView         (folder picker, stats, delete button)
    │             ├─ GroupGridView       (LazyVGrid of GroupCardView)
    │             └─ PreviewView (sheet) (full image + FilmStripView)
    │
    └─ Image Loading ──► ImageProcessor
                             ├─ loadThumbnail()       → QLThumbnailGenerator (Media Engine)
                             ├─ loadFullImage()       → CIImage → Metal GPU
                             └─ computeFeaturePrint() → Vision (Neural Engine)
```

---

## Configuration

### Adjust grouping thresholds

Edit in [Models.swift](PhotoSimilarFinder/Models.swift):

```swift
// Vision similarity: cosine similarity 0.0–1.0 (default: 0.92)
// Higher = must be more similar to be grouped together
static let visionSimilarityThreshold: Float = 0.92
```

---

## License

MIT
