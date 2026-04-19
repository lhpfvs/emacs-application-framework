# Makefile – EAF macOS NSView + in-process Python embedding module
#
# Usage:
#   make              – build eaf-macos-module.so
#   make clean        – remove build artefact
#   make install      – build in place under core/macos
#
# Requirements:
#   • macOS with Xcode Command Line Tools
#   • Emacs.app at /Applications/Emacs.app  (or override EMACS_APP)
#   • Python 3 from Homebrew  (or override PYTHON)

# ── Paths ─────────────────────────────────────────────────────────────────────

EMACS_APP  ?= /Applications/Emacs.app
EMACS_INC  := $(EMACS_APP)/Contents/Resources/include

# Use the same Python that the EAF venv is based on.
PYTHON     ?= /opt/homebrew/bin/python3
PY_INC     := $(shell $(PYTHON) -c "import sysconfig; print(sysconfig.get_config_var('INCLUDEPY'))")
PY_LIBDIR  := $(shell $(PYTHON) -c "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))")
PY_VER     := $(shell $(PYTHON) -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

# ── Compiler / flags ───────────────────────────────────────────────────────────

CC       := clang
CFLAGS   := -fobjc-arc -fPIC \
             -I"$(EMACS_INC)" \
             -I"$(PY_INC)" \
             -framework Cocoa

LDFLAGS  := -bundle -framework Cocoa \
             -L"$(PY_LIBDIR)" -lpython$(PY_VER)

# ── Sources / target ──────────────────────────────────────────────────────────

TARGET  := eaf-macos-module.so
SOURCES := eaf_macos_module.m eaf_host_view.m
HEADERS := eaf_host_view.h

# ── Rules ─────────────────────────────────────────────────────────────────────

.PHONY: all clean install

all: $(TARGET)

$(TARGET): $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(SOURCES) -o $(TARGET) $(LDFLAGS)
	@echo "Built $(TARGET)  (Python $(PY_VER) @ $(PY_LIBDIR))"

clean:
	rm -f $(TARGET)

install: $(TARGET)
	@echo "Module ready → $(CURDIR)/$(TARGET)"
