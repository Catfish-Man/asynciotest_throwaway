import Algorithms
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
   // CSystem._exit(0)
}

func FILE_COUNT() -> UInt32 { 16 }
func FILE_COUNT() -> Int { 16 }

@main
struct MainApp {

    static func main() async throws {
        print("Running...")
        let cwdbuf = getcwd(nil, 0)!
        print("cwd is \(String(cString: cwdbuf))")
        var ring = try IORing(queueDepth: FILE_COUNT() * 6)
        do {
            let files = ring.registerFileSlots(count: FILE_COUNT())
            let slab = UnsafeMutableRawBufferPointer.allocate(byteCount: 32 * FILE_COUNT(), alignment: 0)
                .evenlyChunked(in: FILE_COUNT())

            for (i, chunk) in zip(0 ..< FILE_COUNT(), slab) {
                chunk.storeBytes(of: i, as: Int.self)
            }
            let bPtrs = slab.lazy.map { 
                UnsafeMutableRawBufferPointer(rebasing: $0)
            }
            let buffers = ring.registerBuffers(bPtrs)
            let efd = eventfd(0, Int32(EFD_NONBLOCK))

            for i in 0 ..< FILE_COUNT() {
                ring.prepare(
                    linkedRequests:
                        .opening(
                            "test\(i).txt",
                            in: .currentWorkingDirectory,
                            into: files[i],
                            mode: .readWrite,
                            options: .create,
                            permissions: .ownerReadWrite
                        ),
                    .writing(
                        buffers[i],
                        into: files[i]
                    ),
                    .closing(
                        files[i]
                    )
                )
            }

          //  try ring.registerEventFD(FileDescriptor(rawValue: efd))
            let readSrc = DispatchSource.makeReadSource(fileDescriptor: efd)
            var completedOperationCount = 0

            readSrc.setEventHandler(
                handler: DispatchWorkItem {
                    while let completion = ring.tryConsumeCompletion() {
                        switch completedOperationCount {
                        case 0:
                            handleOpenCompletion(completion)
                        case 1:
                            handleReadCompletion(completion, buffer: buffers[0])
                        case 2:
                            handleCloseCompletion(completion)
                        default:
                            fatalError()
                        }

                        completedOperationCount += 1
                    }
                })
            readSrc.activate()

            for i in 0 ..< FILE_COUNT() {
                ring.prepare(
                    linkedRequests:
                        .opening(
                            "test.txt",
                            in: .currentWorkingDirectory,
                            into: files[i],
                            mode: .readOnly
                        ),
                    .reading(
                        files[i],
                        into: buffers[i]
                    ),
                    .closing(
                        files[i]
                    )
                )
            }

            try ring.submitPreparedRequests()

            sleep(1000)
        } catch (let openErr) {
            print(openErr)
        }
    }
}
