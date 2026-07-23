PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
SRC_DIR = $(shell pwd)

.PHONY: help install uninstall

help:
	@echo "Usage:"
	@echo "  make install   - Create git-ai symlinks in $(BINDIR) (requires sudo access)"
	@echo "  make uninstall - Remove git-ai symlinks from $(BINDIR) (requires sudo access)"

install:
	@echo "Creating git-ai symlinks in $(BINDIR)..."
	sudo mkdir -p $(BINDIR)
	sudo ln -sf $(SRC_DIR)/git-ai.sh $(BINDIR)/git-ai
	sudo ln -sf $(SRC_DIR)/git-ai.conf $(BINDIR)/git-ai.conf
	sudo chmod +x $(SRC_DIR)/git-ai.sh
	@echo "Symlinks created successfully! Run 'git-ai' from anywhere."

uninstall:
	@echo "Removing git-ai from $(BINDIR)..."
	sudo rm -f $(BINDIR)/git-ai
	sudo rm -f $(BINDIR)/git-ai.conf
	@echo "Removed successfully."
