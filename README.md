# BudMeter

A small macOS menu bar app that runs in the background, notices when you connect earbuds, logs their battery and works out how worn the battery is.

For each pair it shows:

- **Battery health**: how long a full charge lasts while listening, compared with the manufacturer's rating. 80% or more is "Healthy", 60 to 80% is "Worn", and under 60% means "Replace soon".
- **Runtime per activity**: how long a full charge lasts while listening, on calls, while idle, and with your real mix of all three.
- **Idle drain**: how much battery the earbuds lose while connected with nothing playing, and what share of all battery use that idle time accounts for. For Galaxy Buds this is split into "in your ears" and "out of your ears, still connected".
- **Trend**: full-charge runtime week by week, and how many minutes of runtime you lose per month.
- **Left vs right**: whether one bud drains faster than the other (AirPods, Beats and Galaxy Buds).
- **Time left right now**: based on the current battery level and what you're doing.
- **Battery history**: a chart of the battery level (the lower bud, since it runs out first) with a row underneath showing when you were listening, on a call or idle, plus connected time per activity.
- **A picture of each model**, for 33 families from AirPods and Galaxy Buds to Sony, Nothing, Bose and more.

## Install

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
scripts/install.sh
```

This builds a release copy, puts it in `/Applications` and starts it. Click the earbuds icon in the menu bar, then the gear button, and turn on **Open at login**. To open the dashboard, open BudMeter again from Finder or Spotlight, or use **Open Dashboard** in the menu.

BudMeter shows in the Dock only while the dashboard is open. Closing the dashboard, ⌘Q and Quit in the Dock all just close the window; BudMeter keeps recording in the menu bar. To quit it completely, use the power button in the menu bar popover.

## How it works

Every 30 seconds BudMeter checks paired headsets:

- **Battery** comes from the same IOBluetooth properties the macOS Bluetooth menu uses: each bud and the case for AirPods and Beats, and one level for the pair from other headsets that report battery over the hands-free profile (Galaxy Buds, Pixel Buds, Bose, Sony and others).
- **Galaxy Buds** also expose Samsung's own Bluetooth channel. BudMeter listens on it, without writing anything, to get each bud's battery at 1% steps, the case battery and where each bud is (in an ear, out, or in the case). You can turn this off in Settings.
- **Activity** comes from CoreAudio. An open microphone means a call, an open output stream means listening, and anything else is idle.

Time in the charging case doesn't count: for Galaxy Buds a bud in the case stops only that bud's measurement, and connected time stops when both are in. For other earbuds a rising battery level marks charging. A reading is saved when anything changes, and every 2 minutes otherwise, to `~/Library/Application Support/BudMeter/budmeter.sqlite`.

**Drain is measured between battery steps.** Many headsets report battery in 10% steps. Measuring from an arbitrary moment would mix in an unknown part of a step, so within each continuous discharge BudMeter only counts the time from the first observed step down to the last. That avoids a bias from the step size. When a step spans several activities, its drop is shared between them in proportion to how fast each one usually drains. With 10% steps a single estimate is still coarse, so the numbers settle as more sessions are recorded. Estimates based on little data are shown dimmed; hover over a number to see how much data it's based on. Charging (level going up), disconnects, app restarts, gaps over 6 minutes (for example the Mac sleeping) and sudden jumps end a discharge run and are left out.

A rate is only shown after at least 30 minutes and a 5% drop in that activity. The health number uses the last 30 days when there is enough listening data, so it reflects the battery as it is now.

### Limits

- BudMeter only sees time connected to this Mac. Use on your phone isn't counted, and neither is drain while the buds are also streaming from another device (multipoint) and the Mac sees them as idle.
- Some apps keep the audio output open even when silent. That time counts as listening, which is also how the earbuds experience it.
- Listening drain depends on volume and noise cancelling. Compare trends for the same pair rather than reading too much into one week.
- The Galaxy Buds channel is not always available. If the phone's Galaxy Wearable app is holding it, BudMeter falls back to one battery level for the pair and tries again every 5 minutes. Putting the buds back in the case and taking them out again usually frees it.
- Rated hours come from a built-in table (noise cancelling on, where it exists). If your model is missing or the number is wrong, click **Rated** next to the health number to change it.

## Development

```sh
cd Core && swift test          # analysis and storage tests
xcodegen generate              # create BudMeter.xcodeproj
xcodebuild -project BudMeter.xcodeproj -scheme BudMeter -derivedDataPath build build
```

To try the dashboard with six weeks of made-up history:

```sh
scripts/demo-data.py /tmp/budmeter-demo.sqlite
open --env BUDMETER_DB=/tmp/budmeter-demo.sqlite build/Build/Products/Debug/BudMeter.app
```

Add `--env BUDMETER_APPEARANCE=dark` (or `light`) to check one appearance without changing the system setting.

Layout:

- `design/icon-artwork.png`: source art for the app icon; `swift scripts/make-icon.swift` turns it into the icon set.
- `design/devices/`: a picture per earbud family (33 of them: AirPods and Beats, Galaxy Buds, Pixel Buds, Sony, Nothing and CMF, Bose, Jabra, Sennheiser, OnePlus, Soundcore, Shokz, Huawei, plus generic earbuds and headphones); `swift scripts/make-device-images.swift` trims them into the asset catalog. `EarbudModel.swift` maps device names and Apple product IDs to a family.
- `Core/`: Swift package with the models, SQLite store and all analysis (`Analysis.swift`, `Report.swift`), plus tests.
- `App/`: the menu bar app. `Bluetooth.swift` (IOBluetooth and CoreAudio), `GalaxyBuds.swift` (Samsung channel), `Monitor.swift` (polling and recording), `Views/`.
