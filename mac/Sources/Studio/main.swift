import SwiftUI

if Stress.requested { MainActor.assumeIsolated { Stress.run() } } else { StudioApp.main() }
