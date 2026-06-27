package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
)

type FSStorage struct {
	rootDir string
}

func NewFSStorage(rootDir string) *FSStorage {
	return &FSStorage{rootDir: rootDir}
}

func (s *FSStorage) AppendChunk(userID, sessionID string, chunk io.Reader) (int64, error) {
	path := filepath.Join(s.rootDir, "uploads", userID, sessionID+".part")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 0, err
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	return io.Copy(file, chunk)
}

func (s *FSStorage) FinalizeUpload(userID, sessionID, versionID string) (string, string, int64, error) {
	sourcePath := filepath.Join(s.rootDir, "uploads", userID, sessionID+".part")
	targetPath := filepath.Join(s.rootDir, "objects", userID, versionID+".bin")
	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return "", "", 0, err
	}
	if err := os.Rename(sourcePath, targetPath); err != nil {
		return "", "", 0, err
	}

	hashValue, size, err := hashFile(targetPath)
	if err != nil {
		return "", "", 0, err
	}
	return targetPath, hashValue, size, nil
}

func hashFile(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()

	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hash.Sum(nil)), size, nil
}
