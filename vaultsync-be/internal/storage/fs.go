package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type FSStorage struct {
	rootDir string
}

var ErrMaxSizeExceeded = errors.New("content exceeds maximum size")

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

func (s *FSStorage) StoreAvatar(userID string, content io.Reader, maxSize int64) (string, string, int64, error) {
	userID, err := safeSegment(userID, "user_id")
	if err != nil {
		return "", "", 0, err
	}
	directory := filepath.Join(s.rootDir, "avatars", userID)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return "", "", 0, err
	}
	temporary, err := os.CreateTemp(directory, ".avatar-*.part")
	if err != nil {
		return "", "", 0, err
	}
	temporaryPath := temporary.Name()
	defer func() { _ = os.Remove(temporaryPath) }()

	size, err := io.CopyN(temporary, content, maxSize+1)
	if err != nil && !errors.Is(err, io.EOF) {
		_ = temporary.Close()
		return "", "", 0, err
	}
	if size > maxSize {
		_ = temporary.Close()
		return "", "", 0, ErrMaxSizeExceeded
	}
	if err := temporary.Close(); err != nil {
		return "", "", 0, err
	}
	hashValue, size, err := hashFile(temporaryPath)
	if err != nil {
		return "", "", 0, err
	}
	targetPath := filepath.Join(directory, "avatar.bin")
	if err := os.Rename(temporaryPath, targetPath); err != nil {
		return "", "", 0, err
	}
	return filepath.ToSlash(filepath.Join("avatars", userID, "avatar.bin")), hashValue, size, nil
}

func (s *FSStorage) OpenAvatar(userID string) (*os.File, error) {
	userID, err := safeSegment(userID, "user_id")
	if err != nil {
		return nil, err
	}
	return os.Open(filepath.Join(s.rootDir, "avatars", userID, "avatar.bin"))
}

type UploadObjectPlacement struct {
	UserID       string
	DeviceID     string
	SyncRootID   string
	SessionID    string
	ObjectID     string
	VersionID    string
	RelativePath string
	Encrypted    bool
	ExpectedSize int64
}

func (s *FSStorage) FinalizeUpload(placement UploadObjectPlacement) (string, string, int64, error) {
	sourcePath := filepath.Join(s.rootDir, "uploads", placement.UserID, placement.SessionID+".part")
	targetPath, mirrorPath, err := s.targetPaths(placement)
	if err != nil {
		return "", "", 0, err
	}
	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return "", "", 0, err
	}
	if err := os.Rename(sourcePath, targetPath); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return "", "", 0, err
		}
		if placement.ExpectedSize == 0 {
			file, createErr := os.OpenFile(targetPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
			if createErr != nil {
				return "", "", 0, createErr
			}
			if closeErr := file.Close(); closeErr != nil {
				return "", "", 0, closeErr
			}
		} else if err := validateExistingFinalizedFile(targetPath, placement.ExpectedSize); err != nil {
			return "", "", 0, err
		}
	}
	if mirrorPath != "" {
		if err := publishPlainMirror(targetPath, mirrorPath); err != nil {
			return "", "", 0, err
		}
	}

	hashValue, size, err := hashFile(targetPath)
	if err != nil {
		return "", "", 0, err
	}
	return targetPath, hashValue, size, nil
}

func (s *FSStorage) InspectRecoverableUpload(placement UploadObjectPlacement) (string, string, int64, error) {
	sourcePath := filepath.Join(s.rootDir, "uploads", placement.UserID, placement.SessionID+".part")
	targetPath, _, err := s.targetPaths(placement)
	if err != nil {
		return "", "", 0, err
	}
	hashPath := targetPath
	if err := validateExistingFinalizedFile(targetPath, placement.ExpectedSize); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return "", "", 0, err
		}
		hashPath = sourcePath
		if err := validateExistingFinalizedFile(sourcePath, placement.ExpectedSize); err != nil {
			return "", "", 0, err
		}
	}
	hashValue, size, err := hashFile(hashPath)
	if err != nil {
		return "", "", 0, err
	}
	return targetPath, hashValue, size, nil
}

func validateExistingFinalizedFile(path string, expectedSize int64) error {
	stat, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return err
		}
		return err
	}
	if stat.IsDir() {
		return fmt.Errorf("正式文件路径是目录：%s", path)
	}
	if stat.Size() != expectedSize {
		return fmt.Errorf("正式文件大小不一致：got %d want %d", stat.Size(), expectedSize)
	}
	return nil
}

func (s *FSStorage) targetPaths(placement UploadObjectPlacement) (string, string, error) {
	userID, err := safeSegment(placement.UserID, "user_id")
	if err != nil {
		return "", "", err
	}
	deviceID, err := safeSegment(placement.DeviceID, "device_id")
	if err != nil {
		return "", "", err
	}
	syncRootID, err := safeSegment(placement.SyncRootID, "sync_root_id")
	if err != nil {
		return "", "", err
	}
	versionID, err := safeSegment(placement.VersionID, "version_id")
	if err != nil {
		return "", "", err
	}
	if placement.Encrypted {
		return filepath.Join(s.rootDir, "objects", userID, "encrypted", deviceID, syncRootID, versionID+".bin"), "", nil
	}
	objectID, err := safeSegment(placement.ObjectID, "object_id")
	if err != nil {
		return "", "", err
	}
	relativePath, err := safeRelativePath(placement.RelativePath)
	if err != nil {
		return "", "", err
	}
	fileName := filepath.Base(relativePath)
	rootPath := filepath.Join(s.rootDir, "objects", userID, "plain", deviceID, syncRootID)
	versionPath := filepath.Join(rootPath, ".vaultsync_versions", objectID, versionID, fileName)
	mirrorPath := filepath.Join(rootPath, relativePath)
	return versionPath, mirrorPath, nil
}

func safeSegment(value, name string) (string, error) {
	if value == "" || value == "." || value == ".." {
		return "", fmt.Errorf("%s is empty or invalid", name)
	}
	if strings.ContainsAny(value, `/\`) {
		return "", fmt.Errorf("%s contains path separator", name)
	}
	return value, nil
}

func safeRelativePath(value string) (string, error) {
	value = strings.ReplaceAll(value, "\\", "/")
	if value == "" || strings.HasPrefix(value, "/") {
		return "", errors.New("relative path is empty or absolute")
	}
	cleaned := filepath.Clean(value)
	cleaned = strings.ReplaceAll(cleaned, "\\", "/")
	if cleaned == "." || strings.HasPrefix(cleaned, "../") || cleaned == ".." {
		return "", errors.New("relative path escapes sync root")
	}
	for _, segment := range strings.Split(cleaned, "/") {
		if segment == "" || segment == "." || segment == ".." || segment == ".vaultsync_versions" {
			return "", errors.New("relative path contains reserved or invalid segment")
		}
	}
	return cleaned, nil
}

func publishPlainMirror(sourcePath, mirrorPath string) error {
	if err := os.MkdirAll(filepath.Dir(mirrorPath), 0o755); err != nil {
		return err
	}
	if err := os.Remove(mirrorPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return copyFile(sourcePath, mirrorPath)
}

func copyFile(sourcePath, targetPath string) error {
	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}
	defer source.Close()

	target, err := os.OpenFile(targetPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(target, source); err != nil {
		_ = target.Close()
		return err
	}
	return target.Close()
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
