import Metal

@MainActor
extension MetalRenderer {
    static var commandQueue: MTLCommandQueue? {
        if let q = _queue { return q }
        guard let (device, _) = deviceAndLibrary() else { return nil }
        let q = device.makeCommandQueue()
        _queue = q
        return q
    }
    @MainActor private static var _queue: MTLCommandQueue?
}
