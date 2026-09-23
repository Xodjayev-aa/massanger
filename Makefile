# Massanger — one place for the commands that actually work.
#
# Nothing here is magic: every target prints the command it runs (`$(Q)` is empty by
# default, `make Q=@` hides them), so you can copy it out and run it yourself.
# Docker is only required for `supabase start` (the local Postgres/Storage/Realtime
# stack); `make test` runs the whole SQL + bridge suite without Docker.

Q              ?= @
ROOT         := $(CURDIR)
APP_DIR      := $(ROOT)/apps/mobile_app
BRIDGE_DIR   := $(ROOT)/services/telegram_bridge
ENV_LOCAL    := $(ROOT)/supabase/.env
FUNC_ENV     := $(ROOT)/supabase/functions/.env.local
BRIDGE_ENV   := $(ROOT)/services/telegram_bridge/.env
FLUTTER      ?= flutter
NPM          ?= npm

.PHONY: help
help:
	$(Q)printf '%s\n' \
		'bootstrap   install every toolchain dependency (npm + flutter pub get)' \
		'env         create the local .env files from the committed examples' \
		'db-start    supabase start (needs Docker) — local API, Storage, Realtime, Studio' \
		'db-stop     supabase stop' \
		'db-reset    drop the local database and re-apply migrations + seed.sql' \
		'link        supabase link to the project named in supabase/.env, then db push' \
		'bridge      run the TDLib bridge against the database (BRIDGE_TRANSPORT=memory by default)' \
		'bridge-test build and run the bridge test-suite' \
		'sql-test    run the Postgres behaviour suite (PGlite, no Docker)' \
		'app         flutter run the mobile app against the local stack' \
		'test        SQL + seed + bridge + flutter tests' \
		'check       everything CI checks: tests, typechecks, analyze, format' \
		'fmt         prettier + dart format' \
		'deploy      supabase db push + function deploy (reads env from supabase/.env)' \
		'docker-up   docker compose up for the bridge + TDLib sidecar (infra/)' \
		''

# ── setup ────────────────────────────────────────────────────────────────────
.PHONY: bootstrap
bootstrap: env
	$(Q)$(NPM) install
	$(Q)cd $(APP_DIR) && $(FLUTTER) pub get

# Each local secret file is created from the committed example next to it, and never
# overwritten: a developer's real keys must survive a `make bootstrap`.
.PHONY: env
env:
	$(Q)test -f $(FUNC_ENV) || cp $(ROOT)/supabase/functions/.env.example $(FUNC_ENV)
	$(Q)test -f $(BRIDGE_ENV) || cp $(ROOT)/services/telegram_bridge/.env.example $(BRIDGE_ENV)
	$(Q)test -f $(ENV_LOCAL) || printf '%s\n' \
		'# Local project handle for make link / make deploy.' \
		'SUPABASE_PROJECT_REF=' \
		'SUPABASE_DB_PASSWORD=' \
		'# supabase/config.toml reads these with env() for the Google provider in Auth.' \
		'# Same web OAuth client as GOOGLE_WEB_CLIENT_ID / GOOGLE_CLIENT_SECRET in' \
		'# supabase/functions/.env.local: one client, two consumers.' \
		'GOOGLE_OAUTH_CLIENT_ID=' \
		'GOOGLE_OAUTH_CLIENT_SECRET=' > $(ENV_LOCAL)
	$(Q)test -f $(ROOT)/.massanger/app.json || mkdir -p $(ROOT)/.massanger && cp $(ROOT)/apps/mobile_app/env/app.example.json $(ROOT)/.massanger/app.json
	$(Q)echo 'local secret files are in place — fill them in (supabase/.env, $(notdir $(FUNC_ENV)), $(notdir $(BRIDGE_ENV)))'

# ── local database ───────────────────────────────────────────────────────────
.PHONY: db-start
db-start: $(ENV_LOCAL)
	$(Q)supabase start

.PHONY: db-stop
db-stop:
	$(Q)supabase stop

.PHONY: db-reset
db-reset:
	$(Q)supabase db reset

.PHONY: link
link: $(ENV_LOCAL)
	$(Q)ref=$$(sed -n 's/^SUPABASE_PROJECT_REF=//p' $(ENV_LOCAL)); \
	  test -n "$$ref" || { echo 'set SUPABASE_PROJECT_REF in $(ENV_LOCAL) first'; exit 1; }; \
	  echo "linking to $$ref (you will be asked for the database password)"; \
	  supabase link --project-ref "$$ref" && supabase db push

# ── services ─────────────────────────────────────────────────────────────────
.PHONY: bridge
bridge: $(BRIDGE_ENV)
	$(Q)cd $(BRIDGE_DIR) && BRIDGE_TRANSPORT=$${BRIDGE_TRANSPORT:-memory} npm run dev

.PHONY: bridge-test
bridge-test:
	$(Q)cd $(BRIDGE_DIR) && npm test

.PHONY: sql-test
sql-test:
	$(Q)$(NPM) run test:sql

# ── app ──────────────────────────────────────────────────────────────────────
.PHONY: app
app:
	$(Q)cd $(APP_DIR) && $(FLUTTER) run --dart-define-from-file=../../.massanger/app.json

.PHONY: build-ios
build-ios:
	$(Q)cd $(APP_DIR) && $(FLUTTER) build ios --release --no-codesign

.PHONY: build-android
build-android:
	$(Q)cd $(APP_DIR) && $(FLUTTER) build apk --release

# ── verification ──────────────────────────────────────────────────────────────
.PHONY: test
test:
	$(Q)$(NPM) run test
	$(Q)cd $(APP_DIR) && $(FLUTTER) test

.PHONY: check
check:
	$(Q)$(NPM) run check
	$(Q)cd $(APP_DIR) && $(FLUTTER) analyze
	$(Q)cd $(APP_DIR) && $(FLUTTER) test

.PHONY: fmt
fmt:
	$(Q)$(NPM) run fmt
	$(Q)cd $(APP_DIR) && dart format lib test

.PHONY: deploy
deploy:
	$(Q)supabase db push
	$(Q)for f in account-age-gate telegram-ingest telegram-link telegram-send; do \
	  supabase functions deploy "$$f" || exit 1; done

# ── containers ────────────────────────────────────────────────────────────────
.PHONY: docker-up
docker-up: $(BRIDGE_ENV)
	$(Q)docker compose -f infra/docker-compose.yml --env-file $(BRIDGE_ENV) up --build

.PHONY: docker-down
docker-down:
	$(Q)docker compose -f infra/docker-compose.yml down
