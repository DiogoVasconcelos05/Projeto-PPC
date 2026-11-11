use axum::{
    body::Bytes,
    http::StatusCode,
    response::IntoResponse,
    routing::post,
    Extension, Router,
};
use reqwest::Client;
use std::net::SocketAddr;
use std::sync::Arc;

struct AppState {
    http_client: Client,
}

#[tokio::main]
async fn main() {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .expect("Falha ao criar o cliente HTTP");

    let state = Arc::new(AppState {
        http_client: client,
    });

    let app = Router::new()
        .route("/api", post(api_handler))
        .layer(Extension(state));

    let addr = SocketAddr::from(([127, 0, 0, 1], 8080));
    println!("Rust Tokio (Axum) API a correr na porta 8080...");
    
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn api_handler(
    Extension(state): Extension<Arc<AppState>>,
    body: Bytes,
) -> impl IntoResponse {
    let payload_len = body.len();

    let res = state
        .http_client
        .get("http://localhost:8081/delay")
        .send()
        .await;

    match res {
        Ok(response) if response.status().is_success() => {
            let json_response = format!(r#"{{"message":"processed","bytes":{}}}"#, payload_len);
            (
                StatusCode::OK,
                [("Content-Type", "application/json")],
                json_response,
            )
        }
        _ => (
            StatusCode::INTERNAL_SERVER_ERROR,
            [("Content-Type", "application/json")],
            r#"{"error":"Internal dependency error"}"#.to_string(),
        ),
    }
}