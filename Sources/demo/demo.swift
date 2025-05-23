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
        var ring = try IORing(queueDepth: FILE_COUNT() * 7, flags: [])
        let filenames = (0..<FILE_COUNT()).map { FilePath("testdatafile\($0).txt") }
        let files = try ring.registerFileSlots(count: FILE_COUNT())
        let slab = UnsafeMutableRawBufferPointer.allocate(
            byteCount: 16 * 1024 * 1024 * FILE_COUNT(), alignment: 0
        )
        slab.initializeMemory(as: UInt8.self, repeating: 2)
        let verificationSum = 16 * 1024 * 1024 * FILE_COUNT() * 2
        let buffers = try ring.registerBuffers(
            slab.evenlyChunked(in: FILE_COUNT()).lazy.map {
                UnsafeMutableRawBufferPointer(rebasing: $0)
            })

        for i in 0..<FILE_COUNT() {
            ring.prepare(
                linkedRequests:
                .open(
                    filenames[i],
                    in: .currentWorkingDirectory,
                    into: files[i],
                    mode: .readWrite,
                    options: .create,
                    permissions: .ownerReadWrite
                ),
                .write(
                    buffers[i],
                    into: files[i]
                ),
                .close(
                    files[i]
                )
            )
        }

        try ring.submitPreparedRequestsAndConsumeCompletions(minimumCount: FILE_COUNT() * 3) {
            completion, error, done in
            if let error {
                throw error
            }
        }

        slab.initializeMemory(as: UInt8.self, repeating: 0)

        for i in 0..<FILE_COUNT() {
            ring.prepare(
                linkedRequests:
                .open(
                    filenames[i],
                    in: .currentWorkingDirectory,
                    into: files[i],
                    mode: .readOnly
                ),
                .read(
                    files[i],
                    into: buffers[i],
                    context: UInt64(UInt(bitPattern: buffers[i].unsafeBuffer.baseAddress!))
                ),
                .close(
                    files[i]
                ),
                .unlink(
                    filenames[i],
                    in: .currentWorkingDirectory
                )
            )
        }

        try ring.submitPreparedRequestsAndConsumeCompletions(minimumCount: FILE_COUNT() * 4) {
            (completion, error, done) in
            if let completion, completion.context > 0 {
                let resultBuffer = UnsafeRawBufferPointer(
                    start: completion.userPointer,
                    count: Int(completion.result)
                )
                sum += resultBuffer.reduce(into: Int(0)) { accum, next in
                    accum += Int(next)
                }
            }
            if let error {
                throw error
            }
        }
        print(
            "Sum of all values is \(sum), expected result is \(verificationSum)"
        )
        _exit(sum == verificationSum ? 0 : 1)
    }
}
