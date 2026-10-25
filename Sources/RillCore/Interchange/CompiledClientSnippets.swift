import Foundation

extension ClientSnippetGenerator {
    // Base64 avoids language-specific Unicode/surrogate and interpolation semantics.
    static func compiledClient(_ request: FrozenClientRequest, target: ClientTarget) throws
        -> String
    {
        func encoded(_ data: Data) -> String {
            let text = data.base64EncodedString()
            var chunks: [String] = []
            var index = text.startIndex
            while index < text.endIndex {
                let end =
                    text.index(index, offsetBy: 1024, limitedBy: text.endIndex) ?? text.endIndex
                chunks.append("\"" + text[index..<end] + "\"")
                index = end
            }
            if chunks.isEmpty { chunks = ["\"\""] }
            let list = chunks.joined(separator: ",")
            switch target {
            case .java, .okhttp: return "String.join(\"\", new String[]{" + list + "})"
            case .go: return "strings.Join([]string{" + list + "}, \"\")"
            case .rust: return "[" + list + "].concat()"
            default: return "string.Concat(new string[]{" + list + "})"
            }
        }
        func string(_ value: String) -> String { "d(" + encoded(Data(value.utf8)) + ")" }
        let method = string(request.method)
        let url = string(request.url)
        let body = encoded(request.body ?? Data())
        let headers = request.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
        let ms = String(Int(request.timeout * 1000))
        let note =
            "Frozen bytes; redirects disabled. URL/body/headers may contain secrets. SDK defaults, URL normalization and timeout semantics differ from Rill."
        switch target {
        case .java:
            let assignments = headers.map {
                "        builder.header(\(string($0.key)), \(string($0.value)));"
            }.joined(separator: "\n")
            return """
                // Java 21+: save as RillRequest.java; javac RillRequest.java && java RillRequest
                // \(note) Request timeout covers headers; bounded body read has a separate deadline.
                import java.net.*;
                import java.net.http.*;
                import java.time.Duration;
                import java.util.Base64;
                import java.nio.charset.StandardCharsets;
                import java.util.concurrent.*;
                public class RillRequest {
                    static String d(String s) { return new String(Base64.getDecoder().decode(s), StandardCharsets.UTF_8); }
                    public static void main(String[] args) throws Exception {
                        try (var client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).connectTimeout(Duration.ofMillis(\(ms))).proxy(new ProxySelector() { public java.util.List<Proxy> select(URI uri) { return java.util.List.of(Proxy.NO_PROXY); } public void connectFailed(URI uri, java.net.SocketAddress address, java.io.IOException error) {} }).build()) {
                            var builder = HttpRequest.newBuilder(URI.create(\(url))).timeout(Duration.ofMillis(\(ms)));
                \(assignments)
                            builder.method(\(method), \(request.body == nil ? "HttpRequest.BodyPublishers.noBody()" : "HttpRequest.BodyPublishers.ofByteArray(Base64.getDecoder().decode(\(body)))"));
                            var response = client.send(builder.build(), HttpResponse.BodyHandlers.ofInputStream());
                            try (var stream = response.body()) {
                                var read = CompletableFuture.supplyAsync(() -> {
                                    try { return stream.readNBytes(16777217); }
                                    catch (java.io.IOException error) { throw new CompletionException(error); }
                                });
                                byte[] payload = read.get(\(ms), TimeUnit.MILLISECONDS);
                                if (payload.length > 16777216) throw new java.io.IOException("Response exceeds 16 MiB");
                                System.out.write(payload);
                            }
                        }
                    }
                }
                """
        case .okhttp:
            let assignments = headers.map {
                "        builder.header(\(string($0.key)), \(string($0.value)));"
            }.joined(separator: "\n")
            // OkHttp requires a body for these methods even when the native draft has none.
            let needsBody =
                request.body != nil
                || ["POST", "PUT", "PATCH", "PROPPATCH", "REPORT"].contains(request.method)
            return """
                // Java 21+; dependency com.squareup.okhttp3:okhttp:5.3.2; class RillRequest.
                // \(note)
                import okhttp3.*;
                import java.util.Base64;
                import java.nio.charset.StandardCharsets;
                import java.util.concurrent.TimeUnit;
                public class RillRequest {
                    static String d(String s) { return new String(Base64.getDecoder().decode(s), StandardCharsets.UTF_8); }
                    public static void main(String[] args) throws Exception {
                        var client = new OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
                            .proxy(java.net.Proxy.NO_PROXY).callTimeout(\(ms), TimeUnit.MILLISECONDS).build();
                        try {
                            var builder = new Request.Builder().url(\(url));
                \(assignments)
                            builder.method(\(method), \(needsBody ? "RequestBody.create((MediaType)null, Base64.getDecoder().decode(\(body)))" : "null"));
                            try (var response = client.newCall(builder.build()).execute()) {
                                try (var stream = response.body().byteStream()) {
                                    byte[] payload = stream.readNBytes(16777217);
                                    if (payload.length > 16777216) throw new java.io.IOException("Response exceeds 16 MiB");
                                    System.out.write(payload);
                                }
                            }
                        } finally {
                            client.dispatcher().executorService().shutdown();
                            client.connectionPool().evictAll();
                        }
                    }
                }
                """
        case .go:
            let assignments = headers.map {
                "    request.Header.Set(\(string($0.key)), \(string($0.value)))"
            }.joined(separator: "\n")
            return """
                // Go 1.24+: save as request.go; go run request.go
                // \(note)
                package main
                import ("bytes"; "encoding/base64"; "fmt"; "io"; "net/http"; "os"; "strings"; "time")
                func d(s string) string { b, err := base64.StdEncoding.DecodeString(s); if err != nil { panic(err) }; return string(b) }
                func main() {
                    body, err := base64.StdEncoding.DecodeString(\(body)); if err != nil { panic(err) }
                    request, err := http.NewRequest(\(method), \(url), bytes.NewReader(body)); if err != nil { panic(err) }
                \(assignments)
                    transport := http.DefaultTransport.(*http.Transport).Clone(); transport.Proxy = nil
                    defer transport.CloseIdleConnections()
                    client := &http.Client{Transport: transport, Timeout: \(ms) * time.Millisecond, CheckRedirect: func(r *http.Request, via []*http.Request) error { return http.ErrUseLastResponse }}
                    response, err := client.Do(request); if err != nil { panic(err) }; defer response.Body.Close()
                    payload, err := io.ReadAll(io.LimitReader(response.Body, 16777217)); if err != nil { panic(err) }
                    if len(payload) > 16777216 { panic(fmt.Errorf("Response exceeds 16 MiB")) }
                    if _, err = os.Stdout.Write(payload); err != nil { panic(err) }
                }
                """
        case .rust:
            let assignments = headers.map {
                "    request = request.header(d(\(encoded(Data($0.key.utf8))))?, d(\(encoded(Data($0.value.utf8))))?);"
            }.joined(separator: "\n")
            return """
                // Rust 2021; Cargo dependencies: reqwest = { version = "0.13.5", features = ["blocking"] }, base64 = "0.22.1"
                // \(note)
                use base64::{Engine as _, engine::general_purpose::STANDARD};
                use std::io::{Read, Write};
                fn d(s: String) -> Result<String, Box<dyn std::error::Error>> { Ok(String::from_utf8(STANDARD.decode(s)?)?) }
                fn main() -> Result<(), Box<dyn std::error::Error>> {
                    let client = reqwest::blocking::Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none()).timeout(std::time::Duration::from_millis(\(ms))).build()?;
                    let mut request = client.request(reqwest::Method::from_bytes(d(\(encoded(Data(request.method.utf8))))?.as_bytes())?, d(\(encoded(Data(request.url.utf8))))?);
                \(assignments)
                    \(request.body == nil ? "" : "request = request.body(STANDARD.decode(\(body))?);")
                    let response = request.send()?;
                    let mut payload = Vec::new(); response.take(16777217).read_to_end(&mut payload)?;
                    if payload.len() > 16777216 { return Err("Response exceeds 16 MiB".into()); }
                    std::io::stdout().write_all(&payload)?;
                    Ok(())
                }
                """
        case .csharp:
            let assignments = headers.map { key, value in
                "if (!request.Headers.TryAddWithoutValidation(\(string(key)), \(string(value)))) { request.Content ??= new ByteArrayContent(Array.Empty<byte>()); if (!request.Content.Headers.TryAddWithoutValidation(\(string(key)), \(string(value)))) throw new Exception(\"Unsupported header\"); }"
            }.joined(separator: "\n")
            return """
                // .NET 10 console project; replace Program.cs; dotnet run.
                // \(note)
                using System;
                using System.IO;
                using System.Net.Http;
                using System.Text;
                using System.Threading;
                static string d(string s) => Encoding.UTF8.GetString(Convert.FromBase64String(s));
                using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseProxy = false };
                using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
                using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(\(ms)));
                using var request = new HttpRequestMessage(new HttpMethod(\(method)), \(url));
                \(request.body == nil ? "" : "request.Content = new ByteArrayContent(Convert.FromBase64String(\(body)));")
                \(assignments)
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
                using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
                using var payload = new MemoryStream();
                var buffer = new byte[65536]; int count;
                while ((count = await stream.ReadAsync(buffer.AsMemory(), deadline.Token)) != 0) {
                    if (payload.Length + count > 16777216) throw new IOException("Response exceeds 16 MiB");
                    payload.Write(buffer, 0, count);
                }
                await Console.OpenStandardOutput().WriteAsync(payload.ToArray(), deadline.Token);
                """
        default: throw CommandError.unsupported("compiled client target")
        }
    }
}
