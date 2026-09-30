#!/usr/bin/env bash
# Enable or restore this clone's main-worktree bot commit identity.
set -euo pipefail

PROGRAM="main-identity-core.sh"

usage() {
	cat <<'EOF'
Usage:
	main-identity-core.sh override --confirm [<repo-dir>]
	main-identity-core.sh restore --confirm [<repo-dir>]

Both operations require explicit confirmation. The override is persistent and
applies to commits made in this repository's main worktree until restored.
EOF
}

fail() {
	printf '%s: ERROR: %s\n' "$PROGRAM" "$1" >&2
	exit 1
}

COMMAND="${1:-}"
if [ -n "$COMMAND" ]; then shift; fi
CONFIRMED=0
REPO_ARG=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--confirm) CONFIRMED=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		usage >&2
		fail "unknown option: $1"
		;;
	*)
		if [ -n "$REPO_ARG" ]; then
			usage >&2
			fail "unexpected argument: $1"
		fi
		REPO_ARG="$1"
		;;
	esac
	shift
done

case "$COMMAND" in
override | restore) ;;
*)
	usage >&2
	fail "choose override or restore"
	;;
esac
[ "$CONFIRMED" -eq 1 ] || fail "explicit user approval is required (--confirm)"

if [ -n "$REPO_ARG" ]; then
	REPO_PATH="$(cd "$REPO_ARG" 2>/dev/null && pwd -P)" || fail "not a directory: $REPO_ARG"
else
	REPO_PATH="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a Git worktree"
fi
MAIN_ROOT="$(git -C "$REPO_PATH" rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a Git worktree"
GIT_DIR="$(git -C "$MAIN_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || fail "cannot resolve Git directory"
COMMON_DIR="$(git -C "$MAIN_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || fail "cannot resolve shared Git directory"
[ "$GIT_DIR" = "$COMMON_DIR" ] || fail "this operation is only for the main worktree; run it from the main worktree, not a linked worktree"

LOCAL_CONFIG="$COMMON_DIR/config"
BOT_CONFIG="$COMMON_DIR/agent-bot-identity.config"
BACKUP_CONFIG="$COMMON_DIR/agent-main-identity.backup.config"
TEMP_CONFIG=""
cleanup() {
	if [ -n "$TEMP_CONFIG" ]; then rm -f "$TEMP_CONFIG"; fi
}
trap cleanup EXIT

[ -f "$LOCAL_CONFIG" ] || fail "repository-local Git config is missing"

# Read one direct local config value. Refuse multiple or multiline entries so
# restoration never has to guess how an unusual identity was represented.
read_local_value() {
	local key="$1" output rc
	if output="$(git config --file "$LOCAL_CONFIG" --get-all "$key" 2>/dev/null)"; then
		[[ "$output" != *$'\n'* ]] || fail "multiple or multiline $key entries found; refusing to change identity"
		READ_PRESENT=1
		READ_VALUE="$output"
	else
		rc=$?
		[ "$rc" -eq 1 ] || fail "could not read $key from repository-local config"
		READ_PRESENT=0
		READ_VALUE=""
	fi
}

write_local_value() {
	local key="$1" present="$2" value="$3" rc
	if [ "$present" -eq 1 ]; then
		git config --file "$LOCAL_CONFIG" --replace-all "$key" "$value" || return 1
	else
		if git config --file "$LOCAL_CONFIG" --unset-all "$key" >/dev/null 2>&1; then
			:
		else
			rc=$?
			[ "$rc" -eq 5 ] || return "$rc"
		fi
	fi
}

load_backup() {
	local version
	version="$(git config --file "$BACKUP_CONFIG" --get main-identity.version 2>/dev/null || true)"
	[ "$version" = "1" ] || fail "backup file is invalid or unsupported; preserve it and inspect it manually"
	BOT_NAME="$(git config --file "$BACKUP_CONFIG" --get main-identity.bot-name 2>/dev/null || true)"
	BOT_EMAIL="$(git config --file "$BACKUP_CONFIG" --get main-identity.bot-email 2>/dev/null || true)"
	ORIGINAL_NAME_PRESENT="$(git config --file "$BACKUP_CONFIG" --get main-identity.original-name-present 2>/dev/null || true)"
	ORIGINAL_EMAIL_PRESENT="$(git config --file "$BACKUP_CONFIG" --get main-identity.original-email-present 2>/dev/null || true)"
	ORIGINAL_NAME="$(git config --file "$BACKUP_CONFIG" --get main-identity.original-name 2>/dev/null || true)"
	ORIGINAL_EMAIL="$(git config --file "$BACKUP_CONFIG" --get main-identity.original-email 2>/dev/null || true)"
	[ -n "$BOT_NAME" ] && [ -n "$BOT_EMAIL" ] || fail "backup file has no bot identity; preserve it and inspect it manually"
	[[ "$ORIGINAL_NAME_PRESENT" == true || "$ORIGINAL_NAME_PRESENT" == false ]] || fail "backup file has invalid original-name-present state"
	[[ "$ORIGINAL_EMAIL_PRESENT" == true || "$ORIGINAL_EMAIL_PRESENT" == false ]] || fail "backup file has invalid original-email-present state"
}

write_backup() {
	local name_present="$1" name="$2" email_present="$3" email="$4"
	TEMP_CONFIG="$BACKUP_CONFIG.tmp.$$"
	[ ! -e "$TEMP_CONFIG" ] || fail "temporary backup already exists: $TEMP_CONFIG"
	(
		umask 077
		: >"$TEMP_CONFIG"
	) || fail "cannot create backup file"
	git config --file "$TEMP_CONFIG" main-identity.version 1
	git config --file "$TEMP_CONFIG" main-identity.bot-name "$BOT_NAME"
	git config --file "$TEMP_CONFIG" main-identity.bot-email "$BOT_EMAIL"
	git config --file "$TEMP_CONFIG" main-identity.original-name-present "$([ "$name_present" -eq 1 ] && printf true || printf false)"
	git config --file "$TEMP_CONFIG" main-identity.original-email-present "$([ "$email_present" -eq 1 ] && printf true || printf false)"
	if [ "$name_present" -eq 1 ]; then git config --file "$TEMP_CONFIG" main-identity.original-name "$name"; fi
	if [ "$email_present" -eq 1 ]; then git config --file "$TEMP_CONFIG" main-identity.original-email "$email"; fi
	[ ! -e "$BACKUP_CONFIG" ] || fail "backup file appeared during activation; refusing to overwrite it"
	mv "$TEMP_CONFIG" "$BACKUP_CONFIG" || fail "cannot install backup file"
	TEMP_CONFIG=""
}

restore_original() {
	local name_present email_present
	name_present=0
	email_present=0
	[ "$ORIGINAL_NAME_PRESENT" = true ] && name_present=1
	[ "$ORIGINAL_EMAIL_PRESENT" = true ] && email_present=1
	write_local_value user.name "$name_present" "$ORIGINAL_NAME" || return 1
	write_local_value user.email "$email_present" "$ORIGINAL_EMAIL" || return 1
}

state_matches_value() {
	local current_present="$1" current_value="$2" original_present="$3" original_value="$4" bot_value="$5"
	if [ "$current_present" -eq 1 ] && [ "$current_value" = "$bot_value" ]; then return 0; fi
	if [ "$original_present" = true ] && [ "$current_present" -eq 1 ] && [ "$current_value" = "$original_value" ]; then return 0; fi
	if [ "$original_present" = false ] && [ "$current_present" -eq 0 ]; then return 0; fi
	return 1
}

if [ "$COMMAND" = override ]; then
	[ -f "$BOT_CONFIG" ] || fail "bot identity is not configured; run agent-git-setup first"
	BOT_NAME="$(git config --file "$BOT_CONFIG" --get user.name 2>/dev/null || true)"
	BOT_EMAIL="$(git config --file "$BOT_CONFIG" --get user.email 2>/dev/null || true)"
	[ -n "$BOT_NAME" ] && [ -n "$BOT_EMAIL" ] || fail "persisted bot identity is incomplete; run agent-git-setup again"
	[[ "$BOT_NAME" != *$'\n'* && "$BOT_EMAIL" != *$'\n'* ]] || fail "persisted bot identity contains a newline; refusing to apply it"
	[[ "$BOT_EMAIL" =~ ^[1-9][0-9]*\+ ]] || fail "persisted bot email is not a numeric GitHub noreply address"
	[ "${BOT_EMAIL#*+}" = "$BOT_NAME@users.noreply.github.com" ] || fail "persisted bot name and noreply email do not match"

	if [ -f "$BACKUP_CONFIG" ]; then
		load_backup
		read_local_value user.name
		name_matches_bot=0
		[ "$READ_PRESENT" -eq 1 ] && [ "$READ_VALUE" = "$BOT_NAME" ] && name_matches_bot=1
		read_local_value user.email
		email_matches_bot=0
		[ "$READ_PRESENT" -eq 1 ] && [ "$READ_VALUE" = "$BOT_EMAIL" ] && email_matches_bot=1
		[ "$name_matches_bot" -eq 1 ] && [ "$email_matches_bot" -eq 1 ] || fail "backup exists but the main-worktree identity differs; restore or inspect it before overriding"
		printf '%s: bot identity is already active for %s\n' "$PROGRAM" "$MAIN_ROOT"
		exit 0
	fi

	read_local_value user.name
	ORIGINAL_NAME_PRESENT="$READ_PRESENT"
	ORIGINAL_NAME="$READ_VALUE"
	read_local_value user.email
	ORIGINAL_EMAIL_PRESENT="$READ_PRESENT"
	ORIGINAL_EMAIL="$READ_VALUE"
	write_backup "$ORIGINAL_NAME_PRESENT" "$ORIGINAL_NAME" "$ORIGINAL_EMAIL_PRESENT" "$ORIGINAL_EMAIL"

	if ! write_local_value user.name 1 "$BOT_NAME" || ! write_local_value user.email 1 "$BOT_EMAIL"; then
		if restore_original; then rm -f "$BACKUP_CONFIG"; fi
		fail "could not apply bot identity; original identity restoration was attempted"
	fi
	read_local_value user.name
	[ "$READ_PRESENT" -eq 1 ] && [ "$READ_VALUE" = "$BOT_NAME" ] || {
		restore_original && rm -f "$BACKUP_CONFIG"
		fail "could not verify bot user.name; original identity restoration was attempted"
	}
	read_local_value user.email
	[ "$READ_PRESENT" -eq 1 ] && [ "$READ_VALUE" = "$BOT_EMAIL" ] || {
		restore_original && rm -f "$BACKUP_CONFIG"
		fail "could not verify bot user.email; original identity restoration was attempted"
	}
	AUTHOR_IDENT="$(git -C "$MAIN_ROOT" var GIT_AUTHOR_IDENT 2>/dev/null || true)"
	COMMITTER_IDENT="$(git -C "$MAIN_ROOT" var GIT_COMMITTER_IDENT 2>/dev/null || true)"
	[[ "$AUTHOR_IDENT" == "$BOT_NAME <$BOT_EMAIL> "* && "$COMMITTER_IDENT" == "$BOT_NAME <$BOT_EMAIL> "* ]] || {
		restore_original && rm -f "$BACKUP_CONFIG"
		fail "effective Git author/committer does not resolve to the bot; check environment overrides"
	}
	printf '%s: bot identity enabled for main worktree %s\n' "$PROGRAM" "$MAIN_ROOT"
	printf '%s: identity remains active until the restore command succeeds\n' "$PROGRAM"
	exit 0
fi

[ -f "$BACKUP_CONFIG" ] || fail "no saved main-worktree identity exists for this repository"
load_backup
read_local_value user.name
CURRENT_NAME_PRESENT="$READ_PRESENT"
CURRENT_NAME="$READ_VALUE"
read_local_value user.email
CURRENT_EMAIL_PRESENT="$READ_PRESENT"
CURRENT_EMAIL="$READ_VALUE"
state_matches_value "$CURRENT_NAME_PRESENT" "$CURRENT_NAME" "$ORIGINAL_NAME_PRESENT" "$ORIGINAL_NAME" "$BOT_NAME" || fail "main-worktree user.name changed since override; refusing to overwrite it"
state_matches_value "$CURRENT_EMAIL_PRESENT" "$CURRENT_EMAIL" "$ORIGINAL_EMAIL_PRESENT" "$ORIGINAL_EMAIL" "$BOT_EMAIL" || fail "main-worktree user.email changed since override; refusing to overwrite it"

restore_original || fail "could not restore the saved identity; backup retained at $BACKUP_CONFIG"
read_local_value user.name
[ "$READ_PRESENT" -eq "$([ "$ORIGINAL_NAME_PRESENT" = true ] && printf 1 || printf 0)" ] || fail "restored user.name presence does not match backup; backup retained"
[ "$ORIGINAL_NAME_PRESENT" = false ] || [ "$READ_VALUE" = "$ORIGINAL_NAME" ] || fail "restored user.name does not match backup; backup retained"
read_local_value user.email
[ "$READ_PRESENT" -eq "$([ "$ORIGINAL_EMAIL_PRESENT" = true ] && printf 1 || printf 0)" ] || fail "restored user.email presence does not match backup; backup retained"
[ "$ORIGINAL_EMAIL_PRESENT" = false ] || [ "$READ_VALUE" = "$ORIGINAL_EMAIL" ] || fail "restored user.email does not match backup; backup retained"
rm -f "$BACKUP_CONFIG"
printf '%s: restored the saved main-worktree identity for %s\n' "$PROGRAM" "$MAIN_ROOT"
