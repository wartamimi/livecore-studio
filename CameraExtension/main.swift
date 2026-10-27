import CoreMediaIO
import Foundation

// Entry point of the LiveCore Virtual Camera system extension (see CameraProvider.swift).
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
