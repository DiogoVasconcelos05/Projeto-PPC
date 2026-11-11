package main

import (
	"fmt"
	"net/http"
	"time"
)

func delayHandler(w http.ResponseWriter, r *http.Request) {
	time.Sleep(20 * time.Millisecond)
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, `{"status":"ok"}`)
}

func main() {
	http.HandleFunc("/delay", delayHandler)
	fmt.Println("Secondary I/O Service a correr na porta 8081...")
	http.ListenAndServe(":8081", nil)
}