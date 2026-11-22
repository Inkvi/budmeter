import Foundation

// `BudMeter --battery` prints the battery levels macOS reports right now and exits (see
// Bluetooth.freshLevels). Anything else starts the app.
if CommandLine.arguments.dropFirst().first == "--battery" {
    Bluetooth.printLevels()
    exit(0)
}
BudMeterApp.main()
