package response

import (
	"encoding/json"
	"net/http"
)

type Envelope struct {
	Success  bool   `json:"success"`
	Message  string `json:"message"`
	HTTPCode int    `json:"httpCode"`
	Data     any    `json:"data"`
}

func Write(w http.ResponseWriter, status int, message string, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data == nil {
		data = map[string]any{}
	}
	_ = json.NewEncoder(w).Encode(Envelope{
		Success:  status >= http.StatusOK && status < http.StatusMultipleChoices,
		Message:  message,
		HTTPCode: status,
		Data:     data,
	})
}
