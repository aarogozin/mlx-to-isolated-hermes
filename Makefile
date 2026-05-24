SHELL := /bin/bash

.PHONY: bootstrap setup doctor clean-all release-check \
	models-search models-list models-sync models-doctor models-prune-incomplete model-select model-start-bg model-stop-bg model-check \
	agent-start agent-stop agent-restart agent-pause agent-switch agent-status agent-logs agent-shell agent-open-dashboard \
	dashboard-remote-start dashboard-remote-stop dashboard-remote-status \
	vm-create vm-start vm-stop vm-ssh vm-snapshot vm-reset vm-destroy vm-status \
	shared-mounts-sync shared-mounts-status shared-mounts-check

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

dashboard-remote-start:
	./scripts/dashboard-remote.sh tailscale-start

dashboard-remote-stop:
	./scripts/dashboard-remote.sh tailscale-stop

dashboard-remote-status:
	./scripts/dashboard-remote.sh tailscale-status

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

vm-destroy:
	./scripts/vm-control.sh destroy

vm-status:
	./scripts/vm-control.sh status

shared-mounts-sync:
	./scripts/shared-mounts.sh sync

shared-mounts-status:
	./scripts/shared-mounts.sh status

shared-mounts-check:
	./scripts/shared-mounts-check.sh
