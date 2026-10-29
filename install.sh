#!/bin/sh
# Install dsh-plugin-model-request-accelerator into a DSH profile.
#
#   curl -fsSL https://raw.githubusercontent.com/No-ni/dsh-plugin-model-request-accelerator/main/install.sh | sh
#
# Clones the plugin next to the profile's other plugins and registers it in the
# profile's patch layer. Safe to re-run: an existing checkout is fast-forwarded,
# an already-registered entry is left alone, and settings it has already migrated
# (or you have since edited) are never overwritten. Upgrading from 1.7.x carries
# your old settings across automatically — see scripts/migrate-legacy-settings.mjs.
#
# Environment overrides:
#   DSH_HOME     DSH home directory       (default: $HOME/.dsh)
#   DSH_PROFILE  profile to install into  (default: web)

set -eu

REPO_URL="https://github.com/No-ni/dsh-plugin-model-request-accelerator.git"
PLUGIN_ID="model-request-accelerator"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_PROFILE="${DSH_PROFILE:-web}"
PROFILE_DIR="$DSH_HOME/profiles/$DSH_PROFILE"
PATCH_FILE="$PROFILE_DIR/cordis.patch.yml"
TARGET_DIR="$PROFILE_DIR/plugins/$PLUGIN_ID"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$PROFILE_DIR" ] || die "no profile \"$DSH_PROFILE\" at $PROFILE_DIR (set DSH_HOME / DSH_PROFILE?)"
[ -f "$PROFILE_DIR/package.json" ] || die "$PROFILE_DIR is not a dsh profile (no package.json)"
command -v git >/dev/null 2>&1 || die "git is required but was not found on PATH"
command -v node >/dev/null 2>&1 || die "node is required but was not found on PATH"

# The row's name is the absolute file URL dsh itself normalizes a patch-relative name
# into. Registering the relative form leaves the settings page unable to save the row;
# scripts/fix-row-name.mjs carries the full explanation. `node` performs the conversion
# so that a path needing percent-encoding -- a space in $HOME, say -- becomes the very
# URL dsh composes, which is what patch matching compares against.
ROW_NAME="$(node -e 'process.stdout.write(require("node:url").pathToFileURL(process.argv[1]).href)' "$TARGET_DIR/lib/index.js")"

if [ -d "$TARGET_DIR/.git" ]; then
	say "==> updating $TARGET_DIR"
	git -C "$TARGET_DIR" pull --ff-only --quiet
elif [ -e "$TARGET_DIR" ]; then
	die "$TARGET_DIR exists but is not a git checkout; remove it and re-run"
else
	say "==> cloning into $TARGET_DIR"
	mkdir -p "$(dirname "$TARGET_DIR")"
	git clone --quiet --depth 1 "$REPO_URL" "$TARGET_DIR"
fi

[ -e "$PATCH_FILE" ] || {
	say "==> creating $PATCH_FILE"
	printf '# Your patch layer for the %s profile.\n' "$DSH_PROFILE" >"$PATCH_FILE"
}

# Register the plugin, unless it is already registered. Registration is separate from
# configuration: this only guarantees the row exists, which is also what the migration
# below needs in order to have somewhere to write.
register_row() {
	if grep -qE "^[[:space:]]*-[[:space:]]*id:[[:space:]]*(dsh-plugin-)?${PLUGIN_ID}[[:space:]]*\$" "$PATCH_FILE" 2>/dev/null; then
		say "==> $PATCH_FILE already registers $PLUGIN_ID; leaving it as is"
		return
	fi
	# A pristine patch layer is comments followed by an empty array. Appending a
	# sequence entry after `[]` produces a file a YAML parser rejects — it reads one
	# document that is both an empty array and a block sequence — so the empty array
	# is removed first and the entry takes its place. Comments are left alone.
	if [ "$(sed 's/#.*$//' "$PATCH_FILE" | sed 's/^---//' | tr -d '[:space:]')" = "[]" ]; then
		say "==> $PATCH_FILE is still an empty array; replacing it with the entry"
		grep -vE '^[[:space:]]*\[\][[:space:]]*$' "$PATCH_FILE" >"$PATCH_FILE.tmp" || true
		mv "$PATCH_FILE.tmp" "$PATCH_FILE"
	fi
	say "==> registering $PLUGIN_ID in $PATCH_FILE"
	{
		printf '\n'
		printf '# Model request acceleration: request-body compression, pre-transmission of the\n'
		printf '# shared history, and a request-timing breakdown (Settings > Plugins).\n'
		printf -- '- insert:\n'
		printf '    - id: %s\n' "$PLUGIN_ID"
		printf "      name: '%s'\n" "$ROW_NAME"
		printf '      config: {}\n'
	} >>"$PATCH_FILE"
}

register_row

# Rewrite the name of a row an earlier release registered with a patch-relative path.
# dsh composes that path into an absolute file URL, but the settings page restates the
# row's own, un-normalized name when it saves, so the write never matched and the page
# refused with "Configuration for ... is overridden by a home patch or command-line
# overlay". Re-running this script is the documented repair; exit code 3 means the row
# was already named correctly and there was nothing to do.
if [ -f "$TARGET_DIR/scripts/fix-row-name.mjs" ]; then
	repaired=0
	node "$TARGET_DIR/scripts/fix-row-name.mjs" "$PATCH_FILE" "$PLUGIN_ID" "$ROW_NAME" || repaired=$?
	if [ "$repaired" = "0" ]; then
		say "==> rewrote $PLUGIN_ID's patch-relative row name to $ROW_NAME"
	elif [ "$repaired" != "3" ]; then
		die "could not rewrite $PLUGIN_ID's row name in $PATCH_FILE"
	fi
fi

# Carry settings over from a 1.7.x install. Those releases kept them in
# $DSH_HOME/settings.yaml, keyed by the plugin's section id; 2.0 reads them from this
# row's `config` instead, and dsh's own migration left this plugin's section behind
# (it only imports sections whose plugin registered a `Config`, and 1.7.x registered
# none). So an upgrade boots with every default and the settings page has no row to
# write to. The migrator moves the stranded section into the row, and leaves a row that
# already carries settings alone. Exit code 3 means there was nothing to migrate.
if [ -f "$TARGET_DIR/scripts/migrate-legacy-settings.mjs" ]; then
	migrated=0
	node "$TARGET_DIR/scripts/migrate-legacy-settings.mjs" --as-command \
		--dsh-home "$DSH_HOME" --profile "$DSH_PROFILE" --plugin-id "$PLUGIN_ID" || migrated=$?
	if [ "$migrated" = "1" ]; then
		say "==> could not migrate settings from an older version; your settings are unchanged,"
		say "    and the settings page will show this plugin's defaults."
	fi
fi

say ""
say "Installed into the \"$DSH_PROFILE\" profile."
say "  1. Reload your browser tab - the settings card arrives with the page's module graph."
say "  2. Open Settings > Plugins > Configuration and enable the providers you want."
say "Every provider starts disabled; confirm your gateway accepts content-encoding: br or"
say "gzip before enabling compression for the provider serving your current session."
say ""
say "Re-running this script updates an existing install: it fast-forwards the checkout and"
say "leaves your settings alone. The settings card shows the version and can update too."
