benchmark:
	go test ./... -bench . -v -benchtime 10s -test.run ^$
.PHONY: benchmark

gitd:
	go build -o bin/gitd/gitd ./bin/gitd
.PHONY: gitd

replycant:
	go build -o bin/replycant/replycant ./bin/replycant
.PHONY: replycant
