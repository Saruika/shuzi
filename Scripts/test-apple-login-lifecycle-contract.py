#!/usr/bin/env python3
"""Local wiring guard; no Apple or production authentication requests."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
service = (root / "Yishu/Services/AppleSignInService.swift").read_text()
view = (root / "Yishu/Views/FanAccountView.swift").read_text()
phase = view.split(".onChange(of: scenePhase)", 1)[1].split(".onChange(of: account.isAuthenticated)", 1)[0]
assert "appleSignIn.scenePhaseDidChange(to: phase)" in phase
assert "appleSignIn.cancel()" not in phase
assert 'if phase == .background {' in phase
assert phase.index('if phase == .background {') < phase.index('clearAppleRegistrationFields()')
assert "needsAppleRegistrationRestore" in phase
completion = service.split("    func completeAuthorization(", 1)[1].split("extension AppleSignInCoordinator:", 1)[0]
assert completion.index("guard controller === self.controller else { return }") < completion.index("guard let challenge")
assert 'if phase == .background { cancel() }' in service
assert 'request.nonce = AppleSignInSecurity.sha256Hex(challenge.nonce)' in service
assert 'AppleSignInSecurity.statesMatch(credential.state, challenge.state)' in completion
print("apple-login-lifecycle: inactive preservation, background cancellation, stale callback isolation passed")
