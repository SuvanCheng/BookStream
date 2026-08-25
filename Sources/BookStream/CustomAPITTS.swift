import Foundation
import AVFoundation

/// 自定义云端/本地大模型 API 配置（支持 OpenAI tts-1-hd, ElevenLabs, Fish-Speech, LocalAI 等）。
public struct CustomAPISettings: Sendable, Codable, Equatable {
    public enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
        case openAI     = "openAI"     // OpenAI (tts-1-hd, alloy/echo/fable/onyx/nova/shimmer)
        case elevenLabs = "elevenLabs" // ElevenLabs (eleven_multilingual_v2, 任意 Voice ID)
        case custom     = "custom"     // 自建本地/私有 API (OpenAI 兼容端点)

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .openAI: return "OpenAI TTS (tts-1-hd)"
            case .elevenLabs: return "ElevenLabs (顶级大模型)"
            case .custom: return "自定义兼容 API (Ollama/本地GPU)"
            }
        }
    }

    public var provider: Provider
    public var apiKey: String
    public var endpointURL: String
    public var model: String
    public var voice: String

    public init(
        provider: Provider = .openAI,
        apiKey: String = "",
        endpointURL: String = "https://api.openai.com/v1/audio/speech",
        model: String = "tts-1-hd",
        voice: String = "onyx"
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.endpointURL = endpointURL
        self.model = model
        self.voice = voice
    }

    public static let `default` = CustomAPISettings()

    public mutating func applyPreset(for p: Provider) {
        self.provider = p
        switch p {
        case .openAI:
            if endpointURL.isEmpty || endpointURL.contains("elevenlabs") || endpointURL.contains("localhost") {
                endpointURL = "https://api.openai.com/v1/audio/speech"
            }
            if model.isEmpty || model.contains("eleven") {
                model = "tts-1-hd"
            }
            if voice.isEmpty || voice.count > 15 {
                voice = "onyx"
            }
        case .elevenLabs:
            if endpointURL.isEmpty || endpointURL.contains("openai.com") || endpointURL.contains("localhost") {
                endpointURL = "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM"
            }
            model = "eleven_multilingual_v2"
            if voice.isEmpty || voice == "onyx" || voice == "tts-1-hd" {
                voice = "21m00Tcm4TlvDq8ikWAM"
            }
        case .custom:
            if endpointURL.isEmpty || endpointURL.contains("openai.com") || endpointURL.contains("elevenlabs") {
                endpointURL = "http://localhost:8000/v1/audio/speech"
            }
            if model.isEmpty || model == "eleven_multilingual_v2" {
                model = "tts-1"
            }
            if voice.isEmpty || voice.count > 15 {
                voice = "default"
            }
        }
    }
}

public final class CustomAPITTS: @unchecked Sendable {

    public static let shared = CustomAPITTS()

    public init() {}

    /// 同步渲染单句音频（通过 URLSession 请求并转换格式）
    public func render(
        text: String,
        settings: CustomAPISettings,
        rate: Float,
        cancellation: (@Sendable () -> Bool)? = nil
    ) throws -> [AVAudioPCMBuffer] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        if cancellation?() == true { throw BookStreamError.cancelled }

        guard let url = URL(string: settings.endpointURL.isEmpty ? "https://api.openai.com/v1/audio/speech" : settings.endpointURL) else {
            throw BookStreamError.audioRenderFailed("无效的 API Endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        if !settings.apiKey.isEmpty {
            if settings.provider == .elevenLabs {
                request.setValue(settings.apiKey, forHTTPHeaderField: "xi-api-key")
            } else {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 构建请求 Body
        let speed = min(2.0, max(0.5, Double(rate) / 0.4))
        var bodyObj: [String: Any] = [:]
        if settings.provider == .elevenLabs {
            bodyObj = [
                "text": trimmed,
                "model_id": settings.model.isEmpty ? "eleven_multilingual_v2" : settings.model,
                "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
            ]
        } else {
            // OpenAI 兼容格式
            bodyObj = [
                "model": settings.model.isEmpty ? "tts-1-hd" : settings.model,
                "input": trimmed,
                "voice": settings.voice.isEmpty ? "onyx" : settings.voice,
                "response_format": "mp3",
                "speed": speed
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)

        let sema = DispatchSemaphore(value: 0)
        final class ResponseBox: @unchecked Sendable {
            var data: Data?
            var error: Error?
            var completed = false
        }
        let box = ResponseBox()

        var dataTask: URLSessionDataTask?
        dataTask = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.error = error
            box.completed = true
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let errStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(http.statusCode)"
                box.error = BookStreamError.audioRenderFailed("API 请求失败 (\(http.statusCode)): \(errStr.prefix(120))")
            }
            sema.signal()
        }
        dataTask?.resume()

        while !box.completed {
            if cancellation?() == true {
                dataTask?.cancel()
                throw BookStreamError.cancelled
            }
            if sema.wait(timeout: .now() + 0.05) == .success {
                break
            }
        }

        if cancellation?() == true { throw BookStreamError.cancelled }

        if let fetchError = box.error { throw fetchError }
        guard let data = box.data, !data.isEmpty else {
            throw BookStreamError.audioRenderFailed("API 未返回任何音频数据")
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("api_tts_\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: tmp) }
        try data.write(to: tmp)

        let audioFile = try AVAudioFile(forReading: tmp)
        var buffers: [AVAudioPCMBuffer] = []
        while audioFile.framePosition < audioFile.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 4096) else { break }
            try audioFile.read(into: buf)
            if buf.frameLength == 0 { break }
            buffers.append(buf)
        }
        guard !buffers.isEmpty else {
            throw BookStreamError.audioRenderFailed("API 音频解码未产出有效 PCM 数据")
        }
        return buffers
    }
}
