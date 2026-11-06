// Package testfiles reads test fixtures, gunzipping the large ones kept compressed.
package testfiles

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"strings"
)

// Read returns the file's contents, decompressed when its name ends in .gz.
func Read(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil || !strings.HasSuffix(path, ".gz") {
		return data, err
	}
	r, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(r)
}
