import CSystem
import Dispatch
import Glibc
import SystemPackage

extension FileDescriptor {
    static var currentWorkingDirectory: FileDescriptor { return FileDescriptor(rawValue: AT_FDCWD) }
}

func handleOpenCompletion(_ completion: IOCompletion) {
    if completion.result < 0 {
        print("Error opening file \(String(cString: strerror(-completion.result)))")
    }
    print("Opened file with result \(completion.result)")
}

func handleReadCompletion(_ completion: IOCompletion, buffer: IORingBuffer) {
    if completion.result < 0 {
        print("Error reading file \(String(cString: strerror(-completion.result)))")
    } else {
        buffer.unsafeBuffer.withMemoryRebound(to: UInt8.self) {
            print("Got \(String(decoding: $0, as: UTF8.self)) with completion \(completion)")
        }
    }
}

func handleCloseCompletion(_ completion: IOCompletion) {
    print(
        "Closed file with result \(String(cString: strerror(-completion.result))), completion \(completion)"
    )
    CSystem._exit(0)
}

@main
struct MainApp {

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
                        in: .currentWorkingDirectory,
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
