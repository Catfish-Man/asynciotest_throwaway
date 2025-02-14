import Algorithms
import CSystem
import Dispatch
import Glibc
import Synchronization
import SystemPackage

extension FileDescriptor {
    static var currentWorkingDirectory: FileDescriptor { return FileDescriptor(rawValue: AT_FDCWD) }
}

func FILE_COUNT() -> UInt32 { 512 }
func FILE_COUNT() -> Int { Int(FILE_COUNT() as UInt32) }

@main
struct MainApp {

    static func main() async throws {
        let sum = Atomic(0)
        var verificationSum = 0
        var ring = try IORing(queueDepth: FILE_COUNT() * 7)
        let filenames = (0..<FILE_COUNT()).map { "testdatafile\($0).txt" }
        do {
            let files = ring.registerFileSlots(count: FILE_COUNT())
            let slab = UnsafeMutableRawBufferPointer.allocate(
                byteCount: 16 * FILE_COUNT() * 2, alignment: 0
            )
            slab.initializeMemory(as: Int.self, repeating: 0)
            let chunks = slab.evenlyChunked(in: FILE_COUNT() * 2)

            for (i, chunk) in zip(0..<FILE_COUNT(), chunks) {
                verificationSum += i
                chunk.storeBytes(of: i, as: Int.self)
            }
            verificationSum *= 2
            let bPtrs = chunks.lazy.map {
                UnsafeMutableRawBufferPointer(rebasing: $0)
            }
            let buffers = ring.registerBuffers(bPtrs)
            let efd = eventfd(0, Int32(EFD_NONBLOCK))

            for i in 0..<FILE_COUNT() {
                filenames[i].withCString { cfilename in
                    ring.prepare(
                        linkedRequests:
                            .opening(
                                cfilename,
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
            }

            try ring.registerEventFD(FileDescriptor(rawValue: efd))
            let readSrc = DispatchSource.makeReadSource(fileDescriptor: efd)
            var completedOperationCount = 0

            let postWriteWork = {
                for i in 0..<FILE_COUNT() {
                    filenames[i].withCString { cfilename in
                        ring.prepare(
                            linkedRequests:
                                .opening(
                                    cfilename,
                                    in: .currentWorkingDirectory,
                                    into: files[i],
                                    mode: .readOnly
                                ),
                            .reading(
                                files[i],
                                into: buffers[i + FILE_COUNT()]
                            ),
                            .closing(
                                files[i]
                            ),
                            .unlinking(
                                cfilename,
                                in: .currentWorkingDirectory
                            )
                        )
                    }
                }

                try ring.submitPreparedRequests()
            }

            var doneWriting = false

            let handler: DispatchWorkItem = DispatchWorkItem { () -> Void in
                while let completion = ring.tryConsumeCompletion() {
                    completedOperationCount += 1
                    if completion.result < 0 {
                        print(
                            "Failed with \(completion), error \(String(cString: strerror(-completion.result))), number: \(completedOperationCount)"
                        )
                    }
                    if completion.userData > 0 {
                        let result = UnsafeRawPointer(bitPattern: UInt(completion.userData))!.load(
                            as: Int.self)
                        sum.wrappingAdd(result, ordering: .sequentiallyConsistent)
                    }
                    if !doneWriting && completedOperationCount == FILE_COUNT() * 3 {
                        doneWriting = true
                        completedOperationCount = 0
                        try! postWriteWork()
                    }
                    if doneWriting && completedOperationCount == FILE_COUNT() * 4 {
                        let resultSum = sum.load(ordering: .sequentiallyConsistent)
                        print(
                            "Sum of all values is \(resultSum), expected result is \(verificationSum)"
                        )
                        _exit(resultSum == verificationSum ? 0 : 1)
                    }
                }
            }
            readSrc.setEventHandler(
                handler: handler)
            readSrc.activate()

            try ring.submitPreparedRequests()

            sleep(1000)
            withExtendedLifetime(filenames) {}
            withExtendedLifetime(slab) {}
        } catch (let openErr) {
            print(openErr)
        }
    }
}
