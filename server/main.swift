// bob-local-ocr: 常驻的本地 OCR 服务，供 Bob 插件通过 HTTP 调用。
// 只监听 127.0.0.1，使用系统 Vision 框架识别文字。
//
// POST /ocr     {"image": "<base64>", "languages": ["zh-Hans", "en-US"], "autoDetect": true}
//            -> {"texts": [{"text": "...", "box": {"x":0,"y":0,"w":1,"h":1}}], "elapsedMs": 123}
// GET  /health  -> {"ok": true}

import AppKit
import Foundation
import Network
import Vision

let port = NWEndpoint.Port(rawValue: UInt16(ProcessInfo.processInfo.environment["BOB_OCR_PORT"] ?? "") ?? 50888)!
let maxBodyBytes = 50 * 1024 * 1024
let workQueue = DispatchQueue(label: "bob-local-ocr.vision", qos: .userInitiated, attributes: .concurrent)

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
}

// MARK: - OCR

struct OCRLine: Encodable {
    struct Box: Encodable { let x, y, w, h: Double }
    let text: String
    let box: Box
}

struct OCRResponse: Encodable {
    let texts: [OCRLine]
    let elapsedMs: Int
}

struct OCRRequestBody: Decodable {
    let image: String
    let languages: [String]?
    let autoDetect: Bool?
}

enum OCRError: Error, CustomStringConvertible {
    case badImage
    case modelCacheGone
    case vision(Error)

    var description: String {
        switch self {
        case .badImage: return "无法解码图片"
        case .modelCacheGone: return "OCR 模型缓存被系统清理了（通常是磁盘空间不足），服务正在重建模型，请 1~2 分钟后重试"
        case .vision(let e): return "Vision 识别失败: \(e)"
        }
    }
}

func recognize(cgImage: CGImage, languages: [String], autoDetect: Bool) throws -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if !languages.isEmpty {
        request.recognitionLanguages = languages
    }
    request.automaticallyDetectsLanguage = autoDetect

    do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
    } catch {
        // 磁盘空间不足时，系统（deleted 守护进程）会清掉 E5 模型编译缓存。已经加载过模型的进程
        // 之后会一直报 e5rtError(..., 13)，不会自动重新编译，只能重启进程。
        if "\(error)".contains("e5rtError") { throw OCRError.modelCacheGone }
        throw OCRError.vision(error)
    }

    // Vision 的坐标原点在左下角，这里转换成左上角原点，方便插件直接使用。
    return (request.results ?? []).compactMap { obs in
        guard let text = obs.topCandidates(1).first?.string else { return nil }
        let b = obs.boundingBox
        return OCRLine(text: text, box: .init(x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height))
    }
}

func decodeImage(base64: String) -> CGImage? {
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
          let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// Vision 按文字体系使用不同的识别模型，每个模型第一次使用时都要在 ANE 上编译（约 20~30 秒），
// 编译结果缓存在 ~/Library/Caches/bob-local-ocr，直到系统升级才失效。
// 启动时逐个文字体系识别一遍，保证真正截图时模型都已编译好。
let prewarmSamples: [(text: String, languages: [String])] = [
    ("Bob 预热 Hello World", ["zh-Hans", "en-US"]),
    ("Only English text here", ["en-US", "zh-Hans"]),
    ("日本語のテキスト 한국어", ["ja-JP", "ko-KR"]),
    ("Привет мир สวัสดี", ["ru-RU", "th-TH"]),
    ("مرحبا بالعالم", ["ar-SA", "en-US"]),
    ("नमस्ते दुनिया", ["hi-IN", "en-US"]),
]

func renderSample(_ text: String) -> CGImage? {
    let width = 480, height = 80
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
        .draw(at: NSPoint(x: 10, y: 20))
    NSGraphicsContext.current = nil
    return ctx.makeImage()
}

func prewarm() {
    let total = Date()
    for sample in prewarmSamples {
        guard let cg = renderSample(sample.text) else { continue }
        let start = Date()
        _ = try? recognize(cgImage: cg, languages: sample.languages, autoDetect: true)
        log("预热 \(sample.languages.first ?? "")，耗时 \(Int(Date().timeIntervalSince(start) * 1000))ms")
    }
    log("预热完成，总耗时 \(Int(Date().timeIntervalSince(total) * 1000))ms")
    watchModelCache()
}

// MARK: - 模型缓存自愈

/// Vision 把编译好的模型缓存在 ~/Library/Caches/<进程名>/com.apple.e5rt.e5bundlecache。
let modelCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(ProcessInfo.processInfo.processName)
    .appendingPathComponent("com.apple.e5rt.e5bundlecache")

func modelCacheFileCount() -> Int {
    let enumerator = FileManager.default.enumerator(
        at: modelCacheDir, includingPropertiesForKeys: [.isRegularFileKey]
    )
    var count = 0
    while let url = enumerator?.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
    }
    return count
}

/// 退出进程，由 launchd（KeepAlive）重新拉起，重新启动后的预热会重建模型。
/// 稍等一下再退出，让正在发送的响应先发出去。
func restartForRebuild(reason: String) {
    log("\(reason)，重启服务以重建模型")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(75) }
}

var modelCacheTimer: DispatchSourceTimer?

/// 每分钟检查一次缓存文件数，发现被系统清理后主动重启，赶在用户下一次截图之前把模型重新编译好。
func watchModelCache() {
    let baseline = modelCacheFileCount()
    log("模型缓存文件数: \(baseline)")
    guard baseline > 0 else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 60, repeating: 60)
    timer.setEventHandler {
        let current = modelCacheFileCount()
        if current < baseline {
            timer.cancel()
            restartForRebuild(reason: "模型缓存被系统清理（文件数 \(baseline) -> \(current)）")
        }
    }
    timer.resume()
    modelCacheTimer = timer
}

// MARK: - HTTP

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}

/// 尝试从缓冲区解析出一个完整的 HTTP 请求；数据不完整时返回 nil。
func parseRequest(_ buffer: Data) throws -> HTTPRequest? {
    guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        if buffer.count > 64 * 1024 { throw URLError(.badServerResponse) }
        return nil
    }
    let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
    let lines = headerText.components(separatedBy: "\r\n")
    let parts = lines.first?.split(separator: " ") ?? []
    guard parts.count >= 2 else { throw URLError(.badServerResponse) }

    var contentLength = 0
    for line in lines.dropFirst() {
        let kv = line.split(separator: ":", maxSplits: 1)
        if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
            contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    guard contentLength <= maxBodyBytes else { throw URLError(.dataLengthExceedsMaximum) }

    let bodyStart = headerEnd.upperBound
    guard buffer.count - bodyStart >= contentLength else { return nil }
    let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
    return HTTPRequest(method: String(parts[0]), path: String(parts[1]), body: body)
}

func send(_ connection: NWConnection, status: Int, json: Data) {
    let reason = [
        200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error", 503: "Service Unavailable",
    ][status] ?? "Error"
    var response = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
    response.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
    response.append(Data("Content-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8))
    response.append(json)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
}

func sendError(_ connection: NWConnection, status: Int, _ message: String) {
    let json = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
    send(connection, status: status, json: json)
}

func handle(_ request: HTTPRequest, on connection: NWConnection) {
    switch (request.method, request.path) {
    case ("GET", "/health"):
        send(connection, status: 200, json: Data(#"{"ok":true}"#.utf8))

    case ("POST", "/ocr"):
        workQueue.async {
            let start = Date()
            do {
                let body = try JSONDecoder().decode(OCRRequestBody.self, from: request.body)
                guard let cgImage = decodeImage(base64: body.image) else { throw OCRError.badImage }
                let lines = try recognize(
                    cgImage: cgImage,
                    languages: body.languages ?? [],
                    autoDetect: body.autoDetect ?? true
                )
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                log("识别 \(cgImage.width)x\(cgImage.height) -> \(lines.count) 行，耗时 \(elapsed)ms")
                send(connection, status: 200, json: try JSONEncoder().encode(OCRResponse(texts: lines, elapsedMs: elapsed)))
            } catch OCRError.modelCacheGone {
                sendError(connection, status: 503, OCRError.modelCacheGone.description)
                restartForRebuild(reason: "识别时发现模型缓存已失效")
            } catch let error as OCRError {
                log("识别失败: \(error)")
                sendError(connection, status: 500, error.description)
            } catch {
                log("请求无效: \(error)")
                sendError(connection, status: 400, "请求格式错误: \(error)")
            }
        }

    default:
        sendError(connection, status: 404, "not found")
    }
}

func receive(on connection: NWConnection, buffer: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { chunk, _, isComplete, error in
        var buffer = buffer
        if let chunk { buffer.append(chunk) }
        do {
            if let request = try parseRequest(buffer) {
                handle(request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        } catch {
            sendError(connection, status: 400, "bad request")
        }
    }
}

// MARK: - main

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
parameters.allowLocalEndpointReuse = true

let listener = try NWListener(using: parameters)
listener.newConnectionHandler = { connection in
    connection.start(queue: .global(qos: .userInitiated))
    receive(on: connection)
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log("监听 127.0.0.1:\(port)")
    case .failed(let error):
        log("监听失败: \(error)")
        exit(1)
    default: break
    }
}
listener.start(queue: .main)
workQueue.async { prewarm() }
dispatchMain()
