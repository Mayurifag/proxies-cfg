.PHONY: ci setup teardown restart test status logs flush-dns update-geodata add-domain remove-domain generate-config doctor unlock lock install-hooks

# ── platform detection ────────────────────────────────────────────────────────
ifeq ($(OS),Windows_NT)
  PS := pwsh.exe -ExecutionPolicy Bypass -File

  cmd_setup        := $(PS) windows/setup.ps1
  cmd_teardown     := $(PS) windows/teardown.ps1
  cmd_test         := $(PS) windows/test.ps1
  cmd_status       := $(PS) windows/status.ps1
  cmd_logs         := $(PS) windows/logs.ps1
  cmd_flush_dns    := $(PS) windows/flush_dns.ps1
  cmd_geodata      := $(PS) windows/update_geodata.ps1
  cmd_add_domain   := $(PS) windows/add_domain.ps1 $(domain) $(proxy)
  cmd_rm_domain    := $(PS) windows/remove_domain.ps1 $(domain)
  cmd_ci           := $(PS) windows/ci.ps1
  cmd_gen_config   := $(PS) windows/generate_config.ps1
  cmd_doctor       := $(PS) windows/doctor.ps1
else ifeq ($(shell uname),Darwin)
  cmd_setup        := bash macos/setup.sh
  cmd_teardown     := bash macos/teardown.sh
  cmd_test         := bash macos/test.sh
  cmd_status       := bash macos/status.sh
  cmd_logs         := bash macos/logs.sh
  cmd_flush_dns    := bash macos/flush_dns.sh
  cmd_geodata      := bash macos/update_geodata.sh
  cmd_add_domain   := bash macos/add_domain.sh $(domain) $(proxy)
  cmd_rm_domain    := bash macos/remove_domain.sh $(domain)
  cmd_ci           := bash macos/ci.sh
  cmd_gen_config   := bash macos/generate_config.sh
  cmd_doctor       := bash macos/doctor.sh
else
  cmd_setup        := bash linux/setup.sh
  cmd_teardown     := bash linux/teardown.sh
  cmd_test         := bash linux/test.sh
  cmd_status       := bash linux/status.sh
  cmd_logs         := bash linux/logs.sh
  cmd_flush_dns    := bash linux/flush_dns.sh
  cmd_geodata      := bash linux/update_geodata.sh
  cmd_add_domain   := bash linux/add_domain.sh $(domain) $(proxy)
  cmd_rm_domain    := bash linux/remove_domain.sh $(domain)
  cmd_ci           := bash linux/ci.sh
  cmd_gen_config   := bash linux/generate_config.sh
  cmd_doctor       := bash linux/doctor.sh
endif

# ── targets ───────────────────────────────────────────────────────────────────
ci:
	$(cmd_ci)

setup:
	$(cmd_setup)

teardown:
	$(cmd_teardown)

restart: teardown setup

test: ci
	$(cmd_test)

status:
	$(cmd_status)

logs:
	$(cmd_logs)

flush-dns:
	$(cmd_flush_dns)

update-geodata:
	$(cmd_geodata)

add-domain:
	$(cmd_add_domain)

remove-domain:
	$(cmd_rm_domain)

generate-config:
	$(cmd_gen_config)

doctor:
	$(cmd_doctor)

unlock:
	git-crypt unlock

lock:
	git-crypt lock

install-hooks:
	git config core.hooksPath .githooks
	@echo 'pre-commit hook active.'
