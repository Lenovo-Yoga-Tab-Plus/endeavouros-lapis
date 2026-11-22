# EndeavourOS lapis image builder
#
# Usage:
#   make builder          Build the Docker builder image
#   make plasma           Build the Plasma desktop image
#   make gnome            Build the GNOME desktop image
#   make all              Build both desktop images
#   make clean            Remove generated images

SHELL := /bin/bash
BUILDER_IMAGE := lapis-endeavouros-builder
BUILDER_DIR := lapis-endeavouros-builder
IMAGES_DIR := images
DOCKER_RUN := docker run --rm --privileged \
	-v "$(CURDIR)/$(IMAGES_DIR):/build/images" \
	-v /dev:/dev \
	-e BUILD_GIT_REV="$(BUILD_GIT_REV)" \
	-e LAPIS_REPO_URL="$(LAPIS_REPO_URL)" \
	-e LAPIS_REPO_NAME="$(LAPIS_REPO_NAME)" \
	$(BUILDER_IMAGE)

# Propagate git revision when building locally; CI sets BUILD_GIT_REV explicitly.
BUILD_GIT_REV ?= $(shell git rev-parse --short HEAD 2>/dev/null || true)
LAPIS_REPO_URL ?=
LAPIS_REPO_NAME ?=

.PHONY: help builder plasma gnome all clean check-docker

help:
	@echo "EndeavourOS lapis image builder"
	@echo
	@echo "Targets:"
	@echo "  builder   Build the Docker builder image"
	@echo "  plasma    Build the Plasma desktop image"
	@echo "  gnome     Build the GNOME desktop image"
	@echo "  all       Build both desktop images"
	@echo "  clean     Remove generated images"
	@echo
	@echo "Environment variables:"
	@echo "  LAPIS_REPO_URL     Override the lapis-pkgs pacman repo URL"
	@echo "  LAPIS_REPO_NAME    Override the lapis-pkgs repo section name"
	@echo "  BUILD_GIT_REV      Git revision stamped into build metadata"

check-docker:
	@command -v docker >/dev/null || { echo "docker is required but not installed."; exit 1; }

builder: check-docker
	docker build $(BUILDER_DIR) -t $(BUILDER_IMAGE)

$(IMAGES_DIR):
	mkdir -p $(IMAGES_DIR)

plasma gnome: builder $(IMAGES_DIR)
	$(DOCKER_RUN) $@

all: plasma gnome

clean:
	rm -rf $(IMAGES_DIR)/*
