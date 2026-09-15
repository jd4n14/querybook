.PHONY: build test test-integration runner_path

build:
	go build -trimpath -o bin/querybook-runner ./cmd/querybook-runner

test:
	go test ./internal/...
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/run.lua; fi
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/inspect_ui.lua; fi
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/connections_ui.lua; fi
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/sqls.lua; fi

test-integration:
	go test -tags=integration ./internal/...
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/run.lua; fi
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/inspect_ui.lua; fi
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/inspect_real.lua; fi
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/connections_ui.lua; fi
	@if command -v nvim >/dev/null 2>&1; then nvim --headless -u NONE -c "set rtp^=$$PWD" -l tests/sqls.lua; fi

runner_path:
	@printf '%s/bin/querybook-runner\n' "$$PWD"
