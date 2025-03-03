import Algorithms
import CSystem
import Dispatch
import Glibc
import SystemPackage

extension FileDescriptor {
    static var currentWorkingDirectory: FileDescriptor { return FileDescriptor(rawValue: AT_FDCWD) }
}

func FILE_COUNT() -> UInt32 { 64 }
func FILE_COUNT() -> Int { Int(FILE_COUNT() as UInt32) }

@main
struct MainApp {
    static func main() async throws {
        var sum = 0
        var verificationSum = 0
        var ring = try IORing(queueDepth: FILE_COUNT() * 7)
        let filenames = (0..<FILE_COUNT()).map { FilePath("testdatafile\($0).txt") }
        do {
            let files = ring.registerFileSlots(count: FILE_COUNT())
            let slab = UnsafeMutableRawBufferPointer.allocate(
                byteCount: 16 * 1024 * 1024 * FILE_COUNT(), alignment: 0
            )
            slab.initializeMemory(as: UInt8.self, repeating: 2)
            verificationSum = 16 * 1024 * 1024 * FILE_COUNT() * 2
            let chunks = slab.evenlyChunked(in: FILE_COUNT())
            let bPtrs = chunks.lazy.map {
                UnsafeMutableRawBufferPointer(rebasing: $0)
            }
            let buffers = ring.registerBuffers(bPtrs)

            for i in 0..<FILE_COUNT() {
                ring.prepare(
                    linkedRequests:
                        .opening(
                            filenames[i],
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

            try ring.submitPreparedRequests()

            try ring.blockingConsumeCompletions(minimumCount: FILE_COUNT() * 3) {
                completion, error, done in
                if let error {
                    print(error)
                }
            }

            slab.initializeMemory(as: UInt8.self, repeating: 0)

            for i in 0..<FILE_COUNT() {
                ring.prepare(
                    linkedRequests:
                        .opening(
                            filenames[i],
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
                    ),
                    .unlinking(
                        filenames[i],
                        in: .currentWorkingDirectory
                    )
                )
            }

            try ring.submitPreparedRequests()

            try ring.blockingConsumeCompletions(minimumCount: FILE_COUNT() * 4) {
                completion, error, done in
                if let completion {
                    if completion.result < 0 {
                        print(
                            "Failed with \(completion), error \(String(cString: strerror(-completion.result)))"
                        )
                    }
                    if completion.userData > 0 {
                        let bptr = UnsafeRawPointer(bitPattern: UInt(completion.userData))!
                        let resultBuffer = UnsafeRawBufferPointer(
                            start: bptr, count: Int(completion.result))
                        let result = resultBuffer.reduce(into: Int(0)) { accum, next in
                            accum += Int(next)
                        }
                        sum += result
                    }
                }
                if let error {
                    print(error)
                }
            }
            print(
                "Sum of all values is \(sum), expected result is \(verificationSum)"
            )
            _exit(sum == verificationSum ? 0 : 1)
            withExtendedLifetime(slab) {}
        } catch (let openErr) {
            print(openErr)
        }
    }
}
