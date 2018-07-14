//
//  HTTP2Session.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 6/21/18.
//

import NIO
import NIOHTTP1

enum FrameError : Error
{
    case incompleteFrame
    case invalidFlags(HTTP2Frame.FrameFlags)
    case unknownType(type: UInt8, length: Int)
}

extension FrameError : Equatable
{
    static func == (lhs: FrameError, rhs: FrameError) -> Bool {
        switch (lhs, rhs) {
        case (.incompleteFrame, .incompleteFrame):
            return true
        case let (.invalidFlags(l), .invalidFlags(r)):
            return l == r
        case let (.unknownType(lt, ll), .unknownType(rt, rl)):
            return lt == rt && ll == rl
        default:
            return false
        }
    }
}

extension HTTP2Frame.FramePayload
{
    var code: UInt8 {
        switch self {
        case .data: return 0
        case .headers: return 1
        case .priority: return 2
        case .resetStream: return 3
        case .settings: return 4
        case .pushPromise: return 5
        case .ping: return 6
        case .goAway: return 7
        case .windowUpdate: return 8
        case .continuation: return 9
        default:
            fatalError("This is not a real frame!")
        }
    }
}

fileprivate let frameHeaderSize = 9



/// This struct exists to work around an annoying problem with stream data when using nghttp2,
/// which is that we need to have a structure but nghttp2 doesn't give us anywhere nice to hang
/// it. We also need to keep track of stream IDs that we may have seen in the past, in case they
/// reappear.
///
/// This is because of the need to use `HTTP2StreamID`, a type that makes me quite
/// unhappy in its current form. In general we attempt to obtain the stream ID from nghttp2
/// directly by asking for the `HTTP2Stream` object, but it is occasionally possible that
/// we need to obtain a stream ID for a stream that is long gone (e.g. for RST_STREAM or
/// GOAWAY purposes). This structure maintains a map that allows us to resurrect these as needed.
fileprivate struct StreamManager
{
    /// The map of streams from their network stream ID.
    ///
    /// This map contains two types of stream IDs. The first are stream IDs for streams that
    /// are no longer active. The second are two special sentinel values, for the root stream
    /// and the highest numbered stream ID.
    private var streamMap: [Int32 : HTTP2Stream]
    
    /// The maximum size of the cache.
    private let maxSize: Int
    
    /// The parser mode for this connection.
    private let mode: HTTP2Parser.ParserMode
    
    fileprivate init(mode: HTTP2Parser.ParserMode, maxSize: Int) {
        self.maxSize = maxSize
        self.mode = mode
        self.streamMap = [
            0 : HTTP2Stream(mode: mode, streamID: .rootStream),
            Int32.max: HTTP2Stream(mode: mode, streamID: .maxID)
        ]
    }
    
    /// Obtains the NIO stream data for a given stream, or nil if NIO doesn't know about this stream.
    public func getStreamData(for streamID: Int32) -> HTTP2Stream? {
        return self.streamMap[streamID]
    }
    
    /// Creates stream data for a given stream.
    mutating func createStreamData(for streamID: Int32) -> HTTP2Stream {
        return createStreamData(for: HTTP2StreamID(knownID: streamID))
    }
    
    /// Creates stream data for a given stream with an internal stream ID.
    mutating func createStreamData(for internalStreamID: HTTP2StreamID) -> HTTP2Stream {
        self.purgeOldStreams()
        let streamData = HTTP2Stream(mode: self.mode, streamID: internalStreamID)
        self.streamMap[internalStreamID.networkStreamID!] = streamData
        return streamData
    }
    
    /// Discard old and unnecessary streams.
    private mutating func purgeOldStreams() {
        while self.streamMap.count >= maxSize {
            let lowestStreamID = self.streamMap.filter { $0.value.active }.keys.sorted().first { $0 != 0 && $0 != Int32.max }!
            self.streamMap.removeValue(forKey: lowestStreamID)
        }
    }
}

/// Each HTTP/2 connection is represented inside nghttp2 by using a `nghttp2_session` object. This
/// object is represented in C by a pointer to an opaque structure, which is safe to use from only
/// one thread. In order to manage the initialization state of this structure, we wrap it in a
/// Swift class that can be used to ensure that the `nghttp2_session` object has its lifetime
/// managed appropriately.
class HTTP2Session
{
    public var frameReceivedHandler: (HTTP2Frame) -> Void
    
    public var headersAccumulation: HTTPHeaders! = nil
    
    /// An internal buffer used to accumulate the body of DATA frames.
    private var dataAccumulation: ByteBuffer
    
    /// Access to an allocator for use during frame callbacks.
    private let allocator: ByteBufferAllocator
    
    /// The mode of this session: client or server.
    private let mode: HTTP2Parser.ParserMode
    
    /// A small byte-buffer used to write DATA frame headers into.
    ///
    /// In many cases this will trigger a CoW (as most flushes will write more than one DATA
    /// frame), so we allocate a new small buffer for this rather than use one of the other buffers
    /// we have lying around. That shrinks the allocation sizes and allows us to use clear() rather
    /// than slicing and potentially triggering copies of the entire buffer for no good reason.
    private var dataFrameHeaderBuffer: ByteBuffer
    
    /// The callback passed by the parent object, to call each time we need to send some data.
    ///
    /// This is expected to have similar semantics to `Channel.write`: that is, it does not trigger I/O
    /// directly. This can safely be called at any time, including when reads have been fed to the code.
    private let sendFunction: (IOData, EventLoopPromise<Void>?) -> Void
    
    /// The callback passed by the parent object to call each time we want to send a user event.
    private let userEventFunction: (Any) -> Void
    
    // TODO(cory): This is not really sufficient, we need to introspect nghttp2, but it is enough for now.
    private var closed: Bool = false
    
    private var streamIDManager: StreamManager
    
    init(mode: HTTP2Parser.ParserMode, allocator: ByteBufferAllocator, maxCachedStreamIDs: Int,
         frameReceivedHandler: @escaping (HTTP2Frame) -> Void,
         sendFunction: @escaping (IOData, EventLoopPromise<Void>?) -> Void,
         userEventFunction: @escaping (Any) -> Void) {
        self.frameReceivedHandler = frameReceivedHandler
        self.sendFunction = sendFunction
        self.userEventFunction = userEventFunction
        self.allocator = allocator
        self.mode = mode
        self.streamIDManager = StreamManager(mode: mode, maxSize: maxCachedStreamIDs)
        
        // TODO(cory): We should make MAX_FRAME_SIZE configurable and use that, rather than hardcode
        // that value here.
        self.dataAccumulation = allocator.buffer(capacity: 16384)  // 2 ^ 14
        
        // 9 is the size of the serialized frame header, excluding the padding byte, which we never set.
        self.dataFrameHeaderBuffer = allocator.buffer(capacity: 9)
        
        // NGhttp2 session setup was here
    }
    
    fileprivate func onBeginFrameCallback() {
        // if frame is data:
        // We need this buffer now: we delayed this potentially CoW operation as long
        // as we could.
        self.dataAccumulation.clear()
    }
    
    public func feedOutput(frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        if self.closed {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        
        var buffer = allocator.buffer(capacity: frameHeaderSize)
        do {
            try self.encode(frame: frame, to: &buffer)
            
            // usually all the data is now in the frame. There are some cases where there's already an IOData
            // or a ByteBuffer attached as payload. In those cases we'll issue two separate writes.
            
            switch frame.payload {
            case .data(let ioData):
                sendFunction(.byteBuffer(buffer), nil)
                sendFunction(ioData, promise)
            case .goAway(_, _, let opaqueData?):
                sendFunction(.byteBuffer(buffer), nil)
                sendFunction(.byteBuffer(opaqueData), promise)
            default:
                sendFunction(.byteBuffer(buffer), promise)
            }
        }
        catch {
            promise?.fail(error: error)
        }
    }
    
    public func receivedEOF() {
        // EOF is the end of this connection. If the connection is already over, that's fine: otherwise,
        // we want to throw an error for reporting on the pipeline. Either way, we need to clean up our state.
        self.closed = true
        
        // TODO(cory): Check state, throw in error cases.
    }
    
    enum WriteResult
    {
        case didWrite
        case noWrite
    }
    
    public func doOneWrite() -> WriteResult {
        guard let bytes = getNextFrameBytes() else {
            return .noWrite
        }
        
        self.sendFunction(.byteBuffer(bytes), nil)
        return .didWrite
    }
    
    /// Given a headers frame, configure nghttp2 to write it and set up appropriate
    /// settings for sending data.
    ///
    /// The complexity of this function exists because nghttp2 does not allow us to have both a headers
    /// and a data frame pending for a stream at the same time. As a result, before we've sent the headers frame we
    /// cannot ask nghttp2 to send the data frame for us. Instead, we set up all our own state for sending data frames
    /// and then wait to swap it in until nghttp2 tells us the data got sent.
    ///
    /// That means all this state must be ready to go once we've submitted the headers frame to nghttp2. This function
    /// is responsible for getting all our ducks in a row.
    private func sendHeaders(frame: HTTP2Frame) {
        let headers: HTTPHeaders
        switch frame.payload {
        case .headers(let h), .continuation(let h):
            headers = h
        default:
            preconditionFailure("Attempting to send non-headers frame via \(#function)")
        }
        
        let isEndStream = frame.endStream
        
    }
    
    private func getNextFrameBytes() -> ByteBuffer? {
        
    }
    
    private func readPayloadLength(from buffer: inout ByteBuffer) -> Int {
        let first: UInt8 = buffer.readInteger()!
        let second: UInt8 = buffer.readInteger()!
        let third: UInt8 = buffer.readInteger()!
        
        // these are network byte-order, high-order bytes first
        return (Int(first) << 16 | Int(second) << 8 | Int(third))
    }
    
    private func writePayloadLength(_ length: Int, to buffer: inout ByteBuffer, at position: Int) {
        let networkInt = length.bigEndian
        withUnsafeBytes(of: networkInt) { (intBuf) -> Void in
            let bytes = intBuf[(intBuf.endIndex-3)...]
            buffer.set(bytes: bytes, at: position)
        }
    }
    
    // MARK: - Frame Encoding
    
    private func encode(frame: HTTP2Frame, to buffer: inout ByteBuffer) throws {
        // ensure enough capacity for the header
        buffer.ensureWriteSpaceAvailable(frameHeaderSize)
        
        // Note where we are, and skip the payload length for now
        let payloadSizeIndex = buffer.writerIndex
        // three-byte length
        buffer.moveWriterIndex(forwardBy: 3)
        // one-byte type
        buffer.write(integer: frame.payload.code)
        // one-byte flags
        buffer.write(integer: frame.flags.rawValue)
        // four-byte stream identifier
        buffer.write(integer: frame.streamID.networkStreamID!)
        
        // find the stream so we can encode things
        let stream = streamIDManager.getStreamData(for: frame.streamID.networkStreamID!)!
        
        // now note where we are again and encode the payload, so we can determine its length afterwards
        let length: Int
        switch frame.payload {
        case .data(let data):
            // NB: outbound data is never padded, for us
            // we just encode the length here, the data goes down the stack separately so it can be
            // processed appropriately as either bytes or a file region.
            length = data.readableBytes
            
        case .headers(let headers):
            let start = buffer.writerIndex
            // TODO: priority encoding
            try headers.forEach { (name, value) in
                try stream.encoder.append(header: name, value: value)
            }
            length = buffer.writerIndex - start
            
        case let .priority(streamID, exclusive, weight):
            var encoded = streamID
            if exclusive { encoded |= HTTP2StreamID.streamDependencyMask }
            buffer.write(integer: encoded)
            buffer.write(integer: weight)
            length = 5
            
        case .resetStream(let errorCode):
            buffer.write(http2ErrorCode: errorCode)
            length = 4
            
        case .settings(let settings):
            if frame.flags.contains(.ack) {
                length = 0
            }
            else {
                let start = buffer.writerIndex
                for setting in settings {
                    setting.compile(to: &buffer)
                }
                length = buffer.writerIndex - start
            }
            
        case let .pushPromise(streamID, headers):
            // NB: we never pad when sending frames
            let start = buffer.writerIndex
            buffer.write(integer: streamID & ~HTTP2StreamID.streamDependencyMask)
            try headers.forEach { name, value in
                try stream.encoder.append(header: name, value: value)
            }
            length = buffer.writerIndex - start
            
        case .ping(let pingData):
            withUnsafeBytes(of: pingData.bytes) { buf in
                let bytes = buf.bindMemory(to: UInt8.self)
                buffer.write(bytes: bytes)
            }
            length = 8
            
        case let .goAway(lastStreamID, errorCode, opaqueData):
            // NB: opaque data will be fed down the pipe separately, since we can't assume it's small enough to
            // be copied around
            buffer.write(integer: lastStreamID.networkStreamID! & ~HTTP2StreamID.streamDependencyMask)
            buffer.write(http2ErrorCode: errorCode)
            length = 8 + (opaqueData?.readableBytes ?? 0)
            
        case .windowUpdate(let windowSizeIncrement):
            buffer.write(integer: windowSizeIncrement & 0x7fff_ffff)    // 31-bit unsigned value
            length = 4
            
        case .continuation(let headers):
            let start = buffer.writerIndex
            try headers.forEach { name, value in
                try stream.encoder.append(header: name, value: value)
            }
            length = buffer.writerIndex - start
        }
        
        writePayloadLength(length, to: &buffer, at: payloadSizeIndex)
    }
    
    // MARK: - Frame Decoding
    
    private func decodeFrame(from buffer: inout ByteBuffer) throws -> HTTP2Frame {
        guard buffer.readableBytes >= frameHeaderSize else {
            throw FrameError.incompleteFrame
        }
        
        let payloadLen: Int = readPayloadLength(from: &buffer)
        let frameType: UInt8 = buffer.readInteger()!
        let frameFlags: UInt8 = buffer.readInteger()!
        let streamId: Int32 = buffer.readInteger()!
        
        guard payloadLen <= buffer.readableBytes else {
            throw FrameError.incompleteFrame
        }
        
        guard FrameType(rawValue: frameType) != nil else {
            throw FrameError.unknownType(type: frameType, length: payloadLen)
        }
        
        // one-byte flags
        // Sender MUST NOT send invalid flags, but receiver MUST ignore any invalid flags (§ 4.1)
        // Therefore, we don't throw when we see something we don't understand.
        let flags = HTTP2Frame.FrameFlags(rawValue: frameFlags)
        
        // we MUST ignore the topmost bit of the stream ID
        let streamIdentifier = Int32(streamId & ~HTTP2StreamID.streamDependencyMask)
        guard let stream = self.streamIDManager.getStreamData(for: streamIdentifier) else {
            throw NIOHTTP2Errors.NoSuchStream(streamID: HTTP2StreamID(knownID: streamId))
        }
        
        let decoder: (inout ByteBuffer, Int, HTTP2Frame.FrameFlags, HTTP2Stream) throws -> HTTP2Frame
        
        switch frameType {
        case 0:
            decoder = decodeDataFrame
        case 1:
            decoder = decodeHeadersFrame
        case 2:
            decoder = decodePriorityFrame
        case 3:
            decoder = decodeResetStreamFrame
        case 4:
            decoder = decodeSettingsFrame
        case 5:
            decoder = decodePushPromiseFrame
        case 6:
            decoder = decodePingFrame
        case 7:
            decoder = decodeGoAwayFrame
        case 8:
            decoder = decodeWindowUpdateFrame
        case 9:
            decoder = decodeContinuationFrame
        default:
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        
        return try decoder(&buffer, payloadLen, flags, stream)
    }
    
    private func decodeDataFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags, stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID != .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        
        var payloadBytes = buffer.readSlice(length: length)!
        if flags.contains(.padded) {
            let padding: UInt8 = payloadBytes.readInteger()!
            if padding > length - 1 {
                throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
            }
        }
        
        // make a concrete copy at this point
        payloadBytes.discardReadBytes()
        
        let payload: HTTP2Frame.FramePayload = .data(.byteBuffer(payloadBytes))
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodeHeadersFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                    stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID != .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        
        var payloadBytes = buffer.readSlice(length: length)!
        
        // absorb any padding bytes
        if flags.contains(.padded) {
            let padding: UInt8 = payloadBytes.readInteger()!
            // validate it
            guard padding < UInt8(flags.contains(.priority) ? length - 6 : length - 1) else {
                // padding is larger than the number of available bytes in the payload
                throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
            }
        }
        
        if flags.contains(.priority) {
            let _ /*dependency*/: Int32 = payloadBytes.readInteger()!
//            let isExclusive = dependency & HTTP2StreamID.streamDependencyMask != 0
//            let streamDependency = dependency & ~HTTP2StreamID.streamDependencyMask
            
            let _ /*weight*/: UInt8 = payloadBytes.readInteger()!
        }
        
        // now decode the headers
        let headers = try stream.decoder.decodeHeaders(from: &payloadBytes)
        let payload = HTTP2Frame.FramePayload.headers(HTTPHeaders(headers))
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodePriorityFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                     stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID != .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        guard length == 5 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        
        let rawDependency: Int32 = buffer.readInteger()!
        let dependency = rawDependency & ~HTTP2StreamID.streamDependencyMask
        let isExclusive = rawDependency & HTTP2StreamID.streamDependencyMask != 0
        let weight: UInt8 = buffer.readInteger()! + 1
        
        let payload = HTTP2Frame.FramePayload.priority(dependency, isExclusive, weight)
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodeResetStreamFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                        stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID != .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        guard length == 4 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        
        let errorCode: UInt32 = buffer.readInteger()!
        let payload = HTTP2Frame.FramePayload.resetStream(HTTP2ErrorCode(errorCode))
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodeSettingsFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                     stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID == .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        
        let isAckFrame = flags.contains(.ack)
        guard isAckFrame || length % 6 == 0 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        guard !isAckFrame || length == 0 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        
        var settings: [HTTP2Setting] = []
        if !isAckFrame {
            // get a slice of the data, so we can run until no more bytes are available
            var slice = buffer.readSlice(length: length)!
            while slice.readableBytes > 0 {
                if let setting = try HTTP2Setting.decode(from: &slice) {
                    settings.append(setting)
                }
            }
        }
        
        let payload = HTTP2Frame.FramePayload.settings(settings)
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodePushPromiseFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                        stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID != .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        guard length >= 4 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        
        var bytes = buffer.readSlice(length: length)!
        
        if flags.contains(.padded) {
            let padding: UInt8 = bytes.readInteger()!
            guard Int(padding) < length - 1 else {
                // padding exceeds size of frame!
                throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
            }
        }
        
        let promisedStreamId: Int32 = bytes.readInteger()! & ~HTTP2StreamID.streamDependencyMask
        guard promisedStreamId > stream.streamID.networkStreamID! && promisedStreamId != 0 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        
        // decode headers
        let headers = try stream.decoder.decodeHeaders(from: &bytes)
        let payload = HTTP2Frame.FramePayload.pushPromise(promisedStreamId, HTTPHeaders(headers))
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodePingFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                 stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID == .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        guard length == 8 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        
        let value: UInt64 = buffer.readInteger()!
        let payload = HTTP2Frame.FramePayload.ping(HTTP2PingData(withInteger: value))
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodeGoAwayFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                   stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID == .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        guard length >= 8 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        
        let lastStreamID = HTTP2StreamID(knownID: buffer.readInteger()! & ~HTTP2StreamID.streamDependencyMask)
        let errorCode = HTTP2ErrorCode(buffer.readInteger()!)
        
        let opaqueData: ByteBuffer?
        if length > 8 {
            opaqueData = buffer.readSlice(length: length - 8)
        }
        else {
            opaqueData = nil
        }
        
        let payload = HTTP2Frame.FramePayload.goAway(lastStreamID: lastStreamID, errorCode: errorCode, opaqueData: opaqueData)
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodeWindowUpdateFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                         stream: HTTP2Stream) throws -> HTTP2Frame {
        guard length == 4 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .frameSizeError)
        }
        
        let increment: Int32 = buffer.readInteger()! & 0x7fff_ffff
        guard increment != 0 else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        
        let payload = HTTP2Frame.FramePayload.windowUpdate(windowSizeIncrement: Int(increment))
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
    
    private func decodeContinuationFrame(from buffer: inout ByteBuffer, length: Int, flags: HTTP2Frame.FrameFlags,
                                         stream: HTTP2Stream) throws -> HTTP2Frame {
        guard stream.streamID != .rootStream else {
            throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
        }
        
        let headers = try stream.decoder.decodeHeaders(from: &buffer)
        let payload = HTTP2Frame.FramePayload.continuation(HTTPHeaders(headers))
        return HTTP2Frame(streamID: stream.streamID, flags: flags.intersection(payload.allowedFlags), payload: payload)
    }
}

extension ByteBuffer
{
    mutating func ensureWriteSpaceAvailable(_ available: Int) {
        let currentSpace = capacity - writerIndex
        if available <= currentSpace {
            return
        }
        
        let difference = available - currentSpace
        changeCapacity(to: capacity + difference)
    }
}
