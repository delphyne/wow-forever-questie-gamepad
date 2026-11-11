# Symlink the QuestieGamepad addon into the WoW: Forever AddOns folder so edits apply on /reload.
WOW_ADDONS ?= /Applications/World of Warcraft/_forever_/Interface/AddOns
NAME        = QuestieGamepad

.PHONY: install uninstall check

install:
	mkdir -p "$(WOW_ADDONS)"
	ln -sfn "$(CURDIR)/$(NAME)" "$(WOW_ADDONS)/$(NAME)"
	@echo "Linked $(WOW_ADDONS)/$(NAME) -> $(CURDIR)/$(NAME)"

uninstall:
	rm -f "$(WOW_ADDONS)/$(NAME)"

check:
	luajit -bl $(NAME)/$(NAME).lua > /dev/null && echo "syntax ok"
