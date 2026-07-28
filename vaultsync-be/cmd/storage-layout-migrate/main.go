package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ligson/vaultsync/internal/maintenance"
	_ "modernc.org/sqlite"
)

func main() {
	var dataDir string
	var storedDataDir string
	var databasePath string
	var reportPath string
	var mode string
	flag.StringVar(&dataDir, "data-dir", "./data", "NAS 宿主机上的真实 data 目录")
	flag.StringVar(&storedDataDir, "stored-data-dir", "", "数据库 content_path 中使用的数据目录前缀，例如 /data；为空时使用 data-dir")
	flag.StringVar(&databasePath, "db", "", "SQLite 数据库路径；为空时使用 {data-dir}/vaultsync.db")
	flag.StringVar(&reportPath, "report", "", "迁移报告 JSONL 路径；cleanup 模式必须指定 apply 阶段生成的报告")
	flag.StringVar(&mode, "mode", string(maintenance.StorageLayoutDryRun), "运行模式：dry-run、apply、cleanup")
	flag.Parse()

	if strings.TrimSpace(storedDataDir) == "" {
		storedDataDir = dataDir
	}
	if strings.TrimSpace(databasePath) == "" {
		databasePath = filepath.Join(dataDir, "vaultsync.db")
	}

	db, err := sql.Open("sqlite", fmt.Sprintf("file:%s", filepath.Clean(databasePath)))
	if err != nil {
		fatal(err)
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		fatal(err)
	}

	summary, err := maintenance.RunStorageLayoutMigration(context.Background(), db, maintenance.StorageLayoutOptions{
		DataDir:       dataDir,
		StoredDataDir: storedDataDir,
		ReportPath:    reportPath,
		Mode:          maintenance.StorageLayoutMode(mode),
	})
	if err != nil {
		fatal(err)
	}
	printSummary(summary)
	if summary.Errors > 0 {
		os.Exit(2)
	}
}

func printSummary(summary maintenance.StorageLayoutSummary) {
	fmt.Printf("模式：%s\n", summary.Mode)
	fmt.Printf("扫描版本：%d\n", summary.Scanned)
	fmt.Printf("计划迁移：%d\n", summary.Planned)
	fmt.Printf("已迁移数据库路径：%d\n", summary.Migrated)
	fmt.Printf("已生成普通目录镜像：%d\n", summary.Mirrored)
	fmt.Printf("已删除旧文件：%d\n", summary.Deleted)
	fmt.Printf("跳过：%d\n", summary.Skipped)
	fmt.Printf("错误：%d\n", summary.Errors)
	if summary.BackupPath != "" {
		fmt.Printf("数据库备份：%s\n", summary.BackupPath)
	}
	if summary.ReportPath != "" {
		fmt.Printf("迁移报告：%s\n", summary.ReportPath)
	}
	if len(summary.NeedsManualCheck) > 0 {
		fmt.Println("需要人工确认：")
		for _, item := range summary.NeedsManualCheck {
			fmt.Printf("- %s\n", item)
		}
	}
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "执行失败：%v\n", err)
	os.Exit(1)
}
