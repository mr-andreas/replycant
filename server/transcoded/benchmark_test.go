package transcoded

import (
	"bytes"
	"io"
	"os/exec"
	"regexp"
	"strconv"
	"testing"
	"time"
)

type timedWriter struct {
	writer    io.Writer
	firstByte time.Time
}

func (w *timedWriter) Write(p []byte) (n int, err error) {
	if w.firstByte.IsZero() {
		w.firstByte = time.Now()
	}
	return w.writer.Write(p)
}

func BenchmarkTranscode2(b *testing.B) {
	for name, argsFunc := range argSets {
		for _, quality := range DefaultQualityVariants {
			b.Run(name+" "+quality.Name, func(b *testing.B) {
				args := argsFunc(
					"http://admin:admin@localhost:8080/objects/a0d0b6ea5df5634e02671a64f86867e42232cdb7640600c67dbae8296924ec5d",
					30.0,
					10.0,
					quality,
					"Accept: application/vnd.git-lfs\r\n",
				)
				cmd := exec.Command("ffmpeg", args...)
				var stderr bytes.Buffer
				timedWriter := &timedWriter{
					writer: io.Discard,
				}
				cmd.Stdout = timedWriter
				cmd.Stderr = &stderr

				// b.Logf("ffmpeg command: %s %s", cmd.Path, strings.Join(cmd.Args, " "))

				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					start := time.Now()
					err := cmd.Run()
					elapsed := time.Since(start)
					if err != nil {
						b.Logf("stderr: %s", stderr.String())
						b.Fatal(err)
					}

					// Extract and report frames per second
					matches := regexp.MustCompile(`fps=(\d+)`).FindAllStringSubmatch(stderr.String(), -1)
					if len(matches) == 0 {
						b.Logf("stderr: %s", stderr.String())
						b.Fatal("fps not found")
					}
					fps, err := strconv.ParseFloat(matches[len(matches)-1][1], 64)
					if err != nil {
						b.Fatal(err)
					}
					b.ReportMetric(fps, "fps")

					speedMatches := regexp.MustCompile(`speed=\s*(\d+\.\d+)x`).FindAllStringSubmatch(stderr.String(), -1)
					if len(speedMatches) == 0 {
						b.Fatal("speed not found")
					}
					speed, err := strconv.ParseFloat(speedMatches[len(speedMatches)-1][1], 64)
					if err != nil {
						b.Fatal(err)
					}
					b.ReportMetric(speed, "speed")

					b.ReportMetric(elapsed.Seconds(), "s/transcode")
					b.ReportMetric(timedWriter.firstByte.Sub(start).Seconds(), "TTFB")

					// b.Fatal(stderr.String())
					// b.Fail
				}
			})
		}
	}
}
