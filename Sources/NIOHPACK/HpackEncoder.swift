//
//  HpackEncoder.swift
//  H2Swift
//
//  Created by Jim Dovey on 1/3/18.
//

import NIO

fileprivate let temporaryBufferTSDKey = "H2Swift.HPACK.IntegerBuffer"
fileprivate let largestEncodedIntegerLength = 11 // the largest possible encoded length of a 64-bit unsigned integer is 11 bytes.

/// A class which performs HPACK encoding of a list of headers.
public class HpackEncoder
{
    public static let defaultDynamicTableSize = DynamicHeaderTable.defaultSize
    private static let defaultDataBufferSize = 128
    
    // internal access for testability
    let headerIndexTable: IndexedHeaderTable
    
    private var huffmanEncoder = HuffmanEncoder()
    private var buffer: ByteBuffer
    
    public var encodedData: ByteBuffer {
        return buffer
    }
    
    public var dynamicTableSize: Int {
        return headerIndexTable.dynamicTableLength
    }
    
    public var maxDynamicTableSize: Int {
        get {
            return headerIndexTable.maxDynamicTableLength
        }
        set {
            headerIndexTable.maxDynamicTableLength = newValue
        }
    }
    
    /// Sets the maximum size for the dynamic table and optionally encodes the new value
    /// into the current packed header block to send to the peer.
    ///
    /// - Parameter size: The new maximum size for the dynamic header table.
    /// - Parameter sendUpdate: If `true`, sends the new maximum table size to the peer
    ///                         by encoding the value inline with the current header set.
    ///                         Default = `true`.
    public func setMaxDynamicTableSize(_ size: Int, andSendUpdate sendUpdate: Bool = true) {
        maxDynamicTableSize = size
        guard sendUpdate else { return }
        buffer.write(encodedInteger: UInt(size), prefix: 5, prefixBits: 0x20)
    }
    
    public init(maxDynamicTableSize: Int = HpackEncoder.defaultDynamicTableSize) {
        headerIndexTable = IndexedHeaderTable(maxDynamicTableSize: maxDynamicTableSize)
        buffer = ByteBufferAllocator().buffer(capacity: HpackEncoder.defaultDataBufferSize)
    }
    
    /// Resets the internal data buffer, ready to begin encoding a new header block.
    public func reset() {
        buffer.clear()
    }
    
    public func updateDynamicTable(for headers: [(String, String)]) throws {
        for (name, value) in headers {
            try headerIndexTable.append(headerNamed: name, value: value)
        }
    }
    
    /// Appends headers in the default fashion: indexed if possible, literal+indexable if not.
    public func append<S : Sequence>(headers: S) throws where S.Element == (name: String, value: String) {
        for (name, value) in headers {
            if append(header: name, value: value) {
                try headerIndexTable.append(headerNamed: name, value: value)
            }
        }
    }
    
    /// Appends a header/value pair, using indexed names/values if possible. If no indexed pair is available,
    /// it will use an indexed header and literal value, or a literal header and value. The name/value pair
    /// will be indexed for future use.
    public func append(header name: String, value: String) throws {
        if append(header: name, value: value) {
            try headerIndexTable.append(headerNamed: name, value: value)
        }
    }
    
    /// Appends a header/value pair, using indexed names/values if possible. If no indexed pair is available,
    /// it will use an indexed header and literal value, or a literal header and value.
    ///
    /// - returns: `true` if this name/value pair should be inserted into the dynamic table.
    func append(header: String, value: String) -> Bool {
        if let (index, hasValue) = headerIndexTable.firstHeaderMatch(forName: header, value: value) {
            if hasValue {
                // purely indexed. Nice & simple.
                buffer.write(encodedInteger: UInt(index), prefix: 7, prefixBits: 0x80)
                // everything is indexed-- nothing more to do!
                return false
            }
            else {
                // no value, so append the index to represent the name, followed by the value's length
                buffer.write(encodedInteger: UInt(index), prefix: 6, prefixBits: 0x40)
                // now encode and append the value string
                appendEncodedString(value)
            }
        }
        else {
            // no indexed name or value. Have to add them both, with a zero index
            buffer.write(integer: UInt8(0x40))
            appendEncodedString(header)
            appendEncodedString(value)
        }
        
        return true
    }
    
    private func appendEncodedString(_ string: String) {
        // encode the value
        huffmanEncoder.reset()
        let len = huffmanEncoder.encode(string)
        buffer.write(encodedInteger: UInt(len), prefix: 7, prefixBits: 0x80)
        
        buffer.write(bytes: huffmanEncoder.data)
    }
    
    /// Appends a header that is *not* to be entered into the dynamic header table, but allows that
    /// stipulation to be overriden by a proxy server/rewriter.
    public func appendNonIndexed(header: String, value: String) {
        if let (index, _) = headerIndexTable.firstHeaderMatch(forName: header, value: "") {
            // we actually don't care if it has a value, because we only use an indexed name here.
            buffer.write(encodedInteger: UInt(index), prefix: 4)
            // now append the value
            appendEncodedString(value)
        }
        else {
            buffer.write(integer: UInt8(0))    // all zeroes now
            appendEncodedString(header)
            appendEncodedString(value)
        }
    }
    
    /// Appends a header that is *never* indexed, preventing even rewriting proxies from doing so.
    public func appendNeverIndexed(header: String, value: String) {
        if let (index, _) = headerIndexTable.firstHeaderMatch(forName: header, value: "") {
            // we actually don't care if it has a value, because we only use an indexed name here.
            buffer.write(encodedInteger: UInt(index), prefix: 4, prefixBits: 0x10)
            // now append the value
            appendEncodedString(value)
        }
        else {
            buffer.write(integer: UInt8(0x10))
            appendEncodedString(header)
            appendEncodedString(value)
        }
    }
}
