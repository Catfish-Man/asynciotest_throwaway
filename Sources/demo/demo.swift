import SystemPackage

@main
struct MainApp {
    static func main() async throws {
        var ring = try IORing(queueDepth: 32)
        let parent = try FileDescriptor.open("/home/david/demo", .readOnly)
        let file = ring.registerFileSlots(count: 1).first!
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 65535, alignment: 0)
        let buffer = ring.registerBuffers(buf).first!
        ring.prepare(
            linkedRequests:
                IORequest(
                    opening: "test.txt",
                    in: parent,
                    into: file,
                    mode: .readOnly
                ),
            IORequest(
                reading: file,
                into: buffer
            ),
            IORequest(closing: file)
        )
        try ring.submitRequests()

    }
}
