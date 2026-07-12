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
# isKnownOrderMutation is a local derived policy. It is true when either:
# - rateLimitGroup is ORDER or CONDITIONAL_ORDER, or
# - fail-closed: mutation method (POST/PUT/PATCH/DELETE) targets an
#   /orders or /conditional-orders path, regardless of rateLimitGroup drift.
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

  # parameter $ref를 완전히 해소한다. 단일 object로 끝나지 않는 모든 형태를 fail-closed로
  # 막는다: (a) broken/external ref는 getpath가 null을 반환하므로 object가 아니면 실패,
  # (b) chained ref(AccountAlias -> $ref AccountSeq)는 첫 resolve가 다시 Reference Object라
  #     재귀로 계속 해소, (c) cyclic ref는 depth 한도로 차단. 조용히 통과하면 account-required
  #     endpoint가 account-free로 잘못 생성된다.
  def resolve_parameter_ref($root; $param; $depth):
    if $depth <= 0 then
      error("parameter $ref chain too deep or cyclic")
    elif (($param["$ref"] // null) != null) then
      ($param["$ref"]) as $ref
      # 각 hop은 반드시 #/components/parameters/ 아래를 가리켜야 한다. name+in shape가
      # 겹치는 다른 OAS object(예: apiKey Security Scheme {type,name,in})로 새면 terminal
      # shape 검증을 우회하므로, ref target namespace 자체를 parameters로 제한한다.
      | if ($ref | startswith("#/components/parameters/")) then
          (resolve_ref($root; $ref)) as $resolved
          | if ($resolved | type) != "object" then
              error("unresolved parameter $ref: \($ref)")
            else
              resolve_parameter_ref($root; $resolved; $depth - 1)
            end
        else
          error("parameter $ref must target #/components/parameters/: \($ref)")
        end
    else
      $param
    end;

  # 완전 해소 후 terminal이 Parameter Object(name+in 필수)인지까지 검증한다. chain이
  # Schema 등 Parameter가 아닌 object로 끝나면 generation을 실패시킨다 (account 판정이
  # 조용히 false가 되는 것을 막는다).
  def resolved_parameter($root; $param):
    (resolve_parameter_ref($root; $param; 16)) as $r
    | if (($r.name // null) != null and ($r.in // null) != null) then $r
      else error("resolved parameter is not a Parameter Object (missing name/in): \($param)")
      end;

  # HTTP field name은 RFC 9110 §5.1에 따라 case-insensitive이므로 name을 소문자로 비교한다.
  def is_account_parameter($resolved):
    ((($resolved.name // "") | ascii_downcase) == "x-tossinvest-account")
    and (($resolved.in // "") == "header");

  # raw `$ref` 문자열 shortcut(단축 평가)과 any(...)의 short-circuit을 모두 제거한다:
  # 전체 parameter 배열을 **먼저** 재귀 resolve·terminal shape 검증(broken/self-cycle/
  # wrong-object이면 여기서 error)한 뒤, 그 결과로 account 여부를 계산한다.
  def requires_account($root; $path_item; $operation):
    (($path_item.parameters // []) + ($operation.parameters // []))
    | map(resolved_parameter($root; .))
    | any(is_account_parameter(.));

  # capture는 no-match에서 error가 아니라 empty stream을 내므로, `... as $rate_limit_group`이
  # 그 operation의 endpoint object 전체를 조용히 drop한다. `// null`로 empty도 null로 복구해
  # marker/description 없는 유효 operation이 endpoint 누락으로 번지지 않게 한다.
  def rate_limit_group($operation):
    (try (
      ($operation.description // "")
      | capture("\\*\\*Rate Limits Group\\*\\*:\\s*`(?<group>[^`]+)`\\s*$"; "m")
      | .group
    ) catch null) // null;

  def is_mutation_method($method):
    (["POST", "PUT", "PATCH", "DELETE"] | index($method)) != null;

  def is_order_path($path):
    $path | test("(^|/)(orders|conditional-orders)(/|$)");

  def is_known_order_mutation($method; $path; $rate_limit_group):
    ((["ORDER", "CONDITIONAL_ORDER"] | index($rate_limit_group // "")) != null)
    or (is_mutation_method($method) and is_order_path($path));

  . as $root
  | {
      schema_version: "1",
      source_openapi_version: .info.version,
      endpoints: ([
        .paths
        | to_entries[] as $path_entry
        | $path_entry.value as $path_item
        # Path Item $ref(OAS 3.0.3 허용)는 operation iteration이 조용히 무시해 endpoint를
        # 누락시킨다. 지원하지 않으므로 fail-closed로 실패시킨다 (현재 스펙엔 없음).
        | (if ($path_item["$ref"] // null) != null then
             error("unsupported Path Item $ref at \($path_entry.key): \($path_item["$ref"])")
           else . end)
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
            isKnownOrderMutation: is_known_order_mutation($method; $path_entry.key; $rate_limit_group)
          }
      ] | sort_by(.method, .path))
    }
' "$input_path" > "$tmp_path"

mv "$tmp_path" "$output_path"
trap - EXIT
