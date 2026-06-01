SHELL := /bin/bash

.PHONY: help bootstrap setup doctor clean-all release-check ci-check matrix-e2e \
	models-search models-list models-sync models-doctor models-prune-incomplete model-select model-start-bg model-stop-bg model-check omlx-update \
	rag-install rag-preflight rag-index rag-sync rag-search rag-start rag-stop rag-status rag-doctor rag-up rag-down rag-logs rag-index-status rag-update \
	agent-start agent-stop agent-restart agent-pause agent-switch agent-status agent-logs agent-shell agent-open-dashboard agent-update agent-data

help:
	@printf '%s\n' 'mlx-to-isolated-agent commands'
	@printf '\n%s\n' 'Setup and health:'
	@printf '  %-24s %s\n' 'make bootstrap' 'Install/verify macOS host dependencies'
	@printf '  %-24s %s\n' 'make setup' 'Interactive end-to-end setup wizard'
	@printf '  %-24s %s\n' 'make doctor' 'Host dependency and service diagnostics'
	@printf '  %-24s %s\n' 'make clean-all' 'Remove sandbox runtime state, keep secrets/models'
	@printf '\n%s\n' 'Models:'
	@printf '  %-24s %s\n' 'make models-search' 'Open LM Studio MLX model search'
	@printf '  %-24s %s\n' 'make models-list' 'List local LM Studio models'
	@printf '  %-24s %s\n' 'make model-select' 'Select the model served by oMLX'
	@printf '  %-24s %s\n' 'make model-start-bg' 'Start host oMLX service'
	@printf '  %-24s %s\n' 'make omlx-update' 'Upgrade oMLX and restart its launchd service'
	@printf '\n%s\n' 'RAG:'
	@printf '  %-24s %s\n' 'make rag-preflight' 'Verify Docker RAG images before pulling'
	@printf '  %-24s %s\n' 'make rag-sync' 'Index source and start RAG service'
	@printf '  %-24s %s\n' 'make rag-search QUERY=...' 'Search local RAG'
	@printf '  %-24s %s\n' 'make rag-index-status' 'Show indexing progress (files done, %)'
	@printf '  %-24s %s\n' 'make rag-up' 'Start Dockerized RAG'
	@printf '  %-24s %s\n' 'make rag-down' 'Stop Dockerized RAG'
	@printf '  %-24s %s\n' 'make rag-update' 'Pull latest Docker RAG images and restart stack'
	@printf '\n%s\n' 'Agents:'
	@printf '  %-24s %s\n' 'make agent-start' 'Start selected Hermes/OpenClaw stack'
	@printf '  %-24s %s\n' 'make agent-status' 'Show active agent state'
	@printf '  %-24s %s\n' 'make agent-update' 'Pull latest image and restart agent'
	@printf '  %-24s %s\n' 'make agent-data' 'Show agent data directory on host'
	@printf '  %-24s %s\n' 'make agent-open-dashboard' 'Open Dashboard/Control UI'
	@printf '  %-24s %s\n' 'make agent-shell' 'Shell into selected sandbox'
	@printf '\n%s\n' 'Release:'
	@printf '  %-24s %s\n' 'make ci-check' 'Fast local CI-equivalent checks'
	@printf '  %-24s %s\n' 'make release-check' 'Full local release gate'

bootstrap:
	./scripts/bootstrap-macos.sh

setup:
	./scripts/setup.sh

doctor:
	./scripts/doctor.sh

clean-all:
	./scripts/clean-all.sh

release-check:
	./scripts/release-check.sh

ci-check:
	SKIP_HOST_DOCTOR=1 SKIP_RAG_E2E=1 SKIP_DOCKER_E2E=1 ./scripts/release-check.sh
	RAG_EMBEDDING_BACKEND=hash MATRIX_MODES=" " MATRIX_CLEAN_MODE=none MATRIX_REPORT_DIR=.runtime/matrix-e2e/ci-synthetic ./scripts/matrix-e2e.sh
	./scripts/test-openclaw-docker-command-mock.sh
	./scripts/test-wizard.sh


matrix-e2e:
	./scripts/matrix-e2e.sh

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

models-doctor:
	./scripts/models-doctor.py

models-prune-incomplete:
	./scripts/models-doctor.py --delete

model-select:
	./scripts/model-select.sh

model-start-bg:
	./scripts/model-start-omlx-bg.sh

model-stop-bg:
	./scripts/model-stop-omlx-bg.sh

model-check:
	./scripts/doctor.sh --model-required

omlx-update:
	./scripts/omlx-update.sh

rag-install:
	./scripts/rag-control.sh install

rag-preflight:
	./scripts/rag-control.sh preflight

rag-index:
	./scripts/rag-control.sh index

rag-sync:
	./scripts/rag-control.sh sync

rag-search:
	@test -n "$(QUERY)" || (echo 'Usage: make rag-search QUERY="your query"' >&2; exit 2)
	./scripts/rag-control.sh search "$(QUERY)"

rag-start:
	./scripts/rag-control.sh start

rag-stop:
	./scripts/rag-control.sh stop

rag-status:
	./scripts/rag-control.sh status

rag-doctor:
	./scripts/rag-control.sh doctor

rag-up:
	RAG_RUNTIME=docker ./scripts/rag-control.sh start

rag-down:
	RAG_RUNTIME=docker ./scripts/rag-control.sh stop

rag-logs:
	RAG_RUNTIME=docker ./scripts/rag-control.sh logs

rag-index-status:
	./scripts/rag-control.sh index-status

rag-update:
	RAG_DOCKER_PULL_POLICY=always ./scripts/rag-control.sh install
	@if docker container inspect mlx-isolated-rag >/dev/null 2>&1 && [ "$$(docker inspect -f '{{.State.Running}}' mlx-isolated-rag 2>/dev/null)" = "true" ]; then \
		echo "Recreating and restarting running RAG stack..."; \
		./scripts/rag-control.sh start; \
	fi

agent-start:
	./scripts/agent-control.sh start

agent-stop:
	./scripts/agent-control.sh stop

agent-restart:
	./scripts/agent-control.sh restart

agent-pause:
	./scripts/agent-control.sh pause

agent-switch:
	AGENT_CONFLICT_POLICY=pause AGENT_PERSIST_SELECTION=1 ./scripts/agent-control.sh start

agent-status:
	./scripts/agent-control.sh status

agent-logs:
	./scripts/agent-control.sh logs

agent-shell:
	./scripts/agent-control.sh shell

agent-open-dashboard:
	./scripts/agent-control.sh open-dashboard

agent-update:
	./scripts/agent-control.sh update

agent-data:
	./scripts/docker-control.sh data-path
