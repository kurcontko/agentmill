.PHONY: init build run watch interactive agents clean

# One-command setup: creates .env and builds the image
init:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env — edit it to add your API key and REPO_PATH"; \
	else \
		echo ".env already exists"; \
	fi
	@if [ ! -f prompts/TASK.md.example ]; then \
		echo "Warning: prompts/TASK.md.example not found"; \
	else \
		echo "Copy prompts/TASK.md.example to your repo as TASK.md and fill it in"; \
	fi

build:
	docker build -t agentmill .

# Single-agent modes
run: build
	docker compose up headless

watch: build
	docker compose run watch

interactive: build
	docker compose run interactive

# Multi-agent
agents: build
	docker compose up agent-1 agent-2 agent-3

# Cleanup
clean:
	docker compose down --remove-orphans
