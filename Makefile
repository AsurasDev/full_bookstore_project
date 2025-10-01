BACKEND_DIR = bookstore-medusa
STOREFRONT_DIR = bookstore-medusa-storefront
ADMIN_EMAIL = admin@test.com
ADMIN_PASSWORD = password123

backend:
	@if [ ! -d "$(BACKEND_DIR)" ]; then \
		echo "Error: Backend directory not found"; \
		exit 1; \
	fi
	@cd $(BACKEND_DIR) && docker compose -f docker-compose-e2e.yml down -v 2>/dev/null || true
	@cd $(BACKEND_DIR) && docker compose -f docker-compose-e2e.yml up -d
	@echo "Waiting for services to start..."
	@sleep 20
	@echo "Running database migrations..."
	@cd $(BACKEND_DIR) && docker compose -f docker-compose-e2e.yml exec medusa npx medusa db:migrate
	@echo "Seeding initial data..."
	#@cd $(BACKEND_DIR) && docker compose -f docker-compose-e2e.yml exec medusa yarn seed || echo "Seeding skipped or already done"
	@echo "Backend ready at http://localhost:9000"

stop:
	@if [ ! -d "$(BACKEND_DIR)" ]; then \
		echo "Error: Backend directory not found"; \
		exit 1; \
	fi
	@cd $(BACKEND_DIR) && docker compose -f docker-compose-e2e.yml down
	@echo "Services stopped"

create-user: backend
	@if [ ! -d "$(BACKEND_DIR)" ]; then \
		echo "Error: Backend directory not found"; \
		exit 1; \
	fi
	@echo "Creating admin user..."
	@cd $(BACKEND_DIR) && docker compose -f docker-compose-e2e.yml exec medusa npx medusa user -e $(ADMIN_EMAIL) -p $(ADMIN_PASSWORD) 2>/dev/null || \
		(echo "User may already exist or services not ready" && exit 0)
	@echo "Admin user ready"

create-api-key: create-user
	@if [ ! -d "$(BACKEND_DIR)" ]; then \
		echo "Error: Backend directory not found"; \
		exit 1; \
	fi
	@echo "Getting admin authentication token..."
	@TOKEN=$$(curl -s -X POST 'http://localhost:9000/auth/user/emailpass' \
		-H 'Content-Type: application/json' \
		-d '{"email":"$(ADMIN_EMAIL)","password":"$(ADMIN_PASSWORD)"}' \
		| grep -o '"token":"[^"]*"' | cut -d'"' -f4); \
	if [ -z "$$TOKEN" ]; then \
		echo "Failed to get admin token. Make sure backend is running and user exists."; \
		exit 1; \
	fi; \
	echo "Getting default sales channel..."; \
	SALES_CHANNEL_ID=$$(curl -s -X GET 'http://localhost:9000/admin/sales-channels?fields=id,name&limit=1' \
		-H "Authorization: Bearer $$TOKEN" \
		-H 'Content-Type: application/json' \
		| grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4); \
	if [ -z "$$SALES_CHANNEL_ID" ]; then \
		echo "Failed to get sales channel"; \
		exit 1; \
	fi; \
	echo "Creating publishable API key..."; \
	API_KEY_RESPONSE=$$(curl -s -X POST 'http://localhost:9000/admin/api-keys' \
		-H "Authorization: Bearer $$TOKEN" \
		-H 'Content-Type: application/json' \
		-d '{"title":"Frontend Key","type":"publishable"}'); \
	API_KEY=$$(echo "$$API_KEY_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4); \
	API_KEY_ID=$$(echo "$$API_KEY_RESPONSE" | grep -o '"id":"[^"]*"' | cut -d'"' -f4); \
	if [ -z "$$API_KEY" ] || [ -z "$$API_KEY_ID" ]; then \
		echo "Failed to create API key"; \
		exit 1; \
	fi; \
	echo "Associating API key with sales channel..."; \
	curl -s -X POST "http://localhost:9000/admin/api-keys/$$API_KEY_ID/sales-channels" \
		-H "Authorization: Bearer $$TOKEN" \
		-H 'Content-Type: application/json' \
		-d "{\"add\":[\"$$SALES_CHANNEL_ID\"]}" > /dev/null; \
	echo "Generating .env.local from template..."; \
	cp $(STOREFRONT_DIR)/.env.template $(STOREFRONT_DIR)/.env.local; \
	sed -i 's|MEDUSA_BACKEND_URL=.*|MEDUSA_BACKEND_URL=http://medusa:9000|g' $(STOREFRONT_DIR)/.env.local; \
	sed -i 's|NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY=.*|NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY='$$API_KEY'|g' $(STOREFRONT_DIR)/.env.local; \
	echo "API key created, associated with sales channel, and .env.local generated from template"

frontend:
	@if [ ! -d "$(STOREFRONT_DIR)" ]; then \
		echo "Error: Storefront directory not found"; \
		exit 1; \
	fi
	@if [ ! -f "$(STOREFRONT_DIR)/.env.local" ]; then \
		echo "Error: .env.local not found. Run 'make create-api-key' first"; \
		exit 1; \
	fi
	@echo "Starting storefront with Docker..."
	@cd $(STOREFRONT_DIR) && docker compose up -d
	@echo "Storefront ready at http://localhost:8000"

stop-frontend:
	@if [ ! -d "$(STOREFRONT_DIR)" ]; then \
		echo "Error: Storefront directory not found"; \
		exit 1; \
	fi
	@cd $(STOREFRONT_DIR) && docker compose down
	@echo "Storefront stopped"

e2e: stop backend create-user create-api-key stop-frontend frontend
	@echo "E2E environment is up and running!"
	@echo "Backend: http://localhost:9000"
	@echo "Storefront: http://localhost:8000"
	@echo "Admin User: $(ADMIN_EMAIL) / $(ADMIN_PASSWORD)"
	@echo "\n--- Following storefront logs (Ctrl+C to stop) ---"
	@docker logs -f medusa_storefront
