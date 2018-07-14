//
//  IntegerTypes.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 6/22/18.
//

/// A 24-bit unsigned integer, as used for HTTP/2 frame lengths.
@usableFromInline
struct _UInt24 : ExpressibleByIntegerLiteral
{
    typealias IntegerLiteralType = UInt16
    
    // NB: This matches a little-endian byte order
    @_versioned var b12: UInt16 // low-order bits
    @_versioned var b3: UInt8   // high-order bits
    
    fileprivate init(b12: UInt16, b3: UInt8) {
        self.b12 = b12
        self.b3 = b3
    }
    
    init(integerLiteral value: UInt16) {
        self.init(b12: value, b3: 0)
    }
    
    static let bitWidth: Int = 24
    
    static var max: _UInt24 {
        return .init(b12: .max, b3: .max)
    }
    
    static let min: _UInt24 = 0
}

extension UInt32
{
    init(_ value: _UInt24) {
        var newValue: UInt32 = 0
        newValue  = UInt32(value.b12)
        newValue |= UInt32(value.b3) << 16
        self = newValue
    }
}

extension Int
{
    init(_ value: _UInt24) {
        var newValue: Int = 0
        newValue  = Int(value.b12)
        newValue |= Int(value.b3) << 16
        self = newValue
    }
}

extension _UInt24
{
    init(_ value: UInt32) {
        assert(value & 0xff_00_00_00 == 0, "\(value) too large for _UInt24")
        self.b12 = UInt16(truncatingIfNeeded: value & 0xff_ff)
        self.b3  = UInt8(value >> 16)
    }
}

extension _UInt24 : Equatable
{
    static func == (lhs: _UInt24, rhs: _UInt24) -> Bool {
        return lhs.b12 == rhs.b12 && lhs.b3 == rhs.b3
    }
}

extension _UInt24 : Hashable
{
    var hashValue: Int {
        return Int(self)
    }
}

extension _UInt24 : Comparable
{
    static func < (lhs: _UInt24, rhs: _UInt24) -> Bool {
        return lhs.b3 < rhs.b3 || lhs.b12 < rhs.b12
    }
}

extension ByteBuffer
{
    mutating func readInteger(endianness: Endianness = .big) -> _UInt24? {
        let b12: UInt16?
        let b3: UInt8?
        
        switch endianness {
        case .big:
            // high-order byte appears first
            b3 = readInteger()
            b12 = readInteger()
        case .little:
            // low-order bytes appear first
            b12 = readInteger(endianness: .little)
            b3 = readInteger(endianness: .little)
        }
        
        if let b12 = b12, let b3 = b3 {
            return _UInt24(b12: b12, b3: b3)
        }
        else {
            return nil
        }
    }
    
    @discardableResult
    mutating func write(integer value: _UInt24, endianness: Endianness = .big) -> Int {
        switch endianness {
        case .big:
            // high-order byte first
            return write(integer: value.b3) + write(integer: value.b12)
        case .little:
            // low-order bytes first
            return write(integer: value.b12, endianness: .little) + write(integer: value.b3, endianness: .little)
        }
    }
}
