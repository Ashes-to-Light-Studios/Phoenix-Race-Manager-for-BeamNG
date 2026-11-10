#!/usr/bin/env bash
# Post one GitHub event to a Discord channel, under the name and avatar of
# whoever caused it.
#
#   discord-post.sh <event name> <event payload file>
#
# This replaces Discord's own GitHub integration (the webhook URL with /github
# on the end). That one renders the message itself, always as "GitHub" with the
# sender's GitHub name and picture, and offers nothing to change. Posting the
# JSON ourselves to the PLAIN webhook URL lets each message carry its own
# `username` and `avatar_url`, and its own embed author.
#
# WHO IS SHOWN AS WHOM is the table just below: a GitHub login on the left is
# posted under the screen name and avatar on the right. Anybody not listed is
# posted under their GitHub login and GitHub picture.
#
# Environment:
#   DISCORD_WEBHOOK_URL  the channel's webhook URL, or several, one per line:
#                        each gets every post. Empty: say so and exit 0, so a
#                        repo without the secret stays green. WHICH channel
#                        an event goes to is the caller's choice: the workflows
#                        pass the releases secret here for a release.
#   DISCORD_DRY_RUN      set to print the JSON instead of posting it.
set -euo pipefail

# login (any case) | screen name | avatar URL
# The avatar has to be a PUBLIC web address: Discord fetches the picture
# itself, so a file is used by putting it in this repo and linking to it. The
# sun is .github/discord/sun.png, as GitHub serves it from main. To change the
# picture, replace that file -- under a NEW NAME, and change the link to
# match, or Discord keeps showing the copy it already fetched.
IDENTITIES='
JHaseldenDev|Jraysunshine|https://raw.githubusercontent.com/Ashes-to-Light-Studios/Phoenix-Race-Manager-for-BeamNG/main/.github/discord/sun.png
'

event="${1:?usage: discord-post.sh <event name> <event payload file>}"
payload="${2:?usage: discord-post.sh <event name> <event payload file>}"
repo="${GITHUB_REPOSITORY:?}"
server="${GITHUB_SERVER_URL:-https://github.com}"

message=$(jq -c \
  --arg event "$event" \
  --arg repo "${repo#*/}" \
  --arg repo_url "$server/$repo" \
  --arg identities "$IDENTITIES" '
  def trunc(n): if length > n then .[0:n-1] + "…" else . end;
  def first_line: (. // "") | split("\n")[0];
  def body(n): (. // "") | gsub("\r"; "") | trunc(n);

  # --- who ---
  (.sender.login // "GitHub") as $login
  | ([$identities | split("\n")[] | select(length > 0) | split("|")
      | select(.[0] | ascii_downcase == ($login | ascii_downcase))][0]) as $known
  | ($known[1] // $login) as $name
  | ($known[2] // .sender.avatar_url) as $avatar
  | (.sender.html_url // $repo_url) as $profile

  # --- what: null means "nothing worth a post" ---
  | (if $event == "push" then
      (.ref | sub("^refs/(heads|tags)/"; "")) as $ref
      | (.ref | startswith("refs/tags/")) as $is_tag
      | if .deleted then
          { title: "[\($repo)] \(if $is_tag then "Tag" else "Branch" end) deleted: \($ref)", color: 13574702 }
        elif $is_tag then
          { title: "[\($repo)] New tag: \($ref)", url: "\($repo_url)/releases/tag/\($ref)", color: 7506394 }
        elif (.commits | length) == 0 then
          if .created
          then { title: "[\($repo)] New branch: \($ref)", url: "\($repo_url)/tree/\($ref)", color: 7506394 }
          else null end
        else
          (.commits | length) as $n
          | { title: ("[\($repo):\($ref)] \($n) new commit\(if $n == 1 then "" else "s" end)"
                      + (if .forced then " (force push)" else "" end)),
              url: .compare,
              color: 7506394,
              description: (
                [.commits[:10][]
                  | "[`\(.id[0:7])`](\(.url)) \(.message | first_line | trunc(72))"]
                + (if $n > 10 then ["… and \($n - 10) more"] else [] end)
                | join("\n")) }
        end

    elif $event == "pull_request" or $event == "pull_request_target" then
      .pull_request as $pr
      | (if .action == "closed" and $pr.merged then "merged" else .action end) as $did
      | if ($did | IN("opened", "reopened", "closed", "merged", "ready_for_review")) then
          { title: "[\($repo)] Pull request \($did | gsub("_"; " ")): #\($pr.number) \($pr.title)",
            url: $pr.html_url,
            color: ({ merged: 8540383, closed: 13574702 }[$did] // 2991182),
            description: (if $did == "opened" then ($pr.body | body(500)) else "" end) }
        else null end

    elif $event == "issues" then
      .issue as $i
      | if (.action | IN("opened", "reopened", "closed")) then
          { title: "[\($repo)] Issue \(.action): #\($i.number) \($i.title)",
            url: $i.html_url,
            color: (if .action == "closed" then 13574702 else 15426592 end),
            description: (if .action == "opened" then ($i.body | body(500)) else "" end) }
        else null end

    elif $event == "issue_comment" then
      if .action == "created" then
        { title: "[\($repo)] New comment on \(if .issue.pull_request then "pull request" else "issue" end) #\(.issue.number): \(.issue.title)",
          url: .comment.html_url,
          color: 9807270,
          description: (.comment.body | body(500)) }
      else null end

    elif $event == "release" then
      if .action == "published" then
        { title: "[\($repo)] New release: \(.release.name // .release.tag_name)",
          url: .release.html_url,
          color: 15844367,
          description: (.release.body | body(1000)) }
      else null end

    else null end) as $embed

  | if $embed == null then empty else
      { username: ($name | trunc(80)),
        avatar_url: $avatar,
        # Commit messages and comments are text written by others: never let an
        # @everyone in one of them ping the channel.
        allowed_mentions: { parse: [] },
        embeds: [ $embed
          + { title: ($embed.title | trunc(256)) }
          + { author: { name: ($name | trunc(256)), url: $profile, icon_url: $avatar } } ] }
    end
' "$payload")

if [ -z "$message" ]; then
  echo "Nothing to post for this $event event."
  exit 0
fi

if [ -n "${DISCORD_DRY_RUN:-}" ]; then
  echo "$message"
  exit 0
fi

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
  echo "::notice::No Discord webhook secret is set, so nothing was posted. Add DISCORD_WEBHOOK_URL (and DISCORD_RELEASES_WEBHOOK_URL for releases) under Settings, Secrets and variables, Actions."
  exit 0
fi

# ONE SECRET, ANY NUMBER OF WEBHOOKS: one URL per line (or separated by
# spaces). Every URL gets every post. One that fails does not stop the rest,
# and the run goes red at the end so it is noticed.
#
# The /github ending is Discord's GitHub-format endpoint and rejects this JSON.
# Somebody pasting the URL from the old integration gets the plain one anyway.
#
# No -v and no URL in any output: the URL is the credential. Webhooks are
# named by their position in the secret instead.
n=0
failed=0
for url in $(printf '%s' "$DISCORD_WEBHOOK_URL" | tr -d '\r'); do
  n=$((n + 1))
  url="${url%/}"
  url="${url%/github}"
  status=$(curl -sS -o /tmp/discord-response -w '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary "$message" "$url") || status=000
  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    echo "Webhook $n: posted ($status)."
  else
    echo "::error::Webhook $n: Discord answered $status: $(cat /tmp/discord-response 2>/dev/null)"
    failed=1
  fi
done
exit "$failed"
