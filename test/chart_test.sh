#!/usr/bin/env bash
# Render-level tests for the chart's per-user feature routing.
#
#   test/chart_test.sh            # helm template checks only
#   test/chart_test.sh --cluster  # also kubectl server-side dry run
#                                 # (validates against the API server and
#                                 # Istio CRDs; creates nothing)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHART=$ROOT/chart
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() { helm template t "$CHART" "$@"; }
# Render that must fail, with stderr containing $1.
render_fails_with() { local want=$1; shift; ! render "$@" >/dev/null 2>"$TMP/err" && grep -q "$want" "$TMP/err"; }
# Comments mention hosts/gateways by name, so match on manifests only.
strip() { grep -v '^ *#'; }

pass=0; fail=0
check() {
  if eval "$2"; then echo "PASS  $1"; pass=$((pass+1))
  else echo "FAIL  $1"; fail=$((fail+1)); fi
}

ROUTE=(--set route.enabled=true --set route.env=dev)
NOROUTE=(--set route.enabled=false)
B=(-f "$CHART/service/service-b/prod.yaml")

check "helm lint"                     'helm lint "$CHART" -f "$CHART/features.yaml" "${B[@]}" >/dev/null'

# --- No matching service in features.yaml → nothing feature-related.
OUT=$(render -f "$CHART/features.yaml" "${B[@]}" "${NOROUTE[@]}" | strip)
check "no match: no feature objects"  '! grep -q feature- <<<"$OUT"'
check "no match, route off: no VS"    '! grep -q "kind: VirtualService" <<<"$OUT"'
OUT=$(render -f "$CHART/features.yaml" "${B[@]}" "${ROUTE[@]}" | strip)
check "no match, route on: no mesh"   '! grep -q "^    - mesh" <<<"$OUT"'

# --- Matching service, route on.
OUT=$(render -f "$ROOT/test/features.yaml" "${B[@]}" "${ROUTE[@]}" | strip)
check "feature Deployment rendered"   'grep -q "name: service-b-feature-new-cart-app" <<<"$OUT"'
check "feature image tag"             'grep -q "image: \"service-b:feature-new-cart\"" <<<"$OUT"'
check "feature IMAGE_TAG env"         'grep -q "value: \"feature-new-cart\"" <<<"$OUT"'
check "feature Service + selector"    'grep -q "name: service-b-feature-new-cart$" <<<"$OUT" && grep -q "app: service-b-feature-new-cart-app" <<<"$OUT"'
check "main build untouched"          'grep -q "image: \"service-b:PROD-v1.0.0\"" <<<"$OUT"'
check "VS routes alice + bob"         'grep -q "exact: \"alice\"" <<<"$OUT" && grep -q "exact: \"bob\"" <<<"$OUT"'
check "feature-promo dropped"         '! grep -q promo <<<"$OUT"'
check "carol ignored"                 '! grep -q carol <<<"$OUT"'
check "VS has gateway + mesh"         'grep -q "istio-system/sample-gateway" <<<"$OUT" && grep -q "^    - mesh" <<<"$OUT"'
check "default route is last"         '[ "$(grep "host:" <<<"$OUT" | tail -1 | xargs)" = "host: service-b" ]'
check "external host is <name>.<env>"  'grep -q "host: service-b.dev.apps.shirlenelim.se" <<<"$OUT" && grep -q "^    - service-b.dev.apps.shirlenelim.se" <<<"$OUT"'
ROUTED=$OUT

# --- Matching service, route off → mesh-only VS.
OUT=$(render -f "$ROOT/test/features.yaml" "${B[@]}" "${NOROUTE[@]}" | strip)
check "route off: VS still rendered"  'grep -q "kind: VirtualService" <<<"$OUT"'
check "route off: mesh only"          'grep -q "^    - mesh" <<<"$OUT" && ! grep -q "sample-gateway\|nip.io\|apps.shirlenelim.se" <<<"$OUT"'

# --- Feature builds are sized by featureBuild, not the main build.
OUT=$(render -f "$ROOT/test/features.yaml" "${B[@]}" --set replicas=5 | strip)
check "main build scales"             '[ "$(grep -A4 "name: service-b-app$" <<<"$OUT" | grep -m1 replicas: | xargs)" = "replicas: 5" ]'
check "feature build stays at 1"      '[ "$(grep -A4 "name: service-b-feature-new-cart-app$" <<<"$OUT" | grep -m1 replicas: | xargs)" = "replicas: 1" ]'

# --- Header values are always strings (YAML would read 123 / on as int / bool).
printf 'users: ["123", "on"]\nservices:\n  service-b:\n    feature-x: ["123", "on"]\n' > "$TMP/odd-users.yaml"
OUT=$(render -f "$TMP/odd-users.yaml" "${B[@]}" | strip)
check "numeric user quoted"           'grep -q "exact: \"123\"" <<<"$OUT"'
check "boolean-ish user quoted"       'grep -q "exact: \"on\"" <<<"$OUT"'

# --- Bad input fails at render time, not at apply time.
printf 'users: [alice]\nservices:\n  service-b:\n    Feature_X: [alice]\n' > "$TMP/bad-name.yaml"
check "invalid feature name rejected" 'render_fails_with "Feature_X" -f "$TMP/bad-name.yaml" "${B[@]}"'
printf 'users: [alice]\nservices:\n  service-b:\n    %s: [alice]\n' "feature-$(printf 'x%.0s' {1..60})" > "$TMP/long-name.yaml"
check "over-long feature name rejected" 'render_fails_with "over Kubernetes" -f "$TMP/long-name.yaml" "${B[@]}"'
check "route on without env rejected" 'render_fails_with "route.env is required" "${B[@]}" --set route.env='

if [ "${1:-}" = "--cluster" ]; then
  check "server dry run accepted" 'kubectl apply --dry-run=server -f - <<<"$ROUTED" >/dev/null'
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
