import SystemPackage
import CSystem
import Foundation

@main
struct MainApp {
    @convention(c)
    static func data_ready() {

    }

    static func main() async throws {
        var ring = try IORing(queueDepth: 32)
        let parent = try FileDescriptor.open("/home/david/demo", .readOnly)
        let file = ring.registerFileSlots(count: 1).first!
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 65535, alignment: 0)
        let buffer = ring.registerBuffers(buf).first!
        let efd = eventfd(0, Int32(EFD_NONBLOCK))

        try ring.registerEventFD(FileDescriptor(rawValue: efd))
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
        let epollFD = epoll_create(1)
        var epoll_evt = epoll_event() //see CFRunLoop.c for example epoll usage
        epoll_evt.events = EPOLLIN | EPOLLET
        epoll_ctl(epollFD, efd, EPOLL_CTL_ADD, &epoll_evt)
    }
}
