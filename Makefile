# MessengerX — one place for the commands that actually work.
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
		'link        supabase link only — does not push migrations' \
		'bridge      run the TDLib bridge against the database (BRIDGE_TRANSPORT=memory by default)' \
		'bridge-test build and run the bridge test-suite' \
		'sql-test    run the Postgres behaviour suite (PGlite, no Docker)' \
		'app         flutter run the mobile app against the local stack' \
		'web         placeholder Flutter web build at / (not a live deploy)' \
		'build-android  DEBUG APK with local config; not a signed public release' \
		'build-ios  unsigned iOS compile; needs Xcode/Mac and is not a release' \
		'test        SQL + seed + bridge + flutter tests' \
		'check       everything CI checks: tests, typechecks, analyze, format' \
		'fmt         prettier + dart format' \
		'deploy      supabase db push + function deploy (reads env from supabase/.env)' \
		'docker-up   docker compose up for the bridge with TDLib in-process (infra/)' \
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
		'# Google OAuth web client for local Supabase Auth (no Gmail/Drive scopes).' \
		'GOOGLE_OAUTH_CLIENT_ID=' \
		'GOOGLE_OAUTH_CLIENT_SECRET=' > $(ENV_LOCAL)
	$(Q)test -f $(ROOT)/.messengerx/app.json || mkdir -p $(ROOT)/.messengerx && cp $(ROOT)/apps/mobile_app/env/app.example.json $(ROOT)/.messengerx/app.json
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
	$(Q)echo 'Resetting the LOCAL Supabase database only. Never run `supabase db reset` or `supabase db reset --linked` on a hosted project.'
	$(Q)supabase db reset

.PHONY: link
link: $(ENV_LOCAL)
	$(Q)ref=$$(sed -n 's/^SUPABASE_PROJECT_REF=//p' $(ENV_LOCAL)); \
	  test -n "$$ref" || { echo 'set SUPABASE_PROJECT_REF in $(ENV_LOCAL) first'; exit 1; }; \
	  echo "linking to $$ref (you will be asked for the database password)"; \
	  echo 'link does not push. Read docs/vercel.md before supabase db push. Never db reset a hosted project.'; \
	  supabase link --project-ref "$$ref"

# ── services ─────────────────────────────────────────────────────────────────
.PHONY: bridge
bridge: $(BRIDGE_ENV)
	$(Q)cd $(BRIDGE_DIR) && BRIDGE_TRANSPORT=$${BRIDGE_TRANSPORT:-memory} MESSENGERX_ENV=$${MESSENGERX_ENV:-development} npm run dev

.PHONY: bridge-test
bridge-test:
	$(Q)cd $(BRIDGE_DIR) && npm test

.PHONY: sql-test
sql-test:
	$(Q)$(NPM) run test:sql

# ── app ──────────────────────────────────────────────────────────────────────
.PHONY: app
app:
	$(Q)cd $(APP_DIR) && $(FLUTTER) run --dart-define-from-file=../../.messengerx/app.json

.PHONY: web
web:
	$(Q)bash $(APP_DIR)/tool/vercel_build.sh build --placeholder

.PHONY: build-ios
build-ios:
	$(Q)echo 'iOS unsigned compile only; requires Mac/Xcode and is not installable.'
	$(Q)cd $(APP_DIR) && $(FLUTTER) build ios --release --no-codesign --dart-define-from-file=../../.messengerx/app.json

.PHONY: build-android
build-android:
	$(Q)echo 'Android DEBUG only; release signing and device verification are not configured.'
	$(Q)cd $(APP_DIR) && $(FLUTTER) build apk --debug --dart-define-from-file=../../.messengerx/app.json

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
	$(Q)test "$(MESSENGERX_CONFIRM_HOSTED_PUSH)" = "yes" || { \
	  echo 'Refusing hosted deploy. This pushes migrations and functions to the linked Supabase project.'; \
	  echo 'Read docs/vercel.md. Never run supabase db reset on production.'; \
	  echo 'When you intend this: MESSENGERX_CONFIRM_HOSTED_PUSH=yes make deploy'; \
	  exit 1; \
	}
	$(Q)supabase db push
	$(Q)for f in account-age-gate telegram-ingest telegram-link telegram-send web-push-send; do \
	  supabase functions deploy "$$f" || exit 1; done

# ── containers ────────────────────────────────────────────────────────────────
.PHONY: docker-up
docker-up: $(BRIDGE_ENV)
	$(Q)docker compose -f infra/docker-compose.yml --env-file $(BRIDGE_ENV) up --build

.PHONY: docker-down
docker-down:
	$(Q)docker compose -f infra/docker-compose.yml down
