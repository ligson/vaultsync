package httpapi

import (
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/handlers"
)

type Dependencies struct {
	AuthHandler *handlers.AuthHandler
}

func NewRouter(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	return mux
}

func RegisterRoutes(mux *http.ServeMux, deps Dependencies) {
	mux.HandleFunc("POST /api/v1/auth/register", deps.AuthHandler.Register)
	mux.HandleFunc("POST /api/v1/auth/login", deps.AuthHandler.Login)
}
