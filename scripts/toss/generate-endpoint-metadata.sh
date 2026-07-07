#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

input_path="${1:-$repo_root/.claude/skills/using-toss-api/references/vendor/openapi.json}"
output_path="${2:-$repo_root/modules/shared/scripts/toss/endpoints.json}"
output_dir="$(dirname -- "$output_path")"

if [[ ! -f "$input_path" ]]; then
  echo "error: OpenAPI input not found: $input_path" >&2
  exit 1
fi

mkdir -p "$output_dir"

tmp_path="$(mktemp "$output_dir/endpoints.json.tmp.XXXXXX")"
trap 'rm -f "$tmp_path"' EXIT

# rateLimitGroup is not a structured OpenAPI field in the Toss snapshot.
# Local policy: parse a terminal "**Rate Limits Group**: `...`" marker from
# each operation description. If the marker is missing, emit null.
#
# isKnownOrderMutation is a local derived policy: mutation methods
# (POST/PUT/PATCH/DELETE) in ORDER or CONDITIONAL_ORDER rate-limit groups.
#
# Phase B CLI safety remains separate: requiresOrderSafeguards =
# isKnownOrderMutation OR metadataStatus=unknown. This metadata file only
# records endpoint facts and the one local mutation classification.
jq '
  def operation_methods:
    ["get", "put", "post", "delete", "patch", "options", "head", "trace"];

  def regex_escape_char:
    if test("[\\\\.^$|?*+()\\[\\]{}]") then "\\" + . else . end;

  def path_regex($path):
    ($path | split("")) as $chars
    | reduce $chars[] as $char (
        {out: "^", in_param: false};
        if .in_param then
          if $char == "}" then
            .in_param = false
          else
            .
          end
        else
          if $char == "{" then
            .out += "[^/]+" | .in_param = true
          else
            .out += ($char | regex_escape_char)
          end
        end
      )
    | .out + "$";

  def resolve_ref($root; $ref):
    ($ref
      | sub("^#/"; "")
      | split("/")
      | map(gsub("~1"; "/") | gsub("~0"; "~"))) as $path
    | $root
    | getpath($path);

  def resolved_parameter($root; $param):
    if (($param["$ref"] // null) != null) then
      try resolve_ref($root; $param["$ref"]) catch $param
    else
      $param
    end;

  def account_parameter($root; $param):
    (($param["$ref"] // "") == "#/components/parameters/AccountSeq")
    or (
      resolved_parameter($root; $param)
      | ((.name // "") == "X-Tossinvest-Account" and (.in // "") == "header")
    );

  def requires_account($root; $path_item; $operation):
    (($path_item.parameters // []) + ($operation.parameters // []))
    | any(account_parameter($root; .));

  def rate_limit_group($operation):
    try (
      ($operation.description // "")
      | capture("\\*\\*Rate Limits Group\\*\\*:\\s*`(?<group>[^`]+)`\\s*$"; "m")
      | .group
    ) catch null;

  def is_known_order_mutation($method; $rate_limit_group):
    ((["POST", "PUT", "PATCH", "DELETE"] | index($method)) != null)
    and ((["ORDER", "CONDITIONAL_ORDER"] | index($rate_limit_group // "")) != null);

  . as $root
  | {
      schema_version: "1",
      source_openapi_version: .info.version,
      endpoints: ([
        .paths
        | to_entries[] as $path_entry
        | $path_entry.value as $path_item
        | $path_item
        | to_entries[]
        | select(.key as $method | operation_methods | index($method) != null)
        | .key as $method_lower
        | .value as $operation
        | ($method_lower | ascii_upcase) as $method
        | rate_limit_group($operation) as $rate_limit_group
        | {
            method: $method,
            path: $path_entry.key,
            operationId: $operation.operationId,
            requiresAccount: requires_account($root; $path_item; $operation),
            rateLimitGroup: $rate_limit_group,
            pathRegex: path_regex($path_entry.key),
            isKnownOrderMutation: is_known_order_mutation($method; $rate_limit_group)
          }
      ] | sort_by(.method, .path))
    }
' "$input_path" > "$tmp_path"

mv "$tmp_path" "$output_path"
trap - EXIT
