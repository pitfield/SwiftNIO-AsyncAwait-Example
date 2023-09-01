# SwiftNIO-AsyncAwait-Example
Demonstrates consuming the SwiftNIO library through simple `async`/`await` methods

This code example is a simple TCP client built on [SwiftNIO](https://github.com/apple/swift-nio). SwiftNIO predates the concurrency features built into the Swift language, such as the `async` and `await` keywords. Although SwiftNIO is being retrofitted to support these language features, this work is not yet complete.[^fn]

This example shows an interim approach. Specifically, it adds two async methods to `Channel`:

    func asyncRead() async throws -> ByteBuffer?
    
    func asyncWrite(_ buffer: ByteBuffer) async throws
    
`asyncRead()` is implemented by an [`AsyncThrowingStream`](https://developer.apple.com/documentation/swift/asyncthrowingstream). Backpressure is applied to throttle incoming data to keep the number of bytes buffered by the `AsyncThrowingStream` within a target range, specified by `unconsumedBytesLowWatermark` and `unconsumedBytesHighWatermark`.

The implementation of `asyncWrite(buffer:)` is trivial, since SwiftNIO already supports an `async` write API.

## Usage

This example is a simple client that opens a TCP socket to a server, then reads lines from stdin (the keyboard), writes those lines to the socket, reads data from that socket, and prints that data to stdout. It can be run against the NIOEchoServer or NIOChatServer examples included in SwiftNIO (https://github.com/apple/swift-nio) or the NIOTLSServer example included in https://github.com/apple/swift-nio-ssl.

To run:

- Start the server of your choice
- Set the values of `host`, `port`, and `useSSL`
- From the terminal, `swift run` to start the client
- Ctrl+D to exit


[^fn]: If I'm missing something here, please let me know!
