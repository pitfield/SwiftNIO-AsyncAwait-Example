//
//  SwiftNIO-AsyncAwait-Example
//
//  Copyright 2023 David Pitfield
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import NIO

extension Channel {
    
    /// Asynchronously reads from this channel.
    ///
    /// - Returns: the read data, or nil if EOF
    func asyncRead() async throws -> ByteBuffer? {
        let handler = try await pipeline.handler(type: AsyncAwaitHandler.self).get()
        return try await handler.asyncRead()
    }
    
    /// Asynchronously writes to this channel.
    ///
    /// - Parameter buffer: the data to write
    func asyncWrite(_ buffer: ByteBuffer) async throws {
        let handler = try await pipeline.handler(type: AsyncAwaitHandler.self).get()
        try await handler.asyncWrite(buffer)
    }
}

/// A ChannelHandler that provides an async/await interface for a channel.
///
/// Backpressure is applied to throttle the incoming data to the rate at which it is consumed
/// through the async/await interface.
class AsyncAwaitHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    
    /// The channel to which this handler belongs.
    private weak var channel: Channel?
    
    /// Handles incoming data or errors from SwiftNIO.
    private var channelReadHandler: ((Result<ByteBuffer, Error>) -> Void)!
    
    /// An async iterator over incoming data.
    private var asyncReadIterator: AsyncThrowingStream<ByteBuffer, Error>.Iterator!
    
    /// Whether SwiftNIO has indicated there is incoming data waiting to be read.
    private var pendingRead = false
    
    /// The number of incoming bytes read from SwiftNIO but not yet returned by the async iterator.
    /// In other words, the number of bytes buffered by that iterator's underlying async stream.
    private var unconsumedBytesCount = 0
    
    /// An upper limit on the number of incoming bytes to buffer, above which we'll pause asking
    /// SwiftNIO for more data.
    private var unconsumedBytesHighWatermark: Int
    
    /// A lower limit on the number of incoming bytes to buffer, below which we'll resume asking
    /// SwiftNIO for more data.
    private var unconsumedBytesLowWatermark: Int
    
    /// Initializes the handler.
    ///
    /// - Parameters:
    ///   - unconsumedBytesHighWatermark: an upper limit on the number of incoming bytes to buffer,
    ///         above which we'll pause asking SwiftNIO for more data
    ///   - unconsumedBytesLowWatermark: a lower limit on the number of incoming bytes to buffer,
    ///         below which we'll resume asking SwiftNIO for more data
    init(unconsumedBytesHighWatermark: Int = 2048, unconsumedBytesLowWatermark: Int = 1024) {
        
        self.unconsumedBytesHighWatermark = unconsumedBytesHighWatermark
        self.unconsumedBytesLowWatermark = unconsumedBytesLowWatermark
        
        asyncReadIterator = AsyncThrowingStream() { continuation in
            
            channelReadHandler = { result in
                continuation.yield(with: result)
            }
            
            continuation.onTermination = { [weak channel] _ in
                _ = channel?.close()
            }
        }.makeAsyncIterator()
    }
    
    
    //
    // MARK: ChannelInboundHandler
    //
    
    func channelActive(context: ChannelHandlerContext) {
        channel = context.channel
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        channel = nil
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        
        // NOTE: this assertion will not hold if LineDelimiterCodec is added to the pipeline,
        // since it may split a single block of data read from the socket into more than one
        // lines
        assert(unconsumedBytesCount <= unconsumedBytesHighWatermark,
               "channelRead: already above high watermark " +
               "(ensure ChannelOptions.maxMessagesPerRead == 1)")
        
        let buffer = unwrapInboundIn(data)
        unconsumedBytesCount += buffer.readableBytes
        channelReadHandler(.success(buffer))
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        channelReadHandler(.failure(error))
    }
    
    
    //
    // MARK: ChannelOutboundHandler
    //
    
    func read(context: ChannelHandlerContext) {
        if unconsumedBytesCount > unconsumedBytesHighWatermark {
            pendingRead = true
        } else {
            context.read()
        }
    }
    
    
    //
    // MARK: async/await interface
    //
    
    fileprivate func asyncRead() async throws -> ByteBuffer? {
        
        guard let channel else { return nil }
        
        let buffer = try await asyncReadIterator.next()
        
        if let buffer {
            try await channel.eventLoop.submit { [self] in // get back onto the EventLoop thread
                unconsumedBytesCount -= buffer.readableBytes
                
                if unconsumedBytesCount <= unconsumedBytesLowWatermark && pendingRead {
                    pendingRead = false
                    channel.read()
                }
            }.get()
        }

        return buffer
    }
    
    fileprivate func asyncWrite(_ buffer: ByteBuffer) async throws {
        try await channel?.writeAndFlush(buffer)
    }
}


//
// MARK: The channel consumer
//
// To demonstrate use of the async/await APIs added above, this shows a simple client that reads
// lines from stdin, writes those lines to a socket, reads data from that socket, and prints that
// data to stdout.  This demo code can be run against the NIOEchoServer or NIOChatServer examples
// included in Swift-NIO (https://github.com/apple/swift-nio).

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

let bootstrap = ClientBootstrap(group: group)
    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .channelOption(ChannelOptions.maxMessagesPerRead, value: 1) // required for backpressure to work
    .channelInitializer { channel in
        channel.pipeline.addHandlers([
//            ByteToMessageHandler(LineDelimiterCodec()), // see above NOTE
            AsyncAwaitHandler()
        ])
    }

defer {
    print("# group shutting down")
    try! group.syncShutdownGracefully()
    print("# group shutdown")
}

let channel = try await bootstrap.connect(host: "localhost", port: 9999).get()
print("# channel connected")

let reader = Task {
    do {
        while let buffer = try await channel.asyncRead() {
            let string = String(buffer: buffer)
            print(string, terminator: "")
        }
    } catch {
        print("# reader failed: \(error)")
    }
    
    print("# reader exit")
}

let writer = Task {
    do {
        while let line = await asyncReadLine() {
            let buffer = channel.allocator.buffer(string: line)
            try await channel.asyncWrite(buffer)
        }
    } catch {
        print("# writer failed: \(error)")
    }
    
    print("# writer exit")
}

// Wait for the writer task to finish (by the user pressing Ctrl+D).
await writer.value

// Then cancel the reader task and wait for it to finish.
reader.cancel()
await reader.value

// Finally, close the channel.
print("# channel closing")
try await channel.close().get()
print("# channel closed")


/// Decodes bytes into lines each terminated by a UTF-8 newline character.
private class LineDelimiterCodec: ByteToMessageDecoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    
    let newline = "\n".utf8.first!

    func decode(context: ChannelHandlerContext,
                buffer: inout ByteBuffer) throws -> DecodingState {
        
        let index = buffer.withUnsafeReadableBytes { $0.firstIndex(of: newline) }
        
        if let index {
            context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: index + 1)!))
            return .continue
        }
        
        return .needMoreData
    }
}

/// Asynchronously reads a line from stdin.
///
/// - Returns: the line, including the newline terminator; or nil if EOF
func asyncReadLine() async -> String? {
    return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let line = readLine(strippingNewline: false)
            continuation.resume(returning: line)
        }
    }
}

// EOF
