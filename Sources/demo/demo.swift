import CSystem
import Dispatch
import Glibc
import SystemPackage

@main
struct MainApp {
    static func handleOpenCompletion(_ completion: IOCompletion) {
        if completion.result < 0 {
            print("Error opening file \(String(cString: strerror(-completion.result)))")
        }
        print("Opened file with result \(completion.result)")
    }

    static func handleReadCompletion(_ completion: IOCompletion, ring: borrowing IORing) {
        if completion.result < 0 {
            print("Error reading file \(String(cString: strerror(-completion.result)))")
        } else {
            if let idx = completion.bufferIndex {
                print("Got buffer \(ring.registeredBuffers[idx].unsafeBuffer) with completion \(completion)")
            } else {
                print("No buffer index for completion \(completion)")
            }
        }
    }

    static func handleCloseCompletion(_ completion: IOCompletion) {
        print("Closed file with result \(completion.result)")
        CSystem._exit(0)
    }

    static func main() async throws {
        print("Running...")
        let cwdbuf = getcwd(nil, 0)!
        print("cwd is \(String(cString: cwdbuf))")
        var ring = try IORing(queueDepth: 32)
        do {
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
                            handleReadCompletion(completion, ring: ring)
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
                    in: FileDescriptor(rawValue: AT_FDCWD),
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
            sleep(1000)
        } catch (let openErr) {
            print(openErr)
        }
    }
}
