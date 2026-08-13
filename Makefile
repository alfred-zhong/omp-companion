APP_NAME := omp-companion
BUILD_DIR := build
CONFIG ?= release

.PHONY: all build run test clean

all: build

build:
	@./build.sh

run: build
	@open ${BUILD_DIR}/${APP_NAME}.app

test:
	@swift run omp-companion --self-check

clean:
	@rm -rf ${BUILD_DIR} .build
