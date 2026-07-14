TERRAFORM_CMD = terraform
ANSIBLE_CMD = ansible-playbook
ANSIBLE_DIR = config/ansible

COMPOSE_DEV = docker compose -f docker-compose.yaml \
	-f config/docker-compose.overrides/dev.yaml
COMPOSE_DEBUG = $(COMPOSE_DEV) \
	-f config/docker-compose.overrides/debug.yaml

env ?= null
tf_env = $(if $(filter $(env),staging prod),$(env),$(if $(filter $(env),null),staging,$(error Invalid environment: $(env))))
play_env = $(if $(filter $(env),staging prod),$(env),null)
args ?=

.PHONY: precommit infra infra-destroy play help dev debug initdb down clean

precommit:
	pre-commit run --all-files

dev:
	$(COMPOSE_DEV) up -d --build

debug:
	$(COMPOSE_DEBUG) up -d --build

initdb:
	./initdb.sh

down:
	$(COMPOSE_DEBUG) down

clean:
	$(COMPOSE_DEBUG) down -v --remove-orphans

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
	@echo "  dev            Start the local stack in dev mode (real Azure AD login)."
	@echo "  debug          Start the local stack in debug mode (local JWT login, no Azure)."
	@echo "  initdb         Bootstrap the database (runs ./initdb.sh)."
	@echo "  down           Stop the local stack (data is kept)."
	@echo "  clean          Stop the local stack and delete its data volume."
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
