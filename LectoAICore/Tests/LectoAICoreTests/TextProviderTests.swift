import Foundation
import XCTest
@testable import LectoAICore

@MainActor
final class TextProviderTests: XCTestCase {
    // 本机临时服务验证 HTTP/SSE 边界；不访问付费服务、不使用真实密钥。
    private func server(complete: Bool) throws -> (Process, Int) {
        let script = """
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import json
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if self.path != '/v1/chat/completions' or self.headers.get('Authorization') != 'Bearer test-only' or body.get('stream') != True:
                    self.send_error(400); return
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"Hello"}}]}\\n\\n')
                if \(complete ? "True" : "False"):
                    self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\\n\\ndata: [DONE]\\n\\n')
                self.wfile.flush()
        server = HTTPServer(('127.0.0.1', 0), Handler)
        server.timeout = 15
        print(server.server_port, flush=True)
        server.handle_request()
        """
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]; process.standardOutput = output
        try process.run()
        var data = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 { break }; data.append(byte)
        }
        guard let port = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw LessonError.api("测试服务启动失败")
        }
        return (process, port)
    }

    func testCompleteStream() async throws {
        let (server, port) = try server(complete: true)
        defer { if server.isRunning { server.terminate() } }
        let provider = TextProvider(profile: .init(endpoint: "http://127.0.0.1:\(port)/v1", model: "test"), apiKey: "test-only")
        let response = try await provider.stream(system: "test", user: "test") { _ in }
        XCTAssertEqual(response, "Hello")
    }

    func testTruncatedStreamIsNotACompletedAnswer() async throws {
        let (server, port) = try server(complete: false)
        defer { if server.isRunning { server.terminate() } }
        let provider = TextProvider(profile: .init(endpoint: "http://127.0.0.1:\(port)/v1", model: "test"), apiKey: "test-only")
        do {
            _ = try await provider.stream(system: "test", user: "test") { _ in }
            XCTFail("截断回答不应被当作成功")
        } catch { XCTAssertTrue(error.localizedDescription.contains("中断")) }
    }
}
