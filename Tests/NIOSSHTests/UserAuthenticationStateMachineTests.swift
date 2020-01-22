//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import XCTest
import NIO
import CryptoKit
@testable import NIOSSH


/// An authentication delegate that yields passwords forever.
final class InfinitePasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationRequest?>) {
        let request = NIOSSHUserAuthenticationRequest(username: "foo", serviceName: "", request: .password(.init(password: "bar")))
        nextChallengePromise.succeed(request)
    }
}

/// An authentication delegate that denies some number of requests and then accepts exactly one and fails the rest.
final class DenyThenAcceptDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .all

    private var messagesToDeny: Int

    init(messagesToDeny: Int) {
        self.messagesToDeny = messagesToDeny
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        let messages = self.messagesToDeny
        self.messagesToDeny -= 1

        switch messages {
        case 0:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}


final class UserAuthenticationStateMachineTests: XCTestCase {
    var loop: EmbeddedEventLoop!
    var hostKey: NIOSSHHostPrivateKey!

    override func setUp() {
        self.loop = EmbeddedEventLoop()
        self.hostKey = NIOSSHHostPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    }

    override func tearDown() {
        try! self.loop.syncShutdownGracefully()
        self.loop = nil
        self.hostKey = nil
    }

    func beginAuthentication(expecting expectedMessage: SSHMessage.UserAuthRequestMessage?, stateMachine: inout UserAuthenticationStateMachine) {
        var request: SSHMessage.UserAuthRequestMessage?

        stateMachine.beginAuthentication().whenComplete {
            switch $0 {
            case .success(let message):
                request = message
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
        }
        self.loop.run()

        XCTAssertEqual(request, expectedMessage)
    }

    func authFailed(failure: SSHMessage.UserAuthFailureMessage, nextMessage expectedMessage: SSHMessage.UserAuthRequestMessage?, stateMachine: inout UserAuthenticationStateMachine) throws {
        var request: SSHMessage.UserAuthRequestMessage?

        let future = try assertNoThrowWithValue(stateMachine.receiveUserAuthFailure(failure))
        XCTAssertNotNil(future)
        future?.whenComplete {
            switch $0 {
            case .success(let message):
                request = message
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
        }
        self.loop.run()

        XCTAssertEqual(request, expectedMessage)
    }

    func expectAuthRequestToFailSynchronously(request: SSHMessage.UserAuthRequestMessage, expecting result: SSHMessage.UserAuthFailureMessage, stateMachine: inout UserAuthenticationStateMachine) throws {
        var message: SSHMessage.UserAuthFailureMessage?

        let future = try assertNoThrowWithValue(try stateMachine.receiveUserAuthRequest(request))
        XCTAssertNotNil(future)
        future?.whenComplete {
            switch $0 {
            case .success(.failure(let response)):
                message = response
            case .success(.success):
                XCTFail("Unexpected success")
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
        }
        self.loop.run()

        XCTAssertEqual(message, result)
    }

    func expectAuthRequestToSucceedSynchronously(request: SSHMessage.UserAuthRequestMessage, stateMachine: inout UserAuthenticationStateMachine) throws {
        var completed = false

        let future = try assertNoThrowWithValue(try stateMachine.receiveUserAuthRequest(request))
        XCTAssertNotNil(future)
        future?.whenComplete {
            switch $0 {
            case .success(.success):
                completed = true
            case .success(.failure):
                XCTFail("Unexpected failure")
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
        }
        self.loop.run()

        XCTAssertTrue(completed)
    }

    func testBasicHappyClientFlow() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        let firstMessage = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        self.beginAuthentication(expecting: firstMessage, stateMachine: &stateMachine)
        stateMachine.sendUserAuthRequest(firstMessage)

        // Let's say we got a success. Happy path!
        XCTAssertNoThrow(try stateMachine.receiveUserAuthSuccess())
    }

    func testBasicSadClientFlow() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        let firstMessage = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        self.beginAuthentication(expecting: firstMessage, stateMachine: &stateMachine)
        stateMachine.sendUserAuthRequest(firstMessage)

        // Oh no, a failure!
        let failure = SSHMessage.UserAuthFailureMessage(authentications: ["password"], partialSuccess: false)
        try self.authFailed(failure: failure, nextMessage: nil, stateMachine: &stateMachine)

        // We're done.
        stateMachine.noFurtherMethods()
    }

    func testBasicSadThenHappyClientFlow() throws {
        let delegate = InfinitePasswordDelegate()
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        let firstMessage = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        self.beginAuthentication(expecting: firstMessage, stateMachine: &stateMachine)
        stateMachine.sendUserAuthRequest(firstMessage)

        // Oh no, a failure! We'll try again.
        let failure = SSHMessage.UserAuthFailureMessage(authentications: ["password"], partialSuccess: false)
        try self.authFailed(failure: failure, nextMessage: firstMessage, stateMachine: &stateMachine)
        stateMachine.sendUserAuthRequest(firstMessage)

        // Let's say we got a success. Happy path!
        XCTAssertNoThrow(try stateMachine.receiveUserAuthSuccess())
    }

    func testAuthMessagesAfterSuccessAreIgnored() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        let firstMessage = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        self.beginAuthentication(expecting: firstMessage, stateMachine: &stateMachine)
        stateMachine.sendUserAuthRequest(firstMessage)

        // Let's say we got a success. Happy path!
        XCTAssertNoThrow(try stateMachine.receiveUserAuthSuccess())

        // Ok, the following two messages should be ignored.
        XCTAssertNoThrow(try stateMachine.receiveUserAuthSuccess())
        XCTAssertNoThrow(try stateMachine.receiveUserAuthFailure(.init(authentications: ["password"], partialSuccess: false)))
    }

    func testUnsolicitedResponseBeforeInitIsInvalid() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        XCTAssertThrowsError(try stateMachine.receiveUserAuthSuccess()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
        XCTAssertThrowsError(try stateMachine.receiveUserAuthFailure(.init(authentications: ["password"], partialSuccess: false))) { error in
           XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testUnsolicitedResponseAfterInitBeforeSendingIsInvalid() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        // Let's request the first message but not deliver it.
        _ = stateMachine.beginAuthentication()

        XCTAssertThrowsError(try stateMachine.receiveUserAuthSuccess()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
        XCTAssertThrowsError(try stateMachine.receiveUserAuthFailure(.init(authentications: ["password"], partialSuccess: false))) { error in
           XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testUnsolicitedResponseAfterFailureBeforeNextRequestIsInvalid() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        let firstMessage = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        self.beginAuthentication(expecting: firstMessage, stateMachine: &stateMachine)
        stateMachine.sendUserAuthRequest(firstMessage)

        // Oh no, a failure!
        let failure = SSHMessage.UserAuthFailureMessage(authentications: ["password"], partialSuccess: false)
        try self.authFailed(failure: failure, nextMessage: nil, stateMachine: &stateMachine)

        // Don't tell the state machine that there are no more records, deliver the responses now.
        XCTAssertThrowsError(try stateMachine.receiveUserAuthSuccess()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
        XCTAssertThrowsError(try stateMachine.receiveUserAuthFailure(.init(authentications: ["password"], partialSuccess: false))) { error in
           XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testUnsolicitedResponseAfterCompleteFailureIsInvalid() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)

        let firstMessage = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        self.beginAuthentication(expecting: firstMessage, stateMachine: &stateMachine)
        stateMachine.sendUserAuthRequest(firstMessage)

        // Oh no, a failure!
        let failure = SSHMessage.UserAuthFailureMessage(authentications: ["password"], partialSuccess: false)
        try self.authFailed(failure: failure, nextMessage: nil, stateMachine: &stateMachine)

        // Tell the state machine we've truly failed.
        stateMachine.noFurtherMethods()

        // These responses are invalid.
        XCTAssertThrowsError(try stateMachine.receiveUserAuthSuccess()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
        XCTAssertThrowsError(try stateMachine.receiveUserAuthFailure(.init(authentications: ["password"], partialSuccess: false))) { error in
           XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testServersMayNotReceiveUserAuthSuccessMessages() throws {
        var stateMachine = UserAuthenticationStateMachine(role: .server(self.hostKey), clientDelegate: nil, serverDelegate: DenyAllServerAuthDelegate(), loop: self.loop)

        // Deliver a user auth success message
        XCTAssertThrowsError(try stateMachine.receiveUserAuthSuccess()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testServersMayNotReceiveUserAuthFailureMessages() throws {
        var stateMachine = UserAuthenticationStateMachine(role: .server(self.hostKey), clientDelegate: nil, serverDelegate: DenyAllServerAuthDelegate(), loop: self.loop)

        // Deliver a user auth failure message
        let message = SSHMessage.UserAuthFailureMessage(authentications: [], partialSuccess: false)
        XCTAssertThrowsError(try stateMachine.receiveUserAuthFailure(message)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testBasicServerRejections() throws {
        var stateMachine = UserAuthenticationStateMachine(role: .server(self.hostKey), clientDelegate: nil, serverDelegate: DenyAllServerAuthDelegate(), loop: self.loop)

        // User asks a question, it fails.
        let authRequest = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        let failure = SSHMessage.UserAuthFailureMessage(authentications: ["password", "publickey", "hostbased"], partialSuccess: false)
        try expectAuthRequestToFailSynchronously(request: authRequest, expecting: failure, stateMachine: &stateMachine)
        stateMachine.sendUserAuthFailure(failure)

        // User asks again, fails again.
        try expectAuthRequestToFailSynchronously(request: authRequest, expecting: failure, stateMachine: &stateMachine)
        stateMachine.sendUserAuthFailure(failure)
    }

    func testManyAuthRequestsInFlightAtOnce() throws {
        var stateMachine = UserAuthenticationStateMachine(role: .server(self.hostKey), clientDelegate: nil, serverDelegate: DenyAllServerAuthDelegate(), loop: self.loop)

        // The user can ask many questions in parallel.
        let authRequest = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        let failure = SSHMessage.UserAuthFailureMessage(authentications: ["password", "publickey", "hostbased"], partialSuccess: false)

        for _ in 0..<10 {
            try expectAuthRequestToFailSynchronously(request: authRequest, expecting: failure, stateMachine: &stateMachine)
        }
        for _ in 0..<10 {
            stateMachine.sendUserAuthFailure(failure)
        }
    }

    func testSimpleServerHappyPath() throws {
        var stateMachine = UserAuthenticationStateMachine(role: .server(self.hostKey), clientDelegate: nil, serverDelegate: DenyThenAcceptDelegate(messagesToDeny: 0), loop: self.loop)

        // We get a request.
        let authRequest = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        try expectAuthRequestToSucceedSynchronously(request: authRequest, stateMachine: &stateMachine)
        stateMachine.sendUserAuthSuccess()
    }

    func testServerIgnoresMessagesAfterSuccess() throws {
        var stateMachine = UserAuthenticationStateMachine(role: .server(self.hostKey), clientDelegate: nil, serverDelegate: DenyThenAcceptDelegate(messagesToDeny: 0), loop: self.loop)

        // We get a request, which succeeds.
        let authRequest = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))
        try expectAuthRequestToSucceedSynchronously(request: authRequest, stateMachine: &stateMachine)
        stateMachine.sendUserAuthSuccess()

        // Let's try getting another request. This will be ignored.
        let future = try assertNoThrowWithValue(stateMachine.receiveUserAuthRequest(authRequest))
        XCTAssertNil(future)
    }

    func testClientRejectsUserAuthRequests() throws {
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        var stateMachine = UserAuthenticationStateMachine(role: .client, clientDelegate: delegate, serverDelegate: nil, loop: self.loop)
        let authRequest = SSHMessage.UserAuthRequestMessage(username: "foo", service: "", method: .password("bar"))

        XCTAssertThrowsError(try stateMachine.receiveUserAuthRequest(authRequest)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testSimplePasswordDelegateOnlyTriesPassword() throws {
        // This branch isn't really reachable in the current code, but we should verify SimplePasswordDelegate only likes
        // passwords!
        let delegate = SimplePasswordDelegate(username: "foo", password: "bar")
        let challengePromise = self.loop.makePromise(of: NIOSSHUserAuthenticationRequest?.self)
        delegate.nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods.all.subtracting(.password),
                                        nextChallengePromise: challengePromise)
        self.loop.run()

        let result = try assertNoThrowWithValue(challengePromise.futureResult.wait())
        XCTAssertNil(result)
    }
}
