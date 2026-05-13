set dotenv-load := true

DT_URL        := "http://localhost:9082"
DT_FRONTEND   := "http://localhost:9081"
APP_URL       := "http://localhost:5050"
DT_USER       := "admin"                                     # pinned by DT, not configurable
DT_PASS       := env_var_or_default("DT_PASS", "Lab1234!")
IMAGE         := "cesar-beat-app:latest"
PROJECT       := "nodegoat"
APIKEY_FILE   := ".dt-apikey"

# Pinned versions (must match compose.yml / compose.defectdojo.yml)
SYFT_VERSION     := "v1.44.0"
TRIVY_VERSION    := "0.70.0"
DT_VERSION       := "4.14.2"
MONGO_VERSION    := "4.4"
DD_VERSION       := "2.58.2"
POSTGRES_VERSION := "18.3-alpine"
VALKEY_VERSION   := "9.0.3-alpine"

DD_URL        := "http://localhost:18080"
DD_USER       := env_var_or_default("DD_USER", "admin")
DD_PASS       := env_var_or_default("DD_PASS", "Lab1234!")
DD_TOKEN_FILE := ".dd-apitoken"
DD_PRODUCT    := "cesar-beat"
DD_ENGAGEMENT := "nodegoat"
DD_COMPOSE    := "compose.defectdojo.yml"
TRIVY_JSON    := "trivy.json"

@_default:
  just --list --unsorted

# Start NodeGoat + MongoDB + Dependency-Track and wait until healthy
[group('main-lab')]
@up:
  docker compose up -d --build --wait
  echo ""
  echo "NodeGoat:     {{APP_URL}}"
  echo "DT Frontend:  {{DT_FRONTEND}}"
  echo "DT API:       {{DT_URL}}"
  echo ""
  echo "Next: just bootstrap   (create API key)"
  echo "Then: just scan        (SBOM + upload to DT)"

# Stop and remove containers + volumes
[group('main-lab')]
@down:
  docker compose down -v

# Tail container logs
[group('main-lab')]
@logs:
  docker compose logs -f --tail=100

# Initialize DT admin, save API key to .dt-apikey, then chain dt-nvd-api
[group('main-lab')]
bootstrap: && dt-nvd-api
  #!/usr/bin/env bash
  set -euo pipefail
  command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }

  # Try login with the target password (DT was already bootstrapped)
  JWT=$(curl -fsS -X POST "{{DT_URL}}/api/v1/user/login" \
    --data-urlencode "username={{DT_USER}}" \
    --data-urlencode "password={{DT_PASS}}" 2>/dev/null || true)

  if [ "${#JWT}" -lt 50 ]; then
    # Fresh DT: admin still has default password "admin", forced-change required
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "{{DT_URL}}/api/v1/user/forceChangePassword" \
      --data-urlencode "username={{DT_USER}}" \
      --data-urlencode "password=admin" \
      --data-urlencode "newPassword={{DT_PASS}}" \
      --data-urlencode "confirmPassword={{DT_PASS}}")
    if [ "$HTTP" = "200" ] || [ "$HTTP" = "204" ]; then
      echo "First-run setup: initial admin password set to '{{DT_PASS}}'"
      JWT=$(curl -fsS -X POST "{{DT_URL}}/api/v1/user/login" \
        --data-urlencode "username={{DT_USER}}" \
        --data-urlencode "password={{DT_PASS}}" 2>/dev/null || true)
    fi
  fi

  if [ "${#JWT}" -lt 50 ]; then
    echo "Error: could not authenticate with Dependency-Track."
    echo "  DT_PASS in .env ('{{DT_PASS}}') does not match DT's current admin password,"
    echo "  and DT also does not have the default 'admin' password anymore — meaning it"
    echo "  was previously bootstrapped with a different password."
    echo ""
    echo "  Recovery options:"
    echo "    1. Reset DT (loses NVD mirror, re-downloads on next start):"
    echo "         just clean && just up && just bootstrap"
    echo "    2. Set DT_PASS in .env to DT's current admin password, then rerun:"
    echo "         just bootstrap"
    echo "    3. Change the password in DT UI ({{DT_FRONTEND}}) to match DT_PASS,"
    echo "       then rerun: just bootstrap"
    exit 1
  fi

  TEAM_UUID=$(curl -s -H "Authorization: Bearer $JWT" "{{DT_URL}}/api/v1/team" \
    | jq -r '.[] | select(.name=="Automation") | .uuid')
  [ -n "$TEAM_UUID" ] || { echo "Automation team not found"; exit 1; }

  EXISTING=$(curl -s -H "Authorization: Bearer $JWT" "{{DT_URL}}/api/v1/team/$TEAM_UUID" \
    | jq -r '.apiKeys[0].key // empty')

  if [ -n "$EXISTING" ]; then
    API_KEY="$EXISTING"
  else
    API_KEY=$(curl -s -X PUT -H "Authorization: Bearer $JWT" \
      "{{DT_URL}}/api/v1/team/$TEAM_UUID/key" | jq -r '.key')
  fi

  for PERM in BOM_UPLOAD PROJECT_CREATION_UPLOAD VIEW_PORTFOLIO VIEW_VULNERABILITY \
              POLICY_MANAGEMENT VIEW_POLICY_VIOLATION POLICY_VIOLATION_ANALYSIS; do
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $JWT" \
      "{{DT_URL}}/api/v1/permission/$PERM/team/$TEAM_UUID" || true
  done

  echo "$API_KEY" > {{APIKEY_FILE}}
  echo "API key saved to {{APIKEY_FILE}}"
  echo "DT Frontend: {{DT_FRONTEND}}  (admin / {{DT_PASS}})"

# Enable NVD API 2.0 with the NIST key from .env (no-op if NVD_KEY is empty)
[group('main-lab')]
dt-nvd-api:
  #!/usr/bin/env bash
  set -euo pipefail
  if [ -z "${NVD_KEY:-}" ]; then
    echo "NVD_KEY not set in .env — DT will keep using the legacy JSON-feed mirror (slower)."
    echo "Speed it up: request a free key at https://nvd.nist.gov/developers/request-an-api-key"
    echo "             then add 'NVD_KEY=<your-key>' to .env and rerun just bootstrap (or just dt-nvd-api)."
    exit 0
  fi

  JWT=$(curl -fsS -X POST "{{DT_URL}}/api/v1/user/login" \
    --data-urlencode "username={{DT_USER}}" --data-urlencode "password={{DT_PASS}}")
  [ "${#JWT}" -ge 50 ] || { echo "Could not authenticate to DT"; exit 1; }

  echo "Setting nvd.api.enabled=true and nvd.api.key=<your-key>..."
  curl -fsS -X POST "{{DT_URL}}/api/v1/configProperty/aggregate" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "[
      {\"groupName\":\"vuln-source\",\"propertyName\":\"nvd.api.enabled\",\"propertyValue\":\"true\"},
      {\"groupName\":\"vuln-source\",\"propertyName\":\"nvd.api.key\",\"propertyValue\":\"$NVD_KEY\"}
    ]" >/dev/null

  echo "Restarting dtrack-apiserver so the new config + analyzer kicks in..."
  docker compose restart dtrack-apiserver
  echo ""
  echo "Done. Watch the mirror with:"
  echo "  docker compose logs -f dtrack-apiserver | grep -iE 'NvdApi|NistMirror'"

# Create/ensure the "block copyleft licenses" policy in DT
[group('main-lab')]
policy-setup: _ensure-apikey
  #!/usr/bin/env bash
  set -euo pipefail
  command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }

  API_KEY=$(cat {{APIKEY_FILE}})
  POLICY_NAME="cesar-beat-copyleft-fail"

  POLICY_UUID=$(curl -fsS -H "X-Api-Key: $API_KEY" "{{DT_URL}}/api/v1/policy" \
    | jq -r --arg name "$POLICY_NAME" '.[] | select(.name==$name) | .uuid')

  if [ -z "$POLICY_UUID" ]; then
    echo "Creating policy '$POLICY_NAME' (violationState=FAIL)..."
    POLICY_UUID=$(curl -fsS -X PUT -H "X-Api-Key: $API_KEY" \
      -H "Content-Type: application/json" \
      "{{DT_URL}}/api/v1/policy" \
      -d "{\"name\":\"$POLICY_NAME\",\"operator\":\"ANY\",\"violationState\":\"FAIL\"}" \
      | jq -r '.uuid')
  else
    echo "Policy '$POLICY_NAME' already present ($POLICY_UUID)"
  fi

  GROUP_UUID=$(curl -fsS -H "X-Api-Key: $API_KEY" "{{DT_URL}}/api/v1/licenseGroup" \
    | jq -r '.[] | select(.name=="Copyleft") | .uuid')

  if [ -z "$GROUP_UUID" ]; then
    echo "Error: built-in 'Copyleft' license group not found"; exit 1
  fi

  HAS_COND=$(curl -fsS -H "X-Api-Key: $API_KEY" "{{DT_URL}}/api/v1/policy/$POLICY_UUID" \
    | jq -r --arg gid "$GROUP_UUID" \
      '[.policyConditions[]? | select(.subject=="LICENSE_GROUP" and .value==$gid)] | length')

  if [ "$HAS_COND" = "0" ]; then
    echo "Adding condition: LICENSE_GROUP IS Copyleft..."
    curl -fsS -X PUT -H "X-Api-Key: $API_KEY" \
      -H "Content-Type: application/json" \
      "{{DT_URL}}/api/v1/policy/$POLICY_UUID/condition" \
      -d "{\"subject\":\"LICENSE_GROUP\",\"operator\":\"IS\",\"value\":\"$GROUP_UUID\"}" >/dev/null
  else
    echo "Condition already present (LICENSE_GROUP IS Copyleft)"
  fi

  echo "Policy ready. Violations populate after the next SBOM upload."

# Build image (if missing) and generate sbom.json with Syft (CycloneDX)
[group('main-lab')]
sbom:
  #!/usr/bin/env bash
  set -euo pipefail
  command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }

  docker image inspect {{IMAGE}} >/dev/null 2>&1 || docker build -t {{IMAGE}} .

  echo "Generating SBOM with Syft {{SYFT_VERSION}} (image {{IMAGE}})..."
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    anchore/syft:{{SYFT_VERSION}} \
    {{IMAGE}} -o cyclonedx-json > sbom.json

  COUNT=$(jq '.components | length' sbom.json)
  LICENSED=$(jq '[.components[] | select(.licenses != null and (.licenses|length)>0)] | length' sbom.json)
  echo "SBOM: $COUNT components ($LICENSED with a declared license)"

# Generate SBOM and upload it to Dependency-Track
[group('main-lab')]
scan: _ensure-apikey policy-setup sbom
  #!/usr/bin/env bash
  set -euo pipefail
  API_KEY=$(cat {{APIKEY_FILE}})
  VERSION=$(date -u +%Y%m%d-%H%M%S)

  HTTP_CODE=$(curl -s -o /tmp/dt-response.json -w "%{http_code}" \
    -X POST "{{DT_URL}}/api/v1/bom" \
    -H "X-Api-Key: $API_KEY" \
    -F "autoCreate=true" \
    -F "projectName={{PROJECT}}" \
    -F "projectVersion=$VERSION" \
    -F "bom=@sbom.json")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "Upload OK. See licenses at: {{DT_FRONTEND}}/projects"
  else
    echo "Error $HTTP_CODE:"; cat /tmp/dt-response.json; exit 1
  fi

# Run Trivy license scan locally (quick alternative, tabular output)
[group('main-lab')]
trivy-license:
  #!/usr/bin/env bash
  set -euo pipefail
  docker image inspect {{IMAGE}} >/dev/null 2>&1 || docker build -t {{IMAGE}} .
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:{{TRIVY_VERSION}} \
    image --scanners license --license-full {{IMAGE}}

# Same as trivy-license, but show only HIGH/CRITICAL findings (copyleft / restricted)
[group('main-lab')]
trivy-license-high:
  #!/usr/bin/env bash
  set -euo pipefail
  docker image inspect {{IMAGE}} >/dev/null 2>&1 || docker build -t {{IMAGE}} .
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:{{TRIVY_VERSION}} \
    image --scanners license --license-full --severity HIGH,CRITICAL {{IMAGE}}

# Build image (if missing) and run Trivy emitting JSON (vulns + licenses)
[group('main-lab')]
trivy-json:
  #!/usr/bin/env bash
  set -euo pipefail
  command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }
  docker image inspect {{IMAGE}} >/dev/null 2>&1 || docker build -t {{IMAGE}} .
  echo "Running Trivy {{IMAGE}} (vuln + license) -> {{TRIVY_JSON}}..."
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:{{TRIVY_VERSION}} \
    image \
      --format json \
      --scanners vuln,license \
      --license-full \
      --quiet \
      {{IMAGE}} > {{TRIVY_JSON}}
  VULNS=$(jq '[.Results[]?.Vulnerabilities[]?] | length' {{TRIVY_JSON}})
  LICENSES=$(jq '[.Results[]?.Licenses[]?] | length' {{TRIVY_JSON}})
  echo "Trivy: $VULNS vuln findings, $LICENSES license findings"

# Refresh nodegoat-manifests/{package.json,package-lock.json} from upstream NodejsGoat (for GitHub Dependabot/Dependency Review)
[group('main-lab')]
sync-manifests:
  #!/usr/bin/env bash
  set -euo pipefail
  TMP=$(mktemp -d)
  trap "rm -rf $TMP" EXIT

  echo "Cloning OWASP/NodejsGoat to $TMP..."
  git clone --depth 1 https://github.com/OWASP/NodejsGoat.git "$TMP" >/dev/null

  echo "Generating package-lock.json inside node:12-alpine (matches Dockerfile)..."
  docker run --rm \
    -v "$TMP:/app" -w /app \
    node:12-alpine \
    npm install --package-lock-only --no-audit --no-fund >/dev/null

  mkdir -p nodegoat-manifests
  cp "$TMP/package.json" nodegoat-manifests/
  cp "$TMP/package-lock.json" nodegoat-manifests/
  echo "Synced -> nodegoat-manifests/{package.json,package-lock.json}"
  echo "Commit these files so GitHub picks them up."

# Open NodeGoat + Dependency-Track in the browser
[group('main-lab')]
@open:
  open {{APP_URL}} {{DT_FRONTEND}}

# Full teardown of the cesar-beat stack (NodeGoat + Dependency-Track only). Does not touch DefectDojo.
[group('main-lab')]
clean:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Stopping containers and removing volumes..."
  docker compose down -v --remove-orphans
  echo "Removing local artifacts..."
  rm -f {{APIKEY_FILE}} sbom.json {{TRIVY_JSON}} /tmp/dt-response.json /tmp/dt-payload.json
  echo "Removing built image {{IMAGE}}..."
  docker image rm {{IMAGE}} 2>/dev/null || true
  echo "Done. To also drop scanner/DT images, run: just nuke. For DefectDojo, run: just dd-clean / just dd-nuke. For everything, run: just clean-all / just nuke-all"

# Aggressive cleanup: also removes Syft/Trivy and Dependency-Track images
[group('main-lab')]
nuke: clean
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Removing scanner and DT images..."
  docker image rm \
    anchore/syft:{{SYFT_VERSION}} \
    aquasec/trivy:{{TRIVY_VERSION}} \
    dependencytrack/apiserver:{{DT_VERSION}} \
    dependencytrack/frontend:{{DT_VERSION}} \
    mongo:{{MONGO_VERSION}} 2>/dev/null || true
  echo "Done."

# Start DefectDojo stack (first run pulls ~3GB of images)
[group('defectdojo-lab')]
@dd-up:
  docker compose -f {{DD_COMPOSE}} up -d --wait
  # Restart nginx to refresh its DNS cache — if uwsgi/postgres/valkey were recreated
  # while nginx kept running, nginx holds stale IPs and returns 502 until restarted.
  docker compose -f {{DD_COMPOSE}} restart nginx >/dev/null
  echo ""
  echo "DefectDojo: {{DD_URL}}  (admin / {{DD_PASS}})"
  echo "Next: just dd-bootstrap   (get API token, create product + engagement)"
  echo "Then: just dd-scan        (upload sbom.json from 'just scan')"

# Stop and remove DefectDojo containers + volumes
[group('defectdojo-lab')]
@dd-down:
  docker compose -f {{DD_COMPOSE}} down -v

# Tail DefectDojo logs
[group('defectdojo-lab')]
@dd-logs:
  docker compose -f {{DD_COMPOSE}} logs -f --tail=100

# Get API token, create product + engagement
[group('defectdojo-lab')]
dd-bootstrap:
  #!/usr/bin/env bash
  set -euo pipefail
  command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }

  echo "Authenticating to DefectDojo..."
  RESP=$(curl -s -o /tmp/dd-auth.json -w "%{http_code}" -X POST "{{DD_URL}}/api/v2/api-token-auth/" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"{{DD_USER}}\",\"password\":\"{{DD_PASS}}\"}")

  if [ "$RESP" = "502" ] || [ "$RESP" = "503" ]; then
    echo "Error: DefectDojo returned HTTP $RESP — stack may still be initializing or nginx has stale DNS."
    echo "  Try: just dd-up   (refreshes nginx DNS cache), then rerun: just dd-bootstrap"
    exit 1
  fi

  TOKEN=$(jq -r '.token // empty' /tmp/dd-auth.json 2>/dev/null || echo "")
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "Error: could not authenticate with DefectDojo (HTTP $RESP)."
    echo "  DD_USER='{{DD_USER}}' / DD_PASS='{{DD_PASS}}' (from .env or default) do not match the credentials"
    echo "  set when DefectDojo's initializer first ran. DD locks the admin password into its DB on first boot."
    echo ""
    echo "  Recovery options:"
    echo "    1. Reset DefectDojo (loses all data + findings):"
    echo "         just dd-clean && just dd-up && just dd-bootstrap"
    echo "    2. Set DD_PASS in .env to the password used when 'just dd-up' was first run,"
    echo "       then rerun: just dd-bootstrap"
    exit 1
  fi

  echo "$TOKEN" > {{DD_TOKEN_FILE}}
  echo "API token saved to {{DD_TOKEN_FILE}}"

  PROD_ID=$(curl -fsS -H "Authorization: Token $TOKEN" \
    "{{DD_URL}}/api/v2/products/?name={{DD_PRODUCT}}" | jq -r '.results[0].id // empty')
  if [ -z "$PROD_ID" ]; then
    PROD_ID=$(curl -fsS -X POST "{{DD_URL}}/api/v2/products/" \
      -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" \
      -d '{"name":"{{DD_PRODUCT}}","description":"cesar-beat lab","prod_type":1}' \
      | jq -r '.id')
    echo "Created product {{DD_PRODUCT}} (id=$PROD_ID)"
  else
    echo "Product {{DD_PRODUCT}} already exists (id=$PROD_ID)"
  fi

  ENG_ID=$(curl -fsS -H "Authorization: Token $TOKEN" \
    "{{DD_URL}}/api/v2/engagements/?product=$PROD_ID&name={{DD_ENGAGEMENT}}" | jq -r '.results[0].id // empty')
  if [ -z "$ENG_ID" ]; then
    TODAY=$(date -u +%Y-%m-%d)
    ENG_ID=$(curl -fsS -X POST "{{DD_URL}}/api/v2/engagements/" \
      -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" \
      -d "{\"name\":\"{{DD_ENGAGEMENT}}\",\"product\":$PROD_ID,\"target_start\":\"$TODAY\",\"target_end\":\"$TODAY\",\"status\":\"In Progress\",\"engagement_type\":\"CI/CD\"}" \
      | jq -r '.id')
    echo "Created engagement {{DD_ENGAGEMENT}} (id=$ENG_ID)"
  else
    echo "Engagement {{DD_ENGAGEMENT}} already exists (id=$ENG_ID)"
  fi
  echo ""
  echo "Open: {{DD_URL}}/engagement/$ENG_ID"

# Generate Trivy JSON (vulns + licenses) and upload it to DefectDojo
[group('defectdojo-lab')]
dd-scan: _dd-ensure-token trivy-json
  #!/usr/bin/env bash
  set -euo pipefail
  command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }

  TOKEN=$(cat {{DD_TOKEN_FILE}})
  PROD_ID=$(curl -fsS -H "Authorization: Token $TOKEN" "{{DD_URL}}/api/v2/products/?name={{DD_PRODUCT}}" | jq -r '.results[0].id // empty')
  [ -n "$PROD_ID" ] || { echo "Product {{DD_PRODUCT}} not found. Run: just dd-bootstrap"; exit 1; }
  ENG_ID=$(curl -fsS -H "Authorization: Token $TOKEN" "{{DD_URL}}/api/v2/engagements/?product=$PROD_ID&name={{DD_ENGAGEMENT}}" | jq -r '.results[0].id // empty')
  [ -n "$ENG_ID" ] || { echo "Engagement {{DD_ENGAGEMENT}} not found. Run: just dd-bootstrap"; exit 1; }

  echo "Uploading {{TRIVY_JSON}} (Trivy Scan) to engagement $ENG_ID..."
  RESP=$(curl -fsS -X POST "{{DD_URL}}/api/v2/import-scan/" \
    -H "Authorization: Token $TOKEN" \
    -F "scan_type=Trivy Scan" \
    -F "engagement=$ENG_ID" \
    -F "file=@{{TRIVY_JSON}}" \
    -F "active=true" \
    -F "verified=false")
  echo "$RESP" | jq '{test_id, statistics: (.statistics // {})}'
  echo ""
  echo "Open: {{DD_URL}}/engagement/$ENG_ID"

# Open DefectDojo in the browser
[group('defectdojo-lab')]
@dd-open:
  open {{DD_URL}}

# Tear down DefectDojo stack and local artifacts
[group('defectdojo-lab')]
dd-clean:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Stopping DefectDojo containers and removing volumes..."
  docker compose -f {{DD_COMPOSE}} down -v --remove-orphans
  echo "Removing local artifacts..."
  rm -f {{DD_TOKEN_FILE}}

# Aggressive cleanup: dd-clean + remove DefectDojo images
[group('defectdojo-lab')]
dd-nuke: dd-clean
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Removing DefectDojo images..."
  docker image rm \
    defectdojo/defectdojo-django:{{DD_VERSION}} \
    defectdojo/defectdojo-nginx:{{DD_VERSION}} \
    postgres:{{POSTGRES_VERSION}} \
    valkey/valkey:{{VALKEY_VERSION}} 2>/dev/null || true

# Tear down BOTH stacks (cesar-beat + DefectDojo)
[group('both')]
clean-all: clean dd-clean

# Aggressive cleanup for BOTH stacks (clean-all + remove all external images)
[group('both')]
nuke-all: nuke dd-nuke

_ensure-apikey:
  #!/usr/bin/env bash
  [ -f {{APIKEY_FILE}} ] || { echo "No API key. Run: just bootstrap"; exit 1; }

_dd-ensure-token:
  #!/usr/bin/env bash
  [ -f {{DD_TOKEN_FILE}} ] || { echo "No DD token. Run: just dd-bootstrap"; exit 1; }
