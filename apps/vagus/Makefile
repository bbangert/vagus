# Builds priv/vagus_walk for elixir_make. Nerves exports CC/CFLAGS/LDFLAGS
# for the target toolchain during a firmware build; the host falls back to cc.
ifeq ($(MIX_APP_PATH),)
calling_from_make:
	mix compile
endif

PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

CFLAGS ?= -O2 -Wall -Wextra -pedantic
CFLAGS += -std=c11

all: install

install: $(PREFIX)/vagus_walk

# Order-only, so the directory exists before the recipe even under -j, while
# its mtime (bumped by every file written into it) never forces a rebuild.
$(BUILD)/%.o: c_src/%.c | $(BUILD)
	@echo " CC $(notdir $@)"
	$(CC) -c $(CFLAGS) -o $@ $<

$(PREFIX)/vagus_walk: $(BUILD)/vagus_walk.o | $(PREFIX)
	@echo " LD $(notdir $@)"
	$(CC) $^ $(LDFLAGS) -o $@

$(PREFIX) $(BUILD):
	mkdir -p $@

mix_clean:
	$(RM) $(PREFIX)/vagus_walk $(BUILD)/*.o

clean:
	mix clean

.PHONY: all clean mix_clean calling_from_make install

.SILENT:
