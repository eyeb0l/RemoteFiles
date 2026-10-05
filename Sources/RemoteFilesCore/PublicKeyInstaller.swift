import Foundation
import Citadel
import NIOSSH

/// An immutable review of public material. No private key or password belongs in this value.
public struct PublicKeyInstallationRequest: Identifiable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let identityName: String
    public let publicKey: String
    public let fingerprint: String
    public var id: String { account + ":" + publicKey }
    public var account: String { "\(username)@\(host):\(port)" }

    public init(host: String, port: Int, username: String, identity: IdentityMetadata) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("/"), !host.contains("\0"), !username.isEmpty, username.utf8.count <= 256,
              !username.contains(where: { $0.isWhitespace || $0.isNewline }), !username.contains("\0"),
              (1...65535).contains(port) else { throw PublicKeyInstallationError.invalidTarget }
        guard identity.publicKey.utf8.count <= 8192, !identity.publicKey.contains(where: { $0.isNewline }),
              !identity.publicKey.contains("\0") else { throw PublicKeyInstallationError.invalidPublicKey }
        let fields = identity.publicKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "ssh-ed25519" else { throw PublicKeyInstallationError.invalidPublicKey }
        do {
            let details = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: fields.prefix(2).joined(separator: " ")))
            guard details.algorithm == "ssh-ed25519" else { throw PublicKeyInstallationError.invalidPublicKey }
            self.publicKey = details.publicKey; fingerprint = details.fingerprint
        } catch { throw PublicKeyInstallationError.invalidPublicKey }
        self.host = host; self.port = port; self.username = username; identityName = identity.name
    }
}

public enum PublicKeyInstallationResult: String, Sendable { case installed, alreadyInstalled }
public enum PublicKeyInstallationError: LocalizedError, Sendable {
    case invalidTarget, invalidPublicKey, busy, passwordRequired, passwordUnavailable, authenticationFailed
    case unsafeDestination, uncertainOutcome
    public var errorDescription: String? {
        switch self {
        case .invalidTarget: return "Enter a valid server address, account username and SSH port."
        case .invalidPublicKey: return "Choose a valid Ed25519 public identity. Private keys cannot be installed."
        case .busy: return "Another installation is in progress or left a lock. Wait and retry. If it persists, check the account’s key-install lock on the server."
        case .passwordRequired: return "Enter this server account’s password. It is used only for this installation."
        case .passwordUnavailable: return "This server does not offer SSH password authentication. Install the public key manually or choose a server that already supports password login."
        case .authenticationFailed: return "Password login failed. Check the account and password, then try again."
        case .unsafeDestination: return "The server’s SSH directory or authorized_keys file is not safe to update. No existing keys were removed. Check it on the server."
        case .uncertainOutcome: return "Installation could not be confirmed. The key may have been added. Retry to check safely; existing keys are preserved and duplicates are not added."
        }
    }
}

public protocol PublicKeyInstalling: Sendable {
    func install(_ request: PublicKeyInstallationRequest, password: String) async throws -> PublicKeyInstallationResult
    func cancelAll() async
}

/// Password auth is isolated from browsing and never saved to metadata or Keychain.
public actor SSHPublicKeyInstaller: PublicKeyInstalling {
    private let trust: HostTrustStore
    private let timeoutSeconds: UInt64
    private var active: (UUID, SocketControl)?
    public init(trust: HostTrustStore, timeoutSeconds: UInt64 = 30) {
        self.trust = trust; self.timeoutSeconds = max(1, timeoutSeconds)
    }
    public func install(_ request: PublicKeyInstallationRequest, password: String) async throws -> PublicKeyInstallationResult {
        try Task.checkCancellation()
        guard !password.isEmpty else { throw PublicKeyInstallationError.passwordRequired }
        guard active == nil else { throw PublicKeyInstallationError.busy }
        let token = UUID(), control = SocketControl()
        active = (token, control)
        defer { control.close(); if active?.0 == token { active = nil } }
        let trust = self.trust, timeout = timeoutSeconds
        do {
            let result = try await SFTPRemoteFileService.deadline(seconds: timeout, close: { control.close() }) {
                let authentication = SSHAuthenticationMethod.passwordBased(username: request.username, password: password, discoverMethods: true)
                var settings = SSHClientSettings(host: request.host, port: request.port,
                    authenticationMethod: { authentication },
                    hostKeyValidator: .custom(TrustValidator(store: trust, endpoint: .init(host: request.host, port: request.port))))
                settings.connectTimeout = .seconds(Int64(timeout))
                settings.onChannelCreated = { control.install($0) }
                let client = try await SSHClient.connect(to: settings)
                guard authentication.hasOfferedPassword else { throw SSHClientError.unsupportedPasswordAuthentication }
                try Task.checkCancellation()
                guard !control.isCancelled else { throw CancellationError() }
                let output = try await client.executeCommand(PublicKeyInstallCommand.command(request),
                    maxResponseSize: 4096, mergeStreams: false)
                try Task.checkCancellation()
                return try PublicKeyInstallCommand.result(String(buffer: output))
            }
            guard active?.0 == token, !control.isCancelled else { throw CancellationError() }
            return result
        } catch {
            if Task.isCancelled || control.isCancelled && active?.0 != token { throw CancellationError() }
            if error is HostTrustError { throw error }
            if let auth = error as? SSHClientError {
                switch auth {
                case .unsupportedPasswordAuthentication: throw PublicKeyInstallationError.passwordUnavailable
                case .allAuthenticationOptionsFailed: throw PublicKeyInstallationError.authenticationFailed
                default: break
                }
            }
            if let failed = error as? SSHClient.CommandFailed {
                if failed.exitCode == 70 { throw PublicKeyInstallationError.unsafeDestination }
                if failed.exitCode == 71 { throw PublicKeyInstallationError.busy }
            }
            throw PublicKeyInstallationError.uncertainOutcome
        }
    }
    public func cancelAll() { active?.1.close(); active = nil }
}

/// An append-only update under a cooperative lock. A lost reply is resolved by duplicate detection
/// on retry. No command contains account input, a password or private material.
enum PublicKeyInstallCommand {
    static func command(_ request: PublicKeyInstallationRequest) -> String {
        "sh -c " + quote(script) + " remotefiles " + quote(request.publicKey)
    }
    static func result(_ output: String) throws -> PublicKeyInstallationResult {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "REMOTEFILES_KEY_INSTALLED": return .installed
        case "REMOTEFILES_KEY_PRESENT": return .alreadyInstalled
        default: throw PublicKeyInstallationError.uncertainOutcome
        }
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static let script = #"""
    set -eu
    umask 077
    key=$1
    type=${key%% *}
    blob=${key#* }
    [ -n "${HOME:-}" ] && [ -d "$HOME" ] || exit 70
    sshdir="$HOME/.ssh"
    [ ! -L "$sshdir" ] || exit 70
    if [ ! -e "$sshdir" ]; then mkdir -m 700 "$sshdir" || exit 70; fi
    [ -d "$sshdir" ] || exit 70
    owner=$(id -u)
    [ "$(LC_ALL=C ls -nd "$sshdir" | awk '{print $3}')" = "$owner" ] || exit 70
    mode=$(LC_ALL=C ls -ld "$sshdir" | awk '{print $1}')
    case "$mode" in d????w*|d???????w*) exit 70;; esac
    lock="$sshdir/.remotefiles-key-install.lock"
    mkdir "$lock" 2>/dev/null || exit 71
    trap 'rmdir "$lock" 2>/dev/null || :' EXIT
    trap 'exit 72' HUP INT TERM
    file="$sshdir/authorized_keys"
    [ ! -L "$file" ] || exit 70
    if [ -e "$file" ]; then
      [ -f "$file" ] || exit 70
      [ "$(LC_ALL=C ls -nd "$file" | awk '{print $3}')" = "$owner" ] || exit 70
      [ "$(LC_ALL=C ls -nd "$file" | awk '{print $2}')" = 1 ] || exit 70
      mode=$(LC_ALL=C ls -ld "$file" | awk '{print $1}')
      case "$mode" in ?????w*|????????w*) exit 70;; esac
    fi
    present() {
      [ -f "$file" ] && awk -v type="$type" -v blob="$blob" '
        /^[[:space:]]*#/ { next }
        {
          n=0; word=""; quoted=0; escaped=0
          for (i=1; i<=length($0); i++) {
            ch=substr($0,i,1)
            if (escaped) { word=word ch; escaped=0; continue }
            if (ch=="\\") { word=word ch; escaped=1; continue }
            if (ch=="\"") { word=word ch; quoted=!quoted; continue }
            if (ch ~ /[[:space:]]/ && !quoted) {
              if (length(word)) { field[++n]=word; word="" }
            } else word=word ch
          }
          if (length(word)) field[++n]=word
          first=(field[1]==type ? 1 : 2)
          if (n>=first+1 && field[first]==type && field[first+1]==blob) found=1
        }
        END { exit !found }' "$file"
    }
    if present; then printf '%s\n' REMOTEFILES_KEY_PRESENT; exit 0; fi
    exec 9>>"$file" || exit 72
    if [ -s "$file" ]; then printf '\n%s\n' "$key" >&9 || exit 72
    else printf '%s\n' "$key" >&9 || exit 72; fi
    exec 9>&-
    present || exit 72
    printf '%s\n' REMOTEFILES_KEY_INSTALLED
    """#
}
