package test

import (
	"os"
	"path"
)

type MediaTestFile struct {
	// Path relative to this directory
	Path string

	SHA256   string
	Filesize int64
}

func (m *MediaTestFile) AbsPath() string {
	absDir, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return path.Clean(absDir + "/../test/" + m.Path)
}

var MediaTestFiles = []MediaTestFile{
	{
		Path:     "1x1.jpg",
		SHA256:   "6f634954771ccfae7c7041f12e308e4a658cecdd9020a3a5ac867ef0ac345347",
		Filesize: 1231,
	},
	{
		Path:     "1x1.png",
		SHA256:   "97bb583b4b8afdca23a482c9f541bdd0e4831a27b04f19efea59ec32fa160dcc",
		Filesize: 545,
	},
	{
		Path:     "more test images/1x1.jpeg",
		SHA256:   "42e5505f7abc09adb1ad94d323abae37ffce640e5516d8396886b84a97133b20",
		Filesize: 1229,
	},
}
