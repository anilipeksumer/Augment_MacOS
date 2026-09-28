import CoreFoundation
import Foundation
import IOKit

/// Dynamic access to Apple's undocumented `IOAVService` DDC/CI functions.
///
/// There is no public API for talking DDC/CI to an external display on
/// Apple Silicon — every open-source brightness/volume tool for these Macs
/// (MonitorControl, BetterDisplay, m1ddc) goes through these same four
/// private symbols. They're resolved with `dlopen`/`dlsym` against the
/// system framework that ships them rather than linked at build time, so a
/// macOS version that removed or renamed them degrades to "unsupported"
/// instead of refusing to launch the app.
enum DDCPrivateSymbols {
    typealias IOAVServiceCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    typealias IOAVServiceReadI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias IOAVServiceWriteI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let isAvailable: Bool = handle != nil && createWithService != nil && writeI2C != nil

    private static let handle: UnsafeMutableRawPointer? = {
        let paths = [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices",
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/Versions/A/CoreDisplay",
        ]
        for path in paths {
            if let h = dlopen(path, RTLD_NOW) { return h }
        }
        return nil
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static let create: IOAVServiceCreateFn? = symbol("IOAVServiceCreate", as: IOAVServiceCreateFn.self)
    static let createWithService: IOAVServiceCreateWithServiceFn? =
        symbol("IOAVServiceCreateWithService", as: IOAVServiceCreateWithServiceFn.self)
    static let readI2C: IOAVServiceReadI2CFn? = symbol("IOAVServiceReadI2C", as: IOAVServiceReadI2CFn.self)
    static let writeI2C: IOAVServiceWriteI2CFn? = symbol("IOAVServiceWriteI2C", as: IOAVServiceWriteI2CFn.self)
}
