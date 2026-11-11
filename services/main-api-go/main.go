package main

import (
	"fmt"
	"io"
	"net/http"
	"time"
)

var httpClient = &http.Client{
	Timeout: 5 * time.Second,
}

func apiHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Error reading request body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	resp, err := httpClient.Get("http://localhost:8081/delay")
	if err != nil {
		http.Error(w, "Internal dependency error", http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		http.Error(w, "Internal dependency error", http.StatusInternalServerError)
		return
	}

	if _, err := io.Copy(io.Discard, resp.Body); err != nil {
		http.Error(w, "Internal dependency error", http.StatusInternalServerError)
		return
	}

	jsonResponse := fmt.Sprintf(`{"message":"processed","bytes":%d}`, len(body))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(jsonResponse))
}

func main() {
	http.HandleFunc("/api", apiHandler)
	fmt.Println("Go API a correr na porta 8080...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Printf("Erro ao iniciar o servidor: %v\n", err)
	}
}