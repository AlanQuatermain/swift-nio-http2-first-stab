//
//  HTTP2Error.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 6/21/18.
//

public protocol NIOHTTP2Error : Equatable, Error {}

/// Errors that NIO raises when handling HTTP/2 connections.
public enum NIOHTTP2Errors
{
    /// NIO's upgrade handler encountered a successful upgrade to a protocol that it
    /// does not recognise.
    public struct InvalidALPNToken: NIOHTTP2Error
    {
        public init() {}
    }
    
    /// An attempt was made to issue a write on a stream that does not exist.
    public struct NoSuchStream: NIOHTTP2Error
    {
        /// The stream ID that was used that does not exist.
        public var streamID: HTTP2StreamID
        
        public init(streamID: HTTP2StreamID) {
            self.streamID = streamID
        }
    }
    
    /// A stream was closed.
    public struct StreamClosed: NIOHTTP2Error
    {
        /// The stream ID that was closed.
        public var streamID: HTTP2StreamID
        
        /// The error code associated with the closure.
        public var errorCode: HTTP2ErrorCode
        
        public init(streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode) {
            self.streamID = streamID
            self.errorCode = errorCode
        }
    }
    
    /// An protocol error defined by the HTTP/2 spec.
    public struct ProtocolError: NIOHTTP2Error
    {
        /// The associated HTTP/2 error code.
        public var errorCode: HTTP2ErrorCode
        
        public init(errorCode: HTTP2ErrorCode) {
            self.errorCode = errorCode
        }
    }
}
