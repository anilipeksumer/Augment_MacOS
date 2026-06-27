import ApplicationServices
import CoreFoundation
import Foundation

enum AXElementCoercion {
    static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func value(_ value: AnyObject?) -> AXValue? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    static func point(from value: AnyObject?) -> CGPoint? {
        guard let axValue = self.value(value) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(from value: AnyObject?) -> CGSize? {
        guard let axValue = self.value(value) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

}
