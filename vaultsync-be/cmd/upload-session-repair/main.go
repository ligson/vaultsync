package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/ligson/vaultsync/internal/maintenance"
	"github.com/ligson/vaultsync/internal/store"
)

func main() {
	var (
		databasePath  string
		dataDir       string
		storedDataDir string
		mode          string
	)
	flag.StringVar(&databasePath, "database", "", "SQLite 数据库路径")
	flag.StringVar(&dataDir, "data-dir", "", "服务端数据目录的物理路径")
	flag.StringVar(&storedDataDir, "stored-data-dir", "/data", "数据库 content_path 使用的数据目录前缀")
	flag.StringVar(&mode, "mode", string(maintenance.UploadSessionRepairDryRun), "修复模式：dry-run 或 apply")
	flag.Parse()

	if databasePath == "" || dataDir == "" {
		fmt.Fprintln(os.Stderr, "必须指定 -database 和 -data-dir")
		os.Exit(2)
	}

	db, err := store.Open(databasePath)
	if err != nil {
		log.Fatalf("打开数据库失败：%v", err)
	}
	defer db.Close()

	summary, err := maintenance.RunUploadSessionRepair(context.Background(), db, maintenance.UploadSessionRepairOptions{
		DataDir:       dataDir,
		StoredDataDir: storedDataDir,
		Mode:          maintenance.UploadSessionRepairMode(mode),
	})
	if err != nil {
		log.Fatalf("修复失败：%v", err)
	}
	fmt.Printf("mode=%s scanned=%d repairable=%d repaired=%d skipped=%d errors=%d backup=%s\n",
		summary.Mode,
		summary.Scanned,
		summary.Repairable,
		summary.Repaired,
		summary.Skipped,
		summary.Errors,
		summary.BackupPath,
	)
	for _, item := range summary.NeedsManualCheck {
		fmt.Println("manual_check:", item)
	}
	if summary.Errors > 0 {
		os.Exit(1)
	}
}
