TERRAFORM_CMD = terraform
ANSIBLE_CMD = ansible-playbook
ANSIBLE_DIR = config/ansible

# Compose file sets for the local stack. COMPOSE_FILE (colon-separated) is
# docker compose's native mechanism, and initdb.sh honours it too, so every
# target below operates on one consistent stack definition.
COMPOSE_FILES_DEV = docker-compose.yaml:config/docker-compose.overrides/dev.yaml
COMPOSE_FILES_DEBUG = $(COMPOSE_FILES_DEV):config/docker-compose.overrides/debug.yaml
COMPOSE_FILES_TEST = $(COMPOSE_FILES_DEBUG):config/docker-compose.overrides/test.yaml
COMPOSE_DEV = COMPOSE_FILE=$(COMPOSE_FILES_DEV) docker compose
COMPOSE_DEBUG = COMPOSE_FILE=$(COMPOSE_FILES_DEBUG) docker compose

env ?= null
tf_env = $(if $(filter $(env),staging prod),$(env),$(if $(filter $(env),null),staging,$(error Invalid environment: $(env))))
play_env = $(if $(filter $(env),staging prod),$(env),null)
args ?=

.PHONY: precommit infra infra-destroy play help env setup dev debug initdb \
	down clean test test-db test-api test-e2e

precommit:
	pre-commit run --all-files

# Create local configuration from templates. Guarded: never overwrites
# existing files, so it is safe on dev machines and deployed servers alike.
env:
	@test -f .env || { cp .env.tpl .env && echo "Created .env from .env.tpl"; }
	@mkdir -p keys
	@test -f keys/jwt-secret || printf 'Dummy5ecr3t4D3bug0n1yN0T4Pr0D123' > keys/jwt-secret

# From nothing to a running debug-mode stack with a bootstrapped database.
setup:
	$(MAKE) env
	$(MAKE) initdb
	$(MAKE) debug

dev:
	$(COMPOSE_DEV) up -d --build

debug:
	$(COMPOSE_DEBUG) up -d --build

initdb:
	COMPOSE_FILE=$(COMPOSE_FILES_DEBUG) ./initdb.sh --dev-logging

down:
	$(COMPOSE_DEBUG) down

clean:
	$(COMPOSE_DEBUG) down -v --remove-orphans
	for suite in db api e2e; do \
		COMPOSE_PROJECT_NAME=dtrack-test-$$suite \
		COMPOSE_FILE=$(COMPOSE_FILES_TEST) \
		docker compose down -v --remove-orphans; \
	done

# Each suite provisions its own isolated environment (needs only `make env`
# beforehand); `make test` runs all three in parallel. See docs/testing.md.
test:
	./tests/run-all.sh

test-db:
	./tests/run-db-tests.sh

test-api:
	./tests/run-api-tests.sh

test-e2e:
	./tests/run-e2e-tests.sh

# Revive a suite's stopped test environment (data intact in its volume),
# e.g. `make test-up-api`.
test-up-%:
	TEST_SUITE=$* ./tests/test-env.sh

infra-init:
	$(TERRAFORM_CMD) init -backend-config=backend.tfconf

infra:
	$(TERRAFORM_CMD) workspace select -or-create $(tf_env) && $(TERRAFORM_CMD) apply

infra-destroy:
	$(TERRAFORM_CMD) workspace select -or-create $(tf_env) && $(TERRAFORM_CMD) destroy

play:
	@if [ "$(play_env)" = "null" ]; then \
		cd $(ANSIBLE_DIR) && $(ANSIBLE_CMD) base.playbook.yml $(args); \
	else \
		cd $(ANSIBLE_DIR) && $(ANSIBLE_CMD) base.playbook.yml -l $(play_env) $(args); \
	fi

help:
	@echo "Available targets:"
	@echo "  setup          One command from clone to running stack: env + initdb + debug."
	@echo "  env            Create .env and keys/jwt-secret from templates (never overwrites)."
	@echo "  dev            Start the local stack in dev mode (real Azure AD login)."
	@echo "  debug          Start the local stack in debug mode (local JWT login, no Azure)."
	@echo "  initdb         Bootstrap the database (idempotent; ./initdb.sh --force recreates)."
	@echo "  down           Stop the local stack (data is kept)."
	@echo "  clean          Stop the dev and test stacks and delete their data volumes."
	@echo "  test           Run all test suites in parallel, each in its own freshly"
	@echo "                   recreated isolated environment (needs only .env)."
	@echo "  test-db        Run the pgTAP database tests."
	@echo "  test-api       Run the HTTP tests against PostgREST."
	@echo "  test-e2e       Run the Playwright end-to-end tests."
	@echo "  test-up-<s>    Revive suite <s>'s stopped test environment for inspection"
	@echo "                   (db|api|e2e); its last run's data is still in the volume."
	@echo "  precommit      Manually run pre-commit hooks on all files."
	@echo "  infra-init     Initialize Terraform with backend configuration."
	@echo "  infra          Apply infrastructure configuration using Terraform."
	@echo "                   Usage: make infra [env={staging|prod}(default: staging)]"
	@echo "  infra-destroy  Destroy infrastructure configured by Terraform."
	@echo "                   Usage: make infra-destroy [env={staging|prod}(default: staging)]"
	@echo "  play           Run Ansible playbook for optionally selected environments."
	@echo "                   Usage: make play [env={staging|prod}(default: all)]"
	@echo ""
	@echo "Optional argument:"
	@echo "  env            Specifies the environment to target. Acceptable values are staging or prod."
