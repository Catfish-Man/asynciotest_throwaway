import CSystem
import Dispatch
import SystemPackage

@main
struct MainApp {
    static func handleOpenCompletion(_ completion: IOCompletion) {
        print("Opened file with result \(completion.result)")
    }

    static func handleReadCompletion(_ completion: IOCompletion, buffer: IORingBuffer) {
        print("Got buffer \(buffer.unsafeBuffer)")
    }

    static func handleCloseCompletion(_ completion: IOCompletion) {
        print("Closed file with result \(completion.result)")
    }

    static func main() async throws {
        var ring = try IORing(queueDepth: 32)
        let parent = try FileDescriptor.open("/home/david/demo", .readOnly)
        let file = ring.registerFileSlots(count: 1).first!
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 65535, alignment: 0)
        let buffer = ring.registerBuffers(buf).first!
        let efd = eventfd(0, Int32(EFD_NONBLOCK))
        try ring.registerEventFD(FileDescriptor(rawValue: efd))
        let readSrc = DispatchSource.makeReadSource(fileDescriptor: efd)
        var completedOperationCount = 0

        readSrc.setEventHandler(
            handler: DispatchWorkItem {
                while let completion = ring.tryConsumeCompletion() {
                    switch completedOperationCount {
                    case 0: 
                        handleOpenCompletion(completion)
                    case 1: 
                        handleReadCompletion(completion, buffer: buffer)
                    case 2: 
                        handleCloseCompletion(completion)
                    default:
                        fatalError()
                    }

                    completedOperationCount += 1
                }
            })
        readSrc.activate()
        try ring.submit(
            linkedRequests:
                .opening(
                    "test.txt",
                    in: parent,
                    into: file,
                    mode: .readOnly
                ),
            .reading(
                file,
                into: buffer
            ),
            .closing(
                file
            )
        )
    }
}
