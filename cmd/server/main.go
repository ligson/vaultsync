package main

import (
	"log"

	"github.com/ligson/vaultsync/internal/app"
	"github.com/ligson/vaultsync/internal/config"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}

	application, err := app.New(cfg)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("configured VaultSync server addr=%s data_dir=%s database_path=%s", application.Config.HTTPAddr, application.Config.DataDir, application.Config.DatabasePath)
}
