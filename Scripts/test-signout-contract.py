#!/usr/bin/env python3
"""Verify logout wiring locally; never read host sources from an iOS process."""
from pathlib import Path


def section(source: str, begin: str, end: str) -> str:
    return source.split(begin, 1)[1].split(end, 1)[0]


root = Path(__file__).resolve().parents[1]
source = (root / "Yishu/Services/FanAccountStore.swift").read_text()
signout = section(source, "    func signOut() async {", "    func deleteAccount(currentPassword:")
assert "let authorizationToken = token" in signout
assert "FanSignOutOperation.begin(" in signout
assert "authorizationToken: request.authorizationToken" in signout
assert signout.index("clearLocalSession()") < signout.index("await ")
assert "FanAccountOperationGuard" not in signout
assert "clearLocalSession" not in signout.split("await operation.complete", 1)[1]
assert "errorMessage =" not in signout.split("await operation.complete", 1)[1]
assert "noticeMessage =" not in signout.split("await operation.complete", 1)[1]

perform = section(source, "    private func perform<T: Decodable>(", "    private func decodeError(")
assert "clearLocalSession(" not in perform
assert "authorizationToken ?? token" in perform

clear = section(source, "    private func clearLocalSession() {", "    private func scheduleAppleCredentialRetry()")
assert "refreshGeneration &+= 1" in clear
assert "pushSessionGeneration &+= 1" in clear
assert "token = nil" in clear and "profile = nil" in clear
assert "didSet { notificationStore.updateContext(notificationContext) }" in source

begin = section(source, "    static func begin(", "    func complete(using send:")
assert "await " not in begin
assert begin.index("clearLocalState()") < begin.index("return FanSignOutOperation")
complete = section(source, "    func complete(using send:", "enum FanAppleRegistrationCompletionPolicy")
assert "try? await send(request)" in complete
assert "clearLocalState" not in complete
print("signout-contract: synchronous clear, immutable credentials, late-response isolation passed")
