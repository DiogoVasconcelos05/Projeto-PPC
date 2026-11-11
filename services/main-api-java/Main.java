import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.concurrent.Executors;

public class Main {
    private static final HttpClient httpClient = HttpClient.newBuilder()
        .connectTimeout(java.time.Duration.ofSeconds(5))
        .executor(Executors.newVirtualThreadPerTaskExecutor())
        .build();

    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);

        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());

        server.createContext("/api", new ApiHandler());
        System.out.println("Java Virtual Threads API a correr na porta 8080...");
        server.start();
    }

    
    static class ApiHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }

            byte[] body = exchange.getRequestBody().readAllBytes();

            try {
                HttpRequest request = HttpRequest.newBuilder()
                        .uri(URI.create("http://localhost:8081/delay"))
                        .GET()
                        .build();

                HttpResponse<String> response = httpClient.send(
                        request,
                        HttpResponse.BodyHandlers.ofString()
                );

                if (response.statusCode() != 200) {
                    exchange.sendResponseHeaders(500, -1);
                    return;
                }

                String jsonResponse =
                        "{\"message\":\"processed\",\"bytes\":" + body.length + "}";

                byte[] responseBytes = jsonResponse.getBytes(
                        java.nio.charset.StandardCharsets.UTF_8
                );

                exchange.getResponseHeaders().set(
                        "Content-Type", "application/json"
                );

                exchange.sendResponseHeaders(200, responseBytes.length);

                try (OutputStream os = exchange.getResponseBody()) {
                    os.write(responseBytes);
                }

            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                exchange.sendResponseHeaders(500, -1);
            }
        }
    }
}