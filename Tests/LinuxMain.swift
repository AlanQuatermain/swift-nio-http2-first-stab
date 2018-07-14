import XCTest

import swift_nio_http2Tests

var tests = [XCTestCaseEntry]()
tests += swift_nio_http2Tests.allTests()
XCTMain(tests)