//
//  HpackDecoder.swift
//  H2Swift
//
//  Created by Jim Dovey on 1/4/18.
//

import NIO

public class HpackDecoder
{
    public static let maxDynamicTableSize = DynamicHeaderTable.defaultSize
    
    // internal for testability
    let headerTable: IndexedHeaderTable
    
    var dynamicTableLength: Int {
        return headerTable.dynamicTableLength
    }
    
    public var maxDynamicTableLength: Int {
        get {
            return headerTable.maxDynamicTableLength
        }
        set {
            headerTable.maxDynamicTableLength = newValue
        }
    }
    
    public enum Error : Swift.Error
    {
        case invalidIndexedHeader(Int)
        case indexedHeaderWithNoValue(Int)
        case indexOutOfRange(Int, Int)
        case invalidUTF8StringData(ByteBuffer)
        case invalidHeaderStartByte(UInt8, Int)
    }
    
    public init(maxDynamicTableSize: Int = HpackDecoder.maxDynamicTableSize) {
        headerTable = IndexedHeaderTable(maxDynamicTableSize: maxDynamicTableSize)
    }
    
    public func decodeHeaders(from buffer: inout ByteBuffer) throws -> [(String, String)] {
        var result = [(String, String)]()
        while buffer.readableBytes > 0 {
            if let pair = try decodeHeader(from: &buffer) {
                result.append(pair)
            }
        }
        return result
    }
    
    private func decodeHeader(from buffer: inout ByteBuffer) throws -> (String, String)? {
        let initial: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        switch initial {
        case let x where x & 0x80 == 0x80:
            // purely-indexed header field/value
            let hidx = try buffer.readEncodedInteger(withPrefix: 7)
            return try decodeIndexedHeader(from: Int(hidx))
            
        case let x where x & 0xc0 == 0x40:
            // literal header with possibly-indexed name
            let hidx = try buffer.readEncodedInteger(withPrefix: 6)
            return try decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx))
            
        case let x where x & 0xf0 == 0x00:
            // literal header with possibly-indexed name, not added to dynamic table
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            return try decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx), addToIndex: false)
            
        case let x where x & 0xf0 == 0x10:
            // literal header with possibly-indexed name, never added to dynamic table or modified by proxies
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            return try decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx), addToIndex: false)
            
        case let x where x & 0xe0 == 0x20:
            // dynamic header table size update
            maxDynamicTableLength = try Int(buffer.readEncodedInteger(withPrefix: 5))
            return nil
            
        default:
            throw Error.invalidHeaderStartByte(initial, 0)
        }
    }
    
    private func decodeIndexedHeader(from hidx: Int) throws -> (String, String) {
        guard let (h, v) = headerTable.header(at: hidx) else {
            throw Error.invalidIndexedHeader(hidx)
        }
        guard !v.isEmpty else {
            throw Error.indexedHeaderWithNoValue(hidx)
        }
        
        return (h, v)
    }
    
    private func decodeLiteralHeader(from buffer: inout ByteBuffer, headerIndex: Int, addToIndex: Bool = true) throws -> (String, String) {
        if headerIndex != 0 {
            guard let (h, _) = headerTable.header(at: headerIndex) else {
                throw Error.invalidIndexedHeader(headerIndex)
            }
            
            let value = try readEncodedString(from: &buffer)
            
            // This type gets written into the dynamic table
            if addToIndex {
                try headerTable.append(headerNamed: h, value: value)
            }
            
            return (h, value)
        }
        else {
            let header = try readEncodedString(from: &buffer)
            let value = try readEncodedString(from: &buffer)
            
            if addToIndex {
                try headerTable.append(headerNamed: header, value: value)
            }
            
            return (header, value)
        }
    }
    
    private func readEncodedString(from buffer: inout ByteBuffer) throws -> String {
        // get the encoding bit
        let initialByte: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        let huffmanEncoded = initialByte & 0x80 == 0x80
        
        // read the length. There's a seven-bit prefix here (topmost bit indicated encoding)
        let len = try Int(buffer.readEncodedInteger(withPrefix: 7))
        
        if huffmanEncoded {
            guard var slice = buffer.readSlice(length: len) else {
                throw Error.indexOutOfRange(len, buffer.readableBytes)
            }
            return try readHuffmanString(from: &slice)
        }
        else {
            guard let result = buffer.readString(length: len) else {
                throw Error.indexOutOfRange(len, buffer.readableBytes)
            }
            return result
        }
    }
    
    private func readPlainString(from buffer: inout ByteBuffer) throws -> String {
        let bufCopy = buffer
        guard let result = buffer.readString(length: buffer.readableBytes) else {
            throw Error.invalidUTF8StringData(bufCopy.slice())
        }
        return result
    }
    
    private func readHuffmanString(from buffer: inout ByteBuffer) throws -> String {
        let decoder = HuffmanDecoder()
        return try buffer.readWithUnsafeReadableBytes { ptr -> (Int, String) in
            let str = try decoder.decodeString(from: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                               count: ptr.count)
            return (ptr.count, str)
        }
    }
}
