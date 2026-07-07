package handlers

import (
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/response"
)

func Health(w http.ResponseWriter, _ *http.Request) {
	response.Write(w, http.StatusOK, "", map[string]string{
		"status": "ok",
	})
}
