package main

import (
	"log"
	"net/http"
	"os"

	"github.com/ligson/vaultsync/internal/app"
	"github.com/ligson/vaultsync/internal/config"
)

func main() {
	cfg, err := config.LoadFromArgs(os.Args[1:])
	if err != nil {
		log.Fatal(err)
	}

	application, err := app.New(cfg)
	if err != nil {
		log.Fatal(err)
	}
	defer application.Close()

	server := &http.Server{
		Addr:    application.Config.HTTPAddr,
		Handler: application.Handler(),
	}
	log.Printf("starting VaultSync server addr=%s data_dir=%s database_path=%s", application.Config.HTTPAddr, application.Config.DataDir, application.Config.DatabasePath)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
