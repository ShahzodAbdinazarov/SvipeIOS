import Foundation
import CommonCrypto
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

/// The store reviewer's way in, the same as Svipe for Android (org.telegram.svipe.SvipeDemoLogin):
/// the demo number with a fixed code instead of the one Telegram sends.
///
/// The number lives on our server (svipe-backend app/api/demo_login.py) and the app only gets a slow
/// hash of it, so no other number is ever sent anywhere: on the code screen the number being signed in
/// is hashed and the server is asked only when it matches. The server checks the typed code, reads the
/// real one out of the account and hands it back; for two-step verification it computes the SRP proof
/// itself, so the password never reaches the device. The session this creates is closed by the server
/// an hour later.
public enum SvipeDemoLogin {
    private static let base = URL(string: "https://svipe.uz/v1/auth/demo")!
    private static let lock = NSLock()
    private static var config: [String: Any]?
    private static var phone: String?
    private static var code: String?

    /// True right after `exchange` handed out the real code, until the sign-in finishes.
    public static var isActive: Bool {
        return locked { phone != nil }
    }

    public static func reset() {
        locked {
            phone = nil
            code = nil
        }
    }

    /// The code to send to Telegram: the real one when `number` is the demo number and `typed` is our
    /// code, otherwise `typed` unchanged. Never fails loudly. Calls back on the main queue.
    public static func exchange(number: String, typed: String, deviceModel: String, completion: @escaping (String) -> Void) {
        let done: (String?) -> Void = { real in
            Queue.mainQueue().async { completion(real ?? typed) }
        }
        let digits = Self.digits(number)
        loadConfig { config in
            guard let config, config["enabled"] as? Bool == true, matches(digits, config: config) else {
                reset()
                done(nil)
                return
            }
            post("code", ["phone": digits, "code": typed, "device_model": deviceModel]) { result in
                guard let real = result?["code"] as? String, !real.isEmpty else {
                    reset()
                    done(nil)
                    return
                }
                locked {
                    phone = digits
                    code = typed
                }
                done(real)
            }
        }
    }

    /// The two-step verification proof from our server, as (srp_id, A, M1); nil when it can't be had.
    static func proof(_ authData: TwoStepAuthData) -> Signal<(Int64, Data, Data)?, NoError> {
        return Signal { subscriber in
            let state: (String?, String?) = locked { (phone, code) }
            guard let phone = state.0, let code = state.1,
                  let srp = authData.srpSessionData,
                  case let .sha256_sha256_PBKDF2_HMAC_sha512_sha256_srp(salt1, salt2, _, g, p)? = authData.currentPasswordDerivation else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            post("password", [
                "phone": phone, "code": code, "srp_id": srp.id,
                "srp_B": srp.B.base64EncodedString(), "salt1": salt1.base64EncodedString(),
                "salt2": salt2.base64EncodedString(), "g": g, "p": p.base64EncodedString(),
            ]) { result in
                if let result, let id = (result["srp_id"] as? NSNumber)?.int64Value,
                   let a = (result["A"] as? String).flatMap({ Data(base64Encoded: $0) }),
                   let m1 = (result["M1"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                    subscriber.putNext((id, a, m1))
                } else {
                    subscriber.putNext(nil)
                }
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    private static func loadConfig(_ completion: @escaping ([String: Any]?) -> Void) {
        if let cached = locked({ config }) {
            completion(cached)
            return
        }
        request(URLRequest(url: base.appendingPathComponent("config"))) { result in
            if let result {
                locked { config = result }
            }
            completion(result)
        }
    }

    private static func post(_ path: String, _ body: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request(req, completion: completion)
    }

    private static func request(_ req: URLRequest, completion: @escaping ([String: Any]?) -> Void) {
        var req = req
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }

    private static func matches(_ digits: String, config: [String: Any]) -> Bool {
        guard let salt = config["salt"] as? String, let hash = config["hash"] as? String,
              let iterations = (config["iterations"] as? NSNumber)?.uint32Value, iterations > 0 else {
            return false
        }
        var out = [UInt8](repeating: 0, count: 32)
        let password = Array(digits.utf8)
        let saltBytes = Array(salt.utf8)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, pw.count,
                                 saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        }
        guard status == kCCSuccess else {
            return false
        }
        return out.map { String(format: "%02x", $0) }.joined() == hash.lowercased()
    }

    private static func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    private static func digits(_ number: String) -> String {
        return number.filter { $0.isASCII && $0.isNumber }
    }
}

/// Signs in to the demo account's two-step verification with the proof from our server.
public func svipeAuthorizeWithDemoProof(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, syncContacts: Bool) -> Signal<Void, AuthorizationPasswordVerificationError> {
    let check: Signal<Api.auth.Authorization, MTRpcError> = _internal_twoStepAuthData(account.network)
    |> mapToSignal { authData -> Signal<Api.auth.Authorization, MTRpcError> in
        return SvipeDemoLogin.proof(authData)
        |> castError(MTRpcError.self)
        |> mapToSignal { proof -> Signal<Api.auth.Authorization, MTRpcError> in
            guard let (id, a, m1) = proof else {
                return .fail(MTRpcError(errorCode: 400, errorDescription: "SVIPE_DEMO_NO_PROOF"))
            }
            return account.network.request(Api.functions.auth.checkPassword(password: .inputCheckPasswordSRP(.init(srpId: id, A: Buffer(data: a), M1: Buffer(data: m1)))), automaticFloodWait: false)
        }
    }
    return authorizeWithPasswordCheck(accountManager: accountManager, account: account, check: check, syncContacts: syncContacts)
    |> afterDisposed {
        SvipeDemoLogin.reset()
    }
}
