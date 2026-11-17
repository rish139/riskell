// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Foundation

/// The one way the usage providers reach the network: GET over https to two named hosts, a short timeout, no cookies stored or sent
/// by the session, no URL cache, and a redirect followed only to the same host. A session lives for one request.
enum UsageHTTP {
    static let allowedHosts: Set<String> = ["api.anthropic.com", "opencode.ai"]

    /// Calls `done` with the HTTP status and body; the status is nil when the request was refused or failed.
    static func get(_ req: URLRequest, timeout: TimeInterval, done: @escaping (Int?, Data?) -> Void) {
        guard let url = req.url, url.scheme == "https", let host = url.host, allowedHosts.contains(host) else { done(nil, nil); return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.urlCredentialStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg, delegate: SameHostRedirects(), delegateQueue: nil)
        var r = req
        r.timeoutInterval = timeout
        r.httpShouldHandleCookies = false
        session.dataTask(with: r) { data, resp, _ in
            session.finishTasksAndInvalidate()
            done((resp as? HTTPURLResponse)?.statusCode, data)
        }.resume()
    }
}

/// A redirect is followed only when it stays on https and on the same host as the request; anything else ends the request.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url, to = request.url
        let ok = to?.scheme == "https" && to?.host != nil && to?.host == from?.host
        completionHandler(ok ? request : nil)
    }
}
