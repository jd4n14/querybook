package connections

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// NormalizeSQLitePath resolves the only shell-like spelling accepted by the
// connection form. Path handling belongs to the Go boundary so execution and
// the manager use the same value regardless of Neovim's working directory.
// The in-memory SQLite name is kept as-is.
func NormalizeSQLitePath(path string) (string, error) {
	if path == ":memory:" {
		return path, nil
	}
	if strings.TrimSpace(path) == "" {
		return "", errf("invalid_connection", "SQLite path is required")
	}
	if strings.ContainsRune(path, 0) {
		return "", errf("invalid_connection", "SQLite path is invalid")
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", errf("invalid_connection", "user home directory unavailable")
		}
		if path == "~" {
			path = home
		} else {
			path = filepath.Join(home, path[2:])
		}
	} else if strings.HasPrefix(path, "~") {
		return "", errf("invalid_connection", "SQLite paths for another user are not supported")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", errf("invalid_connection", "SQLite path is invalid")
	}
	return filepath.Clean(abs), nil
}

// CheckSQLitePath verifies a file before opening it. modernc SQLite creates a
// missing database during sql.Open, which is useful for fixtures but unsafe
// for a saved connection test or query pointed at a typo. This check keeps
// those operations read-only and gives the user an actionable category.
func CheckSQLitePath(path string) error {
	normalized, err := NormalizeSQLitePath(path)
	if err != nil {
		return err
	}
	if normalized == ":memory:" {
		return nil
	}
	info, statErr := os.Stat(normalized)
	if statErr == nil {
		if !info.Mode().IsRegular() {
			return errf("sqlite_path_invalid", "SQLite path is not a regular file: "+normalized)
		}
		return nil
	}
	if errors.Is(statErr, os.ErrNotExist) {
		parent := filepath.Dir(normalized)
		if _, parentErr := os.Stat(parent); errors.Is(parentErr, os.ErrNotExist) {
			return errf("sqlite_parent_missing", "SQLite parent directory does not exist: "+parent)
		}
		return errf("sqlite_database_missing", "SQLite database file does not exist: "+normalized)
	}
	return errf("sqlite_path_unavailable", "SQLite database path cannot be inspected: "+normalized)
}
