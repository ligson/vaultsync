package token

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type Claims struct {
	TokenID   string
	UserID    string
	DeviceID  string
	ExpiresAt time.Time
}

func Create(secret []byte, tokenID, userID, deviceID string, expiresAt time.Time) (string, error) {
	payload := fmt.Sprintf("%s.%s.%s.%d", tokenID, userID, deviceID, expiresAt.Unix())
	signature := sign(secret, payload)
	return base64.RawURLEncoding.EncodeToString([]byte(payload + "." + signature)), nil
}

func Verify(secret []byte, value string, now time.Time) (Claims, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return Claims{}, fmt.Errorf("invalid token encoding")
	}

	parts := strings.Split(string(decoded), ".")
	if len(parts) != 5 {
		return Claims{}, fmt.Errorf("invalid token payload")
	}

	payload := strings.Join(parts[:4], ".")
	if !hmac.Equal([]byte(sign(secret, payload)), []byte(parts[4])) {
		return Claims{}, fmt.Errorf("invalid token signature")
	}

	expiresUnix, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		return Claims{}, fmt.Errorf("invalid token expiry")
	}
	expiresAt := time.Unix(expiresUnix, 0).UTC()
	if !now.Before(expiresAt) {
		return Claims{}, fmt.Errorf("token expired")
	}

	return Claims{
		TokenID:   parts[0],
		UserID:    parts[1],
		DeviceID:  parts[2],
		ExpiresAt: expiresAt,
	}, nil
}

func sign(secret []byte, payload string) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payload))
	return hex.EncodeToString(mac.Sum(nil))
}
