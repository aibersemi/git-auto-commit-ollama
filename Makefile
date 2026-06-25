PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
SRC_DIR = $(shell pwd)

.PHONY: help install uninstall

help:
	@echo "Usage:"
	@echo "  make install   - Membuat symlink git-ai ke $(BINDIR) (membutuhkan akses sudo)"
	@echo "  make uninstall - Menghapus symlink git-ai dari $(BINDIR) (membutuhkan akses sudo)"

install:
	@echo "Membuat symlink git-ai di $(BINDIR)..."
	sudo mkdir -p $(BINDIR)
	sudo ln -sf $(SRC_DIR)/git-ai.sh $(BINDIR)/git-ai
	sudo ln -sf $(SRC_DIR)/git-ai.conf $(BINDIR)/git-ai.conf
	sudo chmod +x $(SRC_DIR)/git-ai.sh
	@echo "Symlink berhasil dibuat! Jalankan 'git-ai' dari mana saja."

uninstall:
	@echo "Menghapus git-ai dari $(BINDIR)..."
	sudo rm -f $(BINDIR)/git-ai
	sudo rm -f $(BINDIR)/git-ai.conf
	@echo "Berhasil dihapus."
