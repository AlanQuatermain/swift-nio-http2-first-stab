//
//  HTTP2Frame.swift
//  CNIOAtomics
//
//  Created by Jim Dovey on 6/21/18.
//

import NIO
import NIOHTTP1

/// A representation of a single HTTP/2 frame.
public struct HTTP2Frame
{
    /// The payload of this HTTP/2 frame.
    public var payload: FramePayload
    
    /// The frame flags as an 8-bit integer. To set/unset well-defined flags, consider using the
    /// other properties on this object (e.g. `endStream`).
    public var flags: FrameFlags
    
    /// The frame streamID as a 32-bit integer.
    public var streamID: HTTP2StreamID
    
    /// Whether the `END_STREAM` flag is set.
    public var endStream: Bool {
        get {
            switch self.payload {
            case .data, .headers:
                return self.flags.contains(.endStream)
            default:
                return false
            }
        }
        set {
            switch self.payload {
            case .data, .headers:
                self.flags.formUnion(.endStream)
            default:
                break
            }
        }
    }
    
    /// Whether the `PADDED` flag is set.
    public var padded: Bool {
        get {
            switch self.payload {
            case .data, .headers, .pushPromise:
                return self.flags.contains(.padded)
            default:
                return false
            }
        }
        set {
            switch self.payload {
            case .data, .headers, .pushPromise:
                self.flags.formUnion(.padded)
            default:
                break
            }
        }
    }
    
    /// Whether the `PRIORITY` flag is set.
    public var priority: Bool {
        get {
            if case .headers = self.payload {
                return flags.contains(.priority)
            }
            else {
                return false
            }
        }
        set {
            if case .headers = self.payload {
                flags.formUnion(.priority)
            }
        }
    }
    
    /// Whether the ACK flag is set.
    public var ack: Bool {
        get {
            switch self.payload {
            case .settings, .ping:
                return flags.contains(.ack)
            default:
                return false
            }
        }
        set {
            switch self.payload {
            case .settings, .ping:
                flags.formUnion(.ack)
            default:
                break
            }
        }
    }
    
    public enum FramePayload
    {
        case data(IOData)
        case headers(HTTPHeaders)
        case priority(Int32, Bool, UInt8)
        case resetStream(HTTP2ErrorCode)
        case settings([HTTP2Setting])
        case pushPromise(Int32, HTTPHeaders)
        case ping(HTTP2PingData)
        case goAway(lastStreamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, opaqueData: ByteBuffer?)
        case windowUpdate(windowSizeIncrement: Int)
        case continuation(HTTPHeaders)
        case alternativeService
        
        var allowedFlags: FrameFlags {
            switch self {
            case .data:
                return [.endStream, .padded]
            case .headers:
                return [.endStream, .endHeaders, .padded, .priority]
            case .priority:
                return []
            case .resetStream:
                return []
            case .settings:
                return [.ack]
            case .pushPromise:
                return [.endHeaders, .padded]
            case .ping:
                return [.ack]
            case .goAway:
                return []
            case .windowUpdate:
                return []
            case .continuation:
                return [.endHeaders]
            case .alternativeService:
                return []
            }
        }
        
        func validateFlags(_ flags: FrameFlags) -> Bool {
            return flags.isSubset(of: allowedFlags)
        }
    }
    
    public struct FrameFlags : OptionSet
    {
        public typealias RawValue = UInt8
        
        public private(set) var rawValue: UInt8
        
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        public static let endStream    = FrameFlags(rawValue: 0x01)
        public static let ack          = FrameFlags(rawValue: 0x01)
        public static let endHeaders   = FrameFlags(rawValue: 0x04)
        public static let padded       = FrameFlags(rawValue: 0x08)
        public static let priority     = FrameFlags(rawValue: 0x20)
        
        // for unit tests
        static let allFlags: FrameFlags = [.endStream, .endHeaders, .padded, .priority]
    }
}

internal extension HTTP2Frame
{
    internal init(streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.flags = flags
        self.payload = payload
    }
}

public extension HTTP2Frame
{
    /// Constructs a frame header for a given stream ID. All flags are unset.
    public init(streamID: HTTP2StreamID, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.flags = []
        self.payload = payload
    }
}

public enum FrameType : UInt8
{
    case data           // 0
    case headers        // 1
    case priority       // 2
    case resetStream    // 3
    case settings       // 4
    case pushPromise    // 5
    case ping           // 6
    case goAway         // 7
    case windowUpdate   // 8
    case continuation   // 9
}
