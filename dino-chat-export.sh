 #!/bin/sh
#―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
# Name: dino-chat-exporter
# Desc: Export all conversations from Dino (XMPP client)'s database into
#       textual format
# Reqs: shell, sqlite3
# Date: 2022-10
#―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――


sqlite() {
	sqlite3 "$1" "$2"
	if test "$?" -ne 0; then
		>&2 printf "sqlite errored out! Let's try again in a moment…"
		sleep 1

		sqlite3 "$1" "$2"
		if test "$?" -ne 0; then
			>&2 printf "\t… well that didn't work. Oh, well.\n"
		else
			>&2 printf "\t… hey, that worked!\n"
		fi
	fi
}


# A list of all accounts, by internal ID
account_list() {
	sqlite  "$DB_FILE" \
		"SELECT id
		FROM account;"
}


# A list of all counterpart/contact IDs for messages
conversation_partners() {
	local account_id="$1"

	sqlite  "$DB_FILE" \
		"SELECT DISTINCT counterpart_id
		FROM message
		WHERE account_id == $account_id;"
}


# Outputs valid file extension for given file
file_extension() {
	local file="$1"

	# For some reason, `file` doesn't choose a file extension for HTML nor plaintext files?
	if file --brief --mime "$file" | grep "text/html" > /dev/null; then
		echo "html"
	else
		file --brief --extension "$file" \
			| cut --delimiter='/' --fields=1 \
			| sed 's%^???$%txt%'
	fi
}


# Output the account no.'s jid_id (aka, accounts.id→jid.id)
# (We cache this in a global variable, so we're not making a million database queries)
account_jid_id() {
	local account_id="$1"

	if test -z "$YOUR_JID_ID"; then
		YOUR_JID_ID="$(sqlite "$DB_FILE" \
			"SELECT jid.id
			FROM account, jid
			WHERE account.id == $account_id
				AND account.bare_jid == jid.bare_jid;")"
	fi
	echo "$YOUR_JID_ID"
}


# Output the account no.'s xmpp address and nick
# (We cache this in a global variable, so we're not making a million database queries)
account_jid_and_nick() {
	local account_id="$1"

	if test -z "$YOUR_INFO"; then
		YOUR_INFO="$(sqlite "$DB_FILE" \
			"SELECT FORMAT('%s' || char(10) || '%s',
				bare_jid,
				alias)
			FROM account
			WHERE id == $account_id;")"
	fi
	echo "$YOUR_INFO"
}


# Get a user's (based on jid.id) xmpp address and roster nickname
# (We cache this in a global variable, so we're not making a million database queries)
id_jid_and_nick() {
	local internal_id="$1"

	if test -z "$THEIR_INFO"; then
		local nick="$(sqlite "$DB_FILE" \
			"SELECT
				CASE
					WHEN roster.name IS NOT NULL
					THEN roster.name
				END
			FROM roster, jid
			WHERE roster.jid == jid.bare_jid AND jid.id == $internal_id;")"

		local jid="$(sqlite "$DB_FILE" \
			"SELECT bare_jid
			FROM jid
			WHERE jid.id == $internal_id;")"

		if test -z "$nick"; then
			THEIR_INFO="$(printf '%s\n%s\n' "$jid" "$jid")"
		else
			THEIR_INFO="$(printf '%s\n%s\n' "$jid" "$nick")"
		fi
	fi
	echo "$THEIR_INFO"
}


# Archives a full conversation with user (messages and files)
archive_conversation_with_partner() {
	local account_id="$1"
	local partner_id="$2"
	local output_dir="$3"

	mkdir -p "$output_dir"
	if test ! -d  "$output_dir"; then
		echo "$output_dir isn't a valid directory"
		exit 2
	fi

	archive_files_with_partner "$account_id" "$partner_id" "$output_dir/files"
	archive_messages_with_partner "$account_id" "$partner_id" "$output_dir/messages"
}


# Archives all messages between you and partner, according to a stem
archive_messages_with_partner() {
	local account_id="$1"
	local partner_id="$2"
	local output_stem="$3"

	output_messages_with_partner "$account_id" "$partner_id" \
	> "$output_stem"
	mv "$output_stem" "$output_stem.$(file_extension "$output_stem")"
}


# Archives all (currently known/downloaded) files and avatars between you and partner
archive_files_with_partner() {
	local account_id="$1"
	local partner_id="$2"
	local output_dir="$3"
	local IFS="
"
	mkdir -p "$output_dir"
	if test ! -d  "$output_dir"; then
		echo "$output_dir isn't a valid directory"
		return
	fi

	THEIR_AVATAR="$(archive_avatars "$account_id" "$partner_id" "$output_dir/avatar" | head -1)"
	YOUR_AVATAR="$(archive_avatars "$account_id" "$(account_jid_id "$account_id")" "$output_dir/your_avatar" | head -1)"
	if test -z "$THEIR_AVATAR"; then
		THEIR_AVATAR="files/their_avatar.png"
	fi
	if test -z "$YOUR_AVATAR"; then
		YOUR_AVATAR="files/your_avatar.png"
	fi

	local files="$(sqlite  "$DB_FILE" \
		"SELECT path
			FROM file_transfer
			WHERE counterpart_id == $partner_id AND account_id == $account_id;")"

	for file in $files; do
		cp "$DINO_HOME/files/$file" "$output_dir/$file"
	done
}


# Archive the avatars of a user, according to a stem
# ("./files/avatar" becomes "./files/avatar.png", "./files/avatar1.png"…)
archive_avatars() {
	local account_id="$1"
	local internal_id="$2"
	local output_stem="$3"

	local i=""
	for file in $(avatar_paths "$account_id" "$internal_id"); do
		local output_path="$output_stem${i}.$(file_extension "$file")"
		echo "$output_path"

		cp "$file" "$output_stem${i}.$(file_extension "$file")"
	done
}


# For flexibility in formatting, we let the user define the selection order in a simplified manner
message_slots_to_selection() {
	local slots="$1"

	local jid_query_part="CASE message.direction
			WHEN 0
				THEN jid.bare_jid
				ELSE ( select account.bare_jid from account where account.id == message.account_id  )
			END"

	local avatar_query_part="CASE message.direction
		WHEN 0
			THEN 'files/$(basename "$THEIR_AVATAR")'
			ELSE 'files/$(basename "$YOUR_AVATAR")'
		END"

	# If this message has a file attached, print the file's relative path
	# Uses two seperate output formats for files and for images
	local body_query_part="
		CASE
			WHEN message.id == (
					SELECT file_transfer.info
					FROM file_transfer
					WHERE file_transfer.info == message.id )
				THEN ( SELECT
						CASE
							WHEN (file_transfer.path LIKE '%.jpg') OR (file_transfer.path LIKE '%.jpeg') OR (file_transfer.path LIKE '%.jpeg')
									OR (file_transfer.path LIKE '%.png') OR (file_transfer.path LIKE '%.webm') OR (file_transfer.path LIKE '%.svg')
								THEN PRINTF('$IMAGE_FORMAT', 'files/' || path)
								ELSE PRINTF('$FILE_FORMAT', 'files/' || path)
						END
						FROM file_transfer
						WHERE file_transfer.info == message.id )
				ELSE message.body
		END"

	echo "$slots" \
	| sed "s^DATE^DATETIME(message.local_time, 'unixepoch', 'localtime')^g" \
	| sed "s^JID^$(echo "$jid_query_part" | tr '\n' ' ' | tr -d '\t')^g" \
	| sed "s^AVATAR^$(echo "$avatar_query_part" | tr '\n' ' ' | tr -d '\t')^g" \
	| sed "s^BODY^$(echo "$body_query_part" | tr '\n' ' ' | tr -d '\t')^g"
}


# Prints a header/footer for message output, replacing useful variables
output_message_cap() {
	local account_id="$1"
	local partner_id="$2"
	local message_cap="$3"

	echo "$message_cap" \
		| sed 's%YOUR_JID%'"$(account_jid_and_nick "$account_id" | head -1)"'%g' \
		| sed 's%YOUR_NICK%'"$(account_jid_and_nick "$account_id" | tail -1)"'%g' \
		| sed 's%THEIR_JID%'"$(id_jid_and_nick "$partner_id" | head -1)"'%g' \
		| sed 's%THEIR_NICK%'"$(id_jid_and_nick "$partner_id" | tail -1)"'%g'
}


# Outputs all conversation's text with partner, as per $MESSAGE_FORMAT
output_messages_with_partner() {
	local account_id="$1"
	local partner_id="$2"
	local output_dir="$3" # optional, only used to guess avatar paths

	output_message_cap "$account_id" "$partner_id" "$MESSAGE_HEADER"

	sqlite "$DB_FILE" \
		"SELECT FORMAT('$MESSAGE_FORMAT',
			$(message_slots_to_selection "$MESSAGE_SLOTS"))
		FROM jid,message
		WHERE message.account_id == '$account_id'
			AND message.counterpart_id == $partner_id
			AND jid.id == $partner_id
		ORDER BY message.local_time ASC;"

	output_message_cap "$account_id" "$partner_id" "$MESSAGE_FOOTER"
}


# Outputs existant avatar paths for the given user, by internal ID
avatar_paths() {
	local account_id="$1"
	local internal_id="$2"
	local IFS="
"
	for file in $(potential_avatar_paths "$account_id" "$internal_id" | uniq); do
		if test -e "$file"; then
			echo "$file"
		fi
	done
}


# Outputs potential paths for a user's avatar, by internal ID
potential_avatar_paths() {
	local account_id="$1"
	local internal_id="$2"

	sqlite "$DB_FILE" \
		"SELECT '$DINO_HOME/avatars/' || hash
			FROM contact_avatar
			WHERE jid_id == '$internal_id'
				  AND account_id == '$account_id';"
}



# USER ENVIRONMENT
# ———————————————————————————————————————————————————————————————————————————————
# Where Dino's data lives
if test -z "$DINO_HOME"; then
	DINO_HOME="$XDG_DATA_HOME/dino/"
fi
if test ! -e "$DINO_HOME"; then
	DINO_HOME="$HOME/.local/share/dino/"
fi

DB_FILE="$XDG_DATA_HOME/dino/dino.db"

# The format for message output, with %s being substitued with it's corresponding
# place in $MESSAGE_SLOTS
if test -z "$MESSAGE_FORMAT"; then
	MESSAGE_FORMAT="%s <%s> %s"
fi

# The slots used in $MESSAGE_FORMAT.
# May be DATE, JID, BODY, or AVATAR. Must be comma-delimited.
if test -z "$MESSAGE_SLOTS"; then
	MESSAGE_SLOTS="DATE, JID, BODY"
fi

if test -z "$FILE_FORMAT"; then
	FILE_FORMAT="File uploaded: %s"
fi

if test -z "$IMAGE_FORMAT"; then
	IMAGE_FORMAT="Image uploaded: %s"
fi



# STATE
# ———————————————————————————————————————————————————————————————————————————————
# How repulsive… very sorry about this =w="
THEIR_INFO=""
THEIR_AVATAR=""
YOUR_INFO=""
YOUR_JID_ID=""
YOUR_AVATAR=""



# INVOCATION
# ———————————————————————————————————————————————————————————————————————————————

usage() {
	echo "usage: $(basename "$0") OUTPUT_DIRECTORY"
	echo 
	echo "Exports all conversations and files from the Dino XMPP client into a plain-text format."
	echo
	echo '  $DINO_HOME'
	echo '         Dino data directory (default: $XDG_DATA_HOME/Dino or ~/.local/share/Dino)'
	echo '  $MESSAGE_HEADER'
	echo '         Text preceding each message file, with basic substitutions. (e.g., "<html><body>…")'
	echo '         Substitutions are THEIR_JID, YOUR_JID, THEIR_NICK, and YOUR_NICK.'
	echo '  $MESSAGE_FOOTER'
	echo '         Likewise, but is output to the end of each message file. (e.g., "</body></html>")'
	echo '  $MESSAGE_FORMAT'
	echo '         Template for message output, in a printf style (e.g., "[%s] <%s>: %s")'
	echo '  $MESSAGE_SLOTS'
	echo '         Comma-delimited arguments for $MESSAGE_FORMAT (e.g., "DATE,JID,BODY")'
	echo '         Valid slots are AVATAR, BODY, DATE, and JID.'
	echo '  $IMAGE_FORMAT'
	echo '         Format for message-bodies containing an image. (e.g., "<img src="%s" />)'
	echo '         Leave blank or as '%s' to simply print the image path.'
	echo '  $FILE_FORMAT'
	echo '         Likewise, but for every other sort of attached file.'
	exit 2
}


OUTPUT="$1"
if test -z "$OUTPUT" -o "$1" = "--help" -o "$1" = "-h"; then
   usage
fi



for account in $(account_list); do
	# Reset state (repopulated by account_jid_and_nick; account_jid_id; archive_files…)
	YOUR_INFO=""; YOUR_JID_ID=""; YOUR_AVATAR=""

	jid="$(account_jid_and_nick "$account" | head -1)"
	nick="$(account_jid_and_nick "$account" | tail -1)"

	account_output="$OUTPUT/$jid/"
	if test -n "$nick" -a ! "$nick" = "$jid"; then
		account_output="$OUTPUT/$nick ($jid)/"
	fi

	for partner in $(conversation_partners "$account"); do
		# Reset state (repopulated by id_jid_and_nick; archive_files_with…)
		THEIR_INFO=""; THEIR_AVATAR=""

		jid="$(id_jid_and_nick "$partner" | head -1)"
		nick="$(id_jid_and_nick "$partner" | tail -1)"

		partner_output="$account_output/$jid/"
		if test -n "$nick" -a ! "$nick" = "$jid"; then
			partner_output="$account_output/$nick ($jid)/"
		fi

		echo "Archiving $jid…"
		archive_conversation_with_partner "$account" "$partner" "$partner_output"
	done
done
