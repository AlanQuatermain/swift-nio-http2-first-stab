//
//  HTTP2PingData.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 6/21/18.
//

/// The opaque data contained in a HTTP/2 ping frame.
///
/// A HTTP/2 ping frame must contain 8 bytes of opaque data that is controlled entirely by the sender.
/// This data type encapsulates those 8 bytes while providing a friendly interface for them.
public struct HTTP2PingData
{
    /// The underlying bytes to be sent to the wire. These are in network byte order.
    public var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    
    /// Exposes the `HTTP2PingData` as an unsigned 64-bit integer. This property will perform any
    /// endianness transition that is required, meaning that there is no need to byte swap the result
    /// or before setting this property.
    public var integer: UInt64 {
        get {
            return withUnsafeBytes(of: bytes) { bufPtr -> UInt64 in
                let u64Ptr = bufPtr.baseAddress!.assumingMemoryBound(to: UInt64.self)
                return UInt64(bigEndian: u64Ptr.pointee)
            }
        }
        set {
            withUnsafeMutableBytes(of: &bytes) { bufPtr in
                let u64Ptr = bufPtr.baseAddress!.assumingMemoryBound(to: UInt64.self)
                u64Ptr.pointee = newValue.bigEndian
            }
        }
    }
    
    /// Create a new, blank, `HTTP2PingData`.
    public init() {
        self.bytes = (0, 0, 0, 0, 0, 0, 0, 0)
    }
    
    /// Create a `HTTP2PingData` containing the 64-bit integer provided, converting to network
    /// byte order if necessary.
    public init(withInteger integer: UInt64) {
        self.init()
        self.integer = integer
    }
    
    /// Create a `HTTP2PingData` from a tuple of bytes.
    public init(withTuple tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) {
        self.bytes = tuple
    }
}

extension HTTP2PingData : RandomAccessCollection, MutableCollection
{
    public typealias Index = Int
    public typealias Element = UInt8
    
    public var startIndex: Index {
        return 0
    }
    public var endIndex: Index {
        return 8
    }
    
    public subscript(_ index: Index) -> Element {
        get {
            switch index {
            case 0: return self.bytes.0
            case 1: return self.bytes.1
            case 2: return self.bytes.2
            case 3: return self.bytes.3
            case 4: return self.bytes.4
            case 5: return self.bytes.5
            case 6: return self.bytes.6
            case 7: return self.bytes.7
            default:
                preconditionFailure("Invalid index into HTTP2PingData: \(index)")
            }
        }
        set {
            switch index {
            case 0: self.bytes.0 = newValue
            case 1: self.bytes.1 = newValue
            case 2: self.bytes.2 = newValue
            case 3: self.bytes.3 = newValue
            case 4: self.bytes.4 = newValue
            case 5: self.bytes.5 = newValue
            case 6: self.bytes.6 = newValue
            case 7: self.bytes.7 = newValue
            default:
                preconditionFailure("Invalid index into HTTP2PingData: \(index)")
            }
        }
    }
}

extension HTTP2PingData : Equatable
{
    public static func == (lhs: HTTP2PingData, rhs: HTTP2PingData) -> Bool {
        return lhs.integer == rhs.integer
    }
}

extension HTTP2PingData : Hashable
{
    public var hashValue: Int {
        return self.integer.hashValue
    }
}
