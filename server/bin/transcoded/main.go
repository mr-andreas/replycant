package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/server/transcoded"
)

// CLI configuration structure for kong
type CLI struct {
	Listen      string `kong:"default=':8082',help='Server listen address'"`
	Upstream    string `kong:"default='http://decryptd:8084',help='Upstream server base URL'"`
	FFmpegPath  string `kong:"default='ffmpeg',help='Path to ffmpeg binary'"`
	FFprobePath string `kong:"default='ffprobe',help='Path to ffprobe binary'"`
}

// Main entry point for HLS transcoding server
func main() {
	var cli CLI
	kong.Parse(&cli)

	upstreamClient := transcoded.NewUpstreamClient(cli.Upstream)
	transcoder := transcoded.NewTranscoder(cli.FFmpegPath, cli.FFprobePath, upstreamClient)
	server := transcoded.NewServer(transcoder)

	httpServer := &http.Server{
		Addr:    cli.Listen,
		Handler: server,
	}

	go func() {
		log.Printf("HLS server starting on %s", cli.Listen)
		log.Printf("Upstream server: %s", cli.Upstream)
		log.Printf("FFmpeg path: %s", cli.FFmpegPath)
		log.Printf("FFprobe path: %s", cli.FFprobePath)

		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-signalCtx.Done()

	log.Println("Shutting down server...")
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		log.Fatalf("Server shutdown failed: %v", err)
	}

	log.Println("Server stopped")
}
