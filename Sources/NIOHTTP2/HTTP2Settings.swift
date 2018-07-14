//
//  HTTP2Settings.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 6/21/18.
//

import NIO

public enum HTTP2Setting
{
    case headerTableSize(Int32)         // 0x1
    case enablePush(Bool)               // 0x2
    case maxConcurrentStreams(Int32)    // 0x3
    case initialWindowSize(Int32)       // 0x4
    case maxFrameSize(Int32)            // 0x5
    case maxHeaderListSize(Int32)       // 0x6
    case acceptCacheDigest(Bool)        // 0x7  <https://datatracker.ietf.org/doc/draft-ietf-httpbis-cache-digest/>
    case enableConnectProtocol(Bool)    // 0x8  <https://datatracker.ietf.org/doc/draft-ietf-httpbis-h2-websockets/>
    
    internal var identifier: UInt16 {
        switch self {
        case .headerTableSize:          return 1
        case .enablePush:               return 2
        case .maxConcurrentStreams:     return 3
        case .initialWindowSize:        return 4
        case .maxFrameSize:             return 5
        case .maxHeaderListSize:        return 6
        case .acceptCacheDigest:        return 7
        case .enableConnectProtocol:    return 8
        }
    }
}

extension HTTP2Setting
{
    // nullable *and* throws? Invalid data causes an error, but unknown setting types return 'nil' quietly.
    static func decode(from buffer: inout ByteBuffer) throws -> HTTP2Setting? {
        if buffer.readableBytes < 6 {
            throw FrameError.incompleteFrame
        }
        
        let identifier: UInt16 = buffer.readInteger()!
        let value: Int32 = buffer.readInteger()!
        
        switch identifier {
        case 1:
            return .headerTableSize(value)
        case 2:
            guard value == 0 || value == 1 else {
                throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
            }
            return .enablePush(value == 1)
        case 3:
            return .maxConcurrentStreams(value)
        case 4:
            // yes, this looks weird. Yes, value is an Int32. Yes, this condition is stipulated in the
            // protocol specification.
            guard value <= UInt32.max else {
                throw NIOHTTP2Errors.ProtocolError(errorCode: .flowControlError)
            }
            return .initialWindowSize(value)
        case 5:
            guard value <= 16_777_215 else {        // 2^24-1
                throw NIOHTTP2Errors.ProtocolError(errorCode: .protocolError)
            }
            return .maxFrameSize(value)
        case 6:
            return .maxHeaderListSize(value)
        case 7:
            return .acceptCacheDigest(value == 1)
        case 8:
            return .enableConnectProtocol(value == 1)
        default:
            // ignore any unknown settings
            return nil
        }
    }
    
    func compile(to buffer: inout ByteBuffer) {
        buffer.write(integer: identifier)
        switch self {
        case .headerTableSize(let v),
             .maxConcurrentStreams(let v),
             .initialWindowSize(let v),
             .maxFrameSize(let v),
             .maxHeaderListSize(let v):
            buffer.write(integer: v)
        case .enablePush(let b),
             .acceptCacheDigest(let b),
             .enableConnectProtocol(let b):
            buffer.write(integer: b ? Int32(1) : Int32(0))
        }
    }
}

extension HTTP2Setting : Equatable
{
    public static func == (lhs: HTTP2Setting, rhs: HTTP2Setting) -> Bool {
        switch (lhs, rhs) {
        case let (.headerTableSize(l), .headerTableSize(r)):
            return l == r
        case let (.enablePush(l), .enablePush(r)):
            return l == r
        case let (.maxConcurrentStreams(l), .maxConcurrentStreams(r)):
            return l == r
        case let (.initialWindowSize(l), .initialWindowSize(r)):
            return l == r
        case let (.maxFrameSize(l), .maxFrameSize(r)):
            return l == r
        case let (.maxHeaderListSize(l), .maxHeaderListSize(r)):
            return l == r
        case let (.acceptCacheDigest(l), .acceptCacheDigest(r)):
            return l == r
        case let (.enableConnectProtocol(l), .enableConnectProtocol(r)):
            return l == r
        default:
            return false
        }
    }
}
