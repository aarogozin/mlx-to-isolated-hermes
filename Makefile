SHELL := /bin/bash

.PHONY: setup bootstrap doctor models-search models-list models-open models-sync model-select model-start-bg model-stop-bg model-start-omlx model-start-lmstudio model-check agents-install e2e-ready docker-build docker-create docker-start docker-shell docker-stop docker-reset docker-e2e telegram-start telegram-stop telegram-restart telegram-status telegram-logs telegram-pairing telegram-approve telegram-doctor telegram-stop-host dashboard-start dashboard-stop dashboard-restart dashboard-status dashboard-logs dashboard-open dashboard-tailscale-start dashboard-tailscale-stop dashboard-tailscale-status dashboard-cloudflare-start dashboard-cloudflare-stop dashboard-cloudflare-status release-check vm-create vm-start vm-stop vm-ssh vm-snapshot vm-reset vm-status vm-list-snapshots

setup:
	./scripts/setup.sh

bootstrap:
	./scripts/bootstrap-macos.sh

doctor:
	./scripts/doctor.sh

models-search:
	@if [ -x "$$HOME/.lmstudio/bin/lms" ]; then \
		"$$HOME/.lmstudio/bin/lms" get --mlx; \
	else \
		lms get --mlx; \
	fi

models-list:
	./scripts/models-list-human.sh

models-sync:
	./scripts/models-sync-omlx.sh

model-select:
	./scripts/model-select.sh

models-open:
	open -a "LM Studio"

model-start-bg:
	./scripts/model-start-omlx-bg.sh

model-stop-bg:
	./scripts/model-stop-omlx-bg.sh

model-start-omlx:
	@set -a; [ -f .env ] && source .env; set +a; \
	: "$${MODEL_DIR:=$$HOME/.lmstudio/models}"; \
	: "$${OMLX_PORT:=8000}"; \
	: "$${MODEL_BIND_HOST:=0.0.0.0}"; \
	: "$${OPENAI_API_KEY:?OPENAI_API_KEY is required. Run make bootstrap or set it in .env}"; \
	echo "Starting oMLX on http://$${MODEL_BIND_HOST}:$${OMLX_PORT} using $${MODEL_DIR}"; \
	omlx serve --model-dir "$${MODEL_DIR}" --host "$${MODEL_BIND_HOST}" --port "$${OMLX_PORT}" --api-key "$${OPENAI_API_KEY}"

model-start-lmstudio:
	@set -a; [ -f .env ] && source .env; set +a; \
	: "$${LMSTUDIO_PORT:=1234}"; \
	: "$${MODEL_BIND_HOST:=0.0.0.0}"; \
	if [ -x "$$HOME/.lmstudio/bin/lms" ]; then \
		"$$HOME/.lmstudio/bin/lms" server start --port "$${LMSTUDIO_PORT}" --bind "$${MODEL_BIND_HOST}"; \
	else \
		lms server start --port "$${LMSTUDIO_PORT}" --bind "$${MODEL_BIND_HOST}"; \
	fi

model-check:
	./scripts/doctor.sh --model-required

agents-install:
	./scripts/agents-install.sh

e2e-ready:
	./scripts/e2e-ready.sh

docker-build:
	./scripts/docker-build.sh

docker-create:
	./scripts/docker-create.sh

docker-start:
	./scripts/docker-control.sh start

docker-shell:
	./scripts/docker-control.sh shell

docker-stop:
	./scripts/docker-control.sh stop

docker-reset:
	./scripts/docker-control.sh reset

docker-e2e:
	./scripts/docker-e2e.sh

telegram-start:
	./scripts/telegram-control.sh start

telegram-stop:
	./scripts/telegram-control.sh stop

telegram-restart:
	./scripts/telegram-control.sh restart

telegram-status:
	./scripts/telegram-control.sh status

telegram-logs:
	./scripts/telegram-control.sh logs

telegram-pairing:
	./scripts/telegram-control.sh pairing

telegram-approve:
	./scripts/telegram-control.sh approve

telegram-doctor:
	./scripts/telegram-control.sh doctor

telegram-stop-host:
	./scripts/telegram-control.sh stop-host

dashboard-start:
	./scripts/dashboard-control.sh start

dashboard-stop:
	./scripts/dashboard-control.sh stop

dashboard-restart:
	./scripts/dashboard-control.sh restart

dashboard-status:
	./scripts/dashboard-control.sh status

dashboard-logs:
	./scripts/dashboard-control.sh logs

dashboard-open:
	./scripts/dashboard-control.sh open

dashboard-tailscale-start:
	./scripts/dashboard-remote.sh tailscale-start

dashboard-tailscale-stop:
	./scripts/dashboard-remote.sh tailscale-stop

dashboard-tailscale-status:
	./scripts/dashboard-remote.sh tailscale-status

dashboard-cloudflare-start:
	./scripts/dashboard-remote.sh cloudflare-start

dashboard-cloudflare-stop:
	./scripts/dashboard-remote.sh cloudflare-stop

dashboard-cloudflare-status:
	./scripts/dashboard-remote.sh cloudflare-status

release-check:
	./scripts/release-check.sh

vm-create:
	./scripts/vm-create.sh

vm-start:
	./scripts/vm-control.sh start

vm-stop:
	./scripts/vm-control.sh stop

vm-ssh:
	./scripts/vm-control.sh ssh

vm-snapshot:
	./scripts/vm-control.sh snapshot

vm-reset:
	./scripts/vm-control.sh reset

vm-status:
	./scripts/vm-control.sh status

vm-list-snapshots:
	./scripts/vm-control.sh list-snapshots
