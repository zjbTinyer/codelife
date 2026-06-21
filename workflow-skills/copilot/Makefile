# ============================================================
# Workflow Skills Makefile
# ============================================================
# 用法:
#   make gate                          MR 前检查
#   make coverage                      覆盖率分析 (80%)
#   make coverage-gen                  覆盖率分析 + 生成测试
#   make scan-fix                      扫描自动修复（预览）
#   make scan-fix-apply                扫描自动修复（执行）
#   make deploy-check ENV=dev          部署后验证
#   make db-diagnose INSTANCE=project:region:pg DB=orderdb
#   make db-diagnose-key KEY=~/gcp-keys/prod.json DB=orderdb
#   make db-keys                       列出 GCP SA Key
#   make jenkins-log JOB=order-service
#   make jenkins-log-build JOB=order-service BUILD=1234
# ============================================================

SKILLS_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))/skills
ENV ?= dev
DB ?= postgres
INSTANCE ?=
KEY ?=
JOB ?=
BUILD ?= last
SONAR_URL ?= https://sonarqube.company.com
SONAR_PROJECT_KEY ?=

.PHONY: gate coverage coverage-gen scan scan-fix scan-fix-apply deploy-check db-diagnose db-diagnose-key db-keys jenkins-log jenkins-log-build

# === 开发阶段 ===

gate:
	@$(SKILLS_DIR)/pre-mr-gate.sh

coverage:
	@$(SKILLS_DIR)/coverage-hunt.py 80

coverage-gen:
	@$(SKILLS_DIR)/coverage-hunt.py 80 --generate-tests --dry-run

# === 扫描阶段 ===

scan:
	@test -n "$(SONAR_PROJECT_KEY)" || { echo "请设置 SONAR_PROJECT_KEY=com.company:your-service"; exit 1; }
	@$(SKILLS_DIR)/scan-triage.py --sonar-url $(SONAR_URL) --sonar-project-key $(SONAR_PROJECT_KEY)

scan-fix:
	@test -n "$(SONAR_PROJECT_KEY)" || { echo "请设置 SONAR_PROJECT_KEY"; exit 1; }
	@$(SKILLS_DIR)/scan-triage.py --sonar-url $(SONAR_URL) --sonar-project-key $(SONAR_PROJECT_KEY) --auto-fix --dry-run

scan-fix-apply:
	@test -n "$(SONAR_PROJECT_KEY)" || { echo "请设置 SONAR_PROJECT_KEY"; exit 1; }
	@$(SKILLS_DIR)/scan-triage.py --sonar-url $(SONAR_URL) --sonar-project-key $(SONAR_PROJECT_KEY) --auto-fix

# === 部署阶段 ===

deploy-check:
	@$(SKILLS_DIR)/deploy-guard.sh $(ENV)

# === 数据库 ===

db-keys:
	@$(SKILLS_DIR)/db-inspect.sh --list-keys

db-diagnose:
	@test -n "$(INSTANCE)" || { echo "请设置 INSTANCE=project:region:pg"; exit 1; }
	@$(SKILLS_DIR)/db-inspect.sh --gcp-instance $(INSTANCE) --db $(DB) --diagnose

db-diagnose-key:
	@test -n "$(KEY)" || { echo "请设置 KEY=~/gcp-keys/sa.json"; exit 1; }
	@$(SKILLS_DIR)/db-inspect.sh --gcp-key $(KEY) --db $(DB) --diagnose

db-tables:
	@test -n "$(INSTANCE)" || { echo "请设置 INSTANCE"; exit 1; }
	@$(SKILLS_DIR)/db-inspect.sh --gcp-instance $(INSTANCE) --db $(DB) --tables

db-monitor:
	@test -n "$(INSTANCE)" || { echo "请设置 INSTANCE"; exit 1; }
	@$(SKILLS_DIR)/db-inspect.sh --gcp-instance $(INSTANCE) --db $(DB) --monitor

# === Jenkins ===

jenkins-log:
	@test -n "$(JOB)" || { echo "请设置 JOB=order-service"; exit 1; }
	@$(SKILLS_DIR)/jenkins-debug.sh --job $(JOB) --build $(BUILD)

jenkins-log-build:
	@test -n "$(JOB)" || { echo "请设置 JOB=order-service"; exit 1; }
	@test -n "$(BUILD)" || { echo "请设置 BUILD=1234"; exit 1; }
	@$(SKILLS_DIR)/jenkins-debug.sh --job $(JOB) --build $(BUILD)
