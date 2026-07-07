package config

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

const DefaultConfigPath = "config.yaml"

type Config struct {
	HTTPAddr                 string
	DataDir                  string
	DatabasePath             string
	TokenSecret              string
	AdminRegistrationEnabled bool
	DefaultUserQuotaBytes    int64
}

type fileConfig struct {
	App appConfig `yaml:"app"`
}

type appConfig struct {
	Server struct {
		HTTPAddr string `yaml:"http_addr"`
	} `yaml:"server"`
	Storage struct {
		DataDir      string `yaml:"data_dir"`
		DatabasePath string `yaml:"database_path"`
	} `yaml:"storage"`
	Security struct {
		TokenSecret string `yaml:"token_secret"`
	} `yaml:"security"`
	Admin struct {
		RegistrationEnabled   bool  `yaml:"registration_enabled"`
		DefaultUserQuotaBytes int64 `yaml:"default_user_quota_bytes"`
	} `yaml:"admin"`
}

func Load() (Config, error) {
	return LoadFile(DefaultConfigPath)
}

func LoadFromArgs(args []string) (Config, error) {
	flags := flag.NewFlagSet("vaultsync", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	configPath := flags.String("config", DefaultConfigPath, "VaultSync 配置文件路径")
	if err := flags.Parse(args); err != nil {
		return Config{}, err
	}
	return LoadFile(*configPath)
}

func LoadFile(path string) (Config, error) {
	if strings.TrimSpace(path) == "" {
		return Config{}, errors.New("配置文件路径不能为空")
	}

	content, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Config{}, fmt.Errorf("配置文件不存在：%s，请复制 config.example.yaml 为 config.yaml 后修改", path)
		}
		return Config{}, fmt.Errorf("读取配置文件失败：%w", err)
	}

	var raw fileConfig
	if err := yaml.Unmarshal(content, &raw); err != nil {
		return Config{}, fmt.Errorf("解析配置文件失败：%w", err)
	}

	cfg := Config{
		HTTPAddr:                 valueOrDefault(raw.App.Server.HTTPAddr, ":8080"),
		DataDir:                  valueOrDefault(raw.App.Storage.DataDir, "./data"),
		DatabasePath:             raw.App.Storage.DatabasePath,
		TokenSecret:              strings.TrimSpace(raw.App.Security.TokenSecret),
		AdminRegistrationEnabled: raw.App.Admin.RegistrationEnabled,
		DefaultUserQuotaBytes:    raw.App.Admin.DefaultUserQuotaBytes,
	}
	if cfg.DatabasePath == "" {
		cfg.DatabasePath = filepath.Join(cfg.DataDir, "vaultsync.db")
	}
	if cfg.DefaultUserQuotaBytes == 0 {
		cfg.DefaultUserQuotaBytes = 100 * 1024 * 1024 * 1024
	}

	if err := validate(cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func validate(cfg Config) error {
	if strings.TrimSpace(cfg.HTTPAddr) == "" {
		return errors.New("配置项 app.server.http_addr 不能为空")
	}
	if strings.TrimSpace(cfg.DataDir) == "" {
		return errors.New("配置项 app.storage.data_dir 不能为空")
	}
	if strings.TrimSpace(cfg.DatabasePath) == "" {
		return errors.New("配置项 app.storage.database_path 不能为空")
	}
	if cfg.TokenSecret == "" {
		return errors.New("配置项 app.security.token_secret 不能为空")
	}
	return nil
}

func valueOrDefault(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}
