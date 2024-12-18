package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

var metricsDirPath string // Path to your metrics directory

func init() {
	// Get the value of the environment variable "METRICS_PATH"
	metricsDirPath = os.Getenv("METRICS_PATH")

	// Check if the environment variable is set
	if metricsDirPath == "" {
		metricsDirPath = "/var/lib/prometheus-dropzone"
	}
}

// readMetrics reads all metrics files in the specified directory and returns their contents.
func readMetrics() (string, error) {
	var metricsBuilder strings.Builder

	err := filepath.Walk(metricsDirPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(info.Name(), ".prom") { // Only read .prom files
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			metricsBuilder.Write(data)
			metricsBuilder.WriteString("\n") // Add a newline between files
		}
		return nil
	})

	if err != nil {
		return "", err
	}
	return metricsBuilder.String(), nil
}

// metricsHandler handles requests to the /metrics endpoint.
func metricsHandler(w http.ResponseWriter, r *http.Request) {
	metrics, err := readMetrics()
	if err != nil {
		log.Printf("/metrics fail 500")
		http.Error(w, "Could not read metrics", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Write([]byte(metrics))
	log.Printf("/metrics success 200")
}

func main() {
	http.HandleFunc("/metrics", metricsHandler)

	// Start the HTTP server
	port := ":8080"
	fmt.Printf("Starting server on port %s...\n", port)
	if err := http.ListenAndServe(port, nil); err != nil {
		fmt.Printf("Error starting server: %s\n", err)
		os.Exit(1)
	}
}
