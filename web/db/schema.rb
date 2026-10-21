# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_22_030000) do
  create_table "BackupLog", id: :string, force: :cascade do |t|
    t.string "driveFileId"
    t.string "driveUrl"
    t.text "error"
    t.string "fileName"
    t.integer "fileSize"
    t.datetime "finishedAt"
    t.datetime "startedAt", null: false
    t.string "status", default: "running", null: false
    t.string "tenant_id"
    t.index ["tenant_id", "startedAt"], name: "index_BackupLog_on_tenant_id_and_startedAt"
  end

  create_table "InventoryCount", id: :string, force: :cascade do |t|
    t.datetime "appliedAt"
    t.datetime "approvedAt"
    t.datetime "countedAt", null: false
    t.string "createdBy"
    t.string "locationId"
    t.string "note"
    t.string "status", default: "draft", null: false
    t.string "tenant_id"
    t.index ["tenant_id", "countedAt"], name: "index_InventoryCount_on_tenant_id_and_countedAt"
  end

  create_table "InventoryCountItem", id: :string, force: :cascade do |t|
    t.boolean "applied", default: false, null: false
    t.string "countId", null: false
    t.integer "previousQuantity"
    t.integer "quantity", default: 0, null: false
    t.string "shopifyVariantId"
    t.string "sku", null: false
    t.string "squareVariationId"
    t.string "tenant_id"
    t.text "comparison_snapshot"
    t.index ["countId"], name: "index_InventoryCountItem_on_countId"
    t.index ["tenant_id"], name: "index_InventoryCountItem_on_tenant_id"
  end

  create_table "InventoryLevel", id: :string, force: :cascade do |t|
    t.integer "available", default: 0
    t.string "locationId", null: false
    t.integer "quantity", default: 0
    t.string "shopifyVariantId"
    t.string "source", null: false
    t.string "squareVariationId"
    t.string "tenant_id"
    t.datetime "updatedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.integer "sourceQuantity"
    t.index ["locationId"], name: "index_InventoryLevel_on_locationId"
    t.index ["shopifyVariantId"], name: "index_InventoryLevel_on_shopifyVariantId"
    t.index ["tenant_id", "source", "locationId", "shopifyVariantId"], name: "idx_inventory_levels_tenant_source_loc_shopify", unique: true
    t.index ["tenant_id", "source", "locationId", "squareVariationId"], name: "idx_inventory_levels_tenant_source_loc_square", unique: true
    t.index ["tenant_id", "source", "shopifyVariantId"], name: "idx_inventory_levels_tenant_source_shopify_variant"
    t.index ["tenant_id", "source", "squareVariationId"], name: "idx_inventory_levels_tenant_source_square_variation"
    t.index ["tenant_id"], name: "index_InventoryLevel_on_tenant_id"
  end

  create_table "InventoryMovement", id: :string, force: :cascade do |t|
    t.string "actor"
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.integer "delta", default: 0
    t.string "direction", null: false
    t.integer "quantityAfter", null: false
    t.integer "quantityBefore", null: false
    t.string "reason"
    t.string "reference"
    t.string "shopifyVariantId"
    t.string "sku"
    t.string "source", null: false
    t.string "squareVariationId"
    t.string "syncRunId"
    t.string "tenant_id"
    t.index ["createdAt"], name: "index_InventoryMovement_on_createdAt"
    t.index ["shopifyVariantId"], name: "index_InventoryMovement_on_shopifyVariantId"
    t.index ["source"], name: "index_InventoryMovement_on_source"
    t.index ["syncRunId"], name: "index_InventoryMovement_on_syncRunId"
    t.index ["tenant_id", "sku"], name: "idx_inventory_movements_tenant_sku"
    t.index ["tenant_id", "source", "createdAt"], name: "idx_inventory_movements_tenant_source_created_at"
    t.index ["tenant_id", "squareVariationId"], name: "idx_inventory_movements_tenant_square_variation"
    t.index ["tenant_id"], name: "index_InventoryMovement_on_tenant_id"
  end

  create_table "InventoryPolicy", primary_key: "sku", id: :string, force: :cascade do |t|
    t.integer "max"
    t.integer "min"
    t.string "note"
    t.string "priority", default: "lowest"
    t.string "tenant_id"
    t.datetime "updatedAt", null: false
    t.index ["priority"], name: "index_InventoryPolicy_on_priority"
    t.index ["tenant_id"], name: "index_InventoryPolicy_on_tenant_id"
  end

  create_table "LedgerEntry", id: :string, force: :cascade do |t|
    t.string "currency", null: false
    t.integer "grossCents", null: false
    t.integer "lineItems", null: false
    t.datetime "occurredAt", null: false
    t.string "orderName"
    t.string "source", null: false
    t.string "sourceOrderId", null: false
    t.string "status", null: false
    t.string "summary"
    t.datetime "syncedAt", null: false
    t.string "tenant_id"
    t.index ["occurredAt"], name: "index_LedgerEntry_on_occurredAt"
    t.index ["source"], name: "index_LedgerEntry_on_source"
    t.index ["tenant_id", "occurredAt"], name: "idx_ledger_entries_tenant_occurred_at"
    t.index ["tenant_id"], name: "index_LedgerEntry_on_tenant_id"
  end

  create_table "Location", id: :string, force: :cascade do |t|
    t.boolean "active", default: true
    t.string "externalId", null: false
    t.string "kind"
    t.string "name", null: false
    t.boolean "primary_location", default: false, null: false
    t.string "source", null: false
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.string "timezone"
    t.index ["source"], name: "index_Location_on_source"
    t.index ["tenant_id", "source", "externalId"], name: "index_Location_on_tenant_source_externalId", unique: true
    t.index ["tenant_id", "source", "primary_location"], name: "idx_locations_tenant_source_primary"
    t.index ["tenant_id"], name: "index_Location_on_tenant_id"
  end

  create_table "ReconcileItem", id: :string, force: :cascade do |t|
    t.string "actions"
    t.integer "drift"
    t.boolean "ok"
    t.string "priority", default: "lowest"
    t.string "product"
    t.string "runId", null: false
    t.integer "shopifyDelta"
    t.integer "shopifyQty"
    t.string "sku", null: false
    t.integer "squareDelta"
    t.integer "squareQty"
    t.integer "target"
    t.string "tenant_id"
    t.boolean "tracked", default: false
    t.string "variant"
    t.index ["runId"], name: "index_ReconcileItem_on_runId"
    t.index ["sku"], name: "index_ReconcileItem_on_sku"
    t.index ["tenant_id"], name: "index_ReconcileItem_on_tenant_id"
  end

  create_table "ReconcileRun", id: :string, force: :cascade do |t|
    t.integer "actionable", default: 0
    t.integer "applied", default: 0
    t.integer "failed", default: 0
    t.datetime "finishedAt"
    t.string "mode", default: "manual"
    t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "status", default: "pending"
    t.string "tenant_id"
    t.integer "totalRows", default: 0
    t.index ["startedAt"], name: "index_ReconcileRun_on_startedAt"
    t.index ["status"], name: "index_ReconcileRun_on_status"
    t.index ["tenant_id"], name: "index_ReconcileRun_on_tenant_id"
  end

  create_table "ShopifyProduct", id: :string, force: :cascade do |t|
    t.string "featuredImageUrl"
    t.string "handle"
    t.datetime "publishedAt"
    t.string "status", default: "ACTIVE"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tags"
    t.string "tenant_id"
    t.string "title", null: false
    t.integer "totalInventory", default: 0
    t.boolean "catalog_present"
    t.datetime "catalog_read_at"
    t.index ["status"], name: "index_ShopifyProduct_on_status"
    t.index ["tenant_id"], name: "index_ShopifyProduct_on_tenant_id"
    t.index ["title"], name: "index_ShopifyProduct_on_title"
  end

  create_table "ShopifyVariant", id: :string, force: :cascade do |t|
    t.string "barcode"
    t.float "compareAtPrice"
    t.string "inventoryItemId"
    t.integer "inventoryQuantity", default: 0
    t.float "price"
    t.string "productId", null: false
    t.string "sku"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.string "title", null: false
    t.boolean "tracked", default: false
    t.boolean "catalog_present"
    t.datetime "catalog_read_at"
    t.index ["productId"], name: "index_ShopifyVariant_on_productId"
    t.index ["sku", "productId"], name: "idx_shopify_variants_sku_product"
    t.index ["sku"], name: "index_ShopifyVariant_on_sku"
    t.index ["tenant_id", "inventoryItemId"], name: "idx_shopify_variants_tenant_inventory_item_id"
    t.index ["tenant_id"], name: "index_ShopifyVariant_on_tenant_id"
    t.index ["tracked"], name: "index_ShopifyVariant_on_tracked"
  end

  create_table "SkuLink", id: :string, force: :cascade do |t|
    t.boolean "auto", default: true
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "matchSource", default: "sku"
    t.string "shopifyVariantId"
    t.string "sku", null: false
    t.string "squareVariationId"
    t.string "tenant_id"
    t.index ["shopifyVariantId", "squareVariationId"], name: "SkuLink_shopifyVariantId_squareVariationId_key", unique: true
    t.index ["shopifyVariantId"], name: "index_SkuLink_on_shopifyVariantId", unique: true
    t.index ["sku"], name: "index_SkuLink_on_sku"
    t.index ["tenant_id", "squareVariationId"], name: "idx_sku_links_tenant_square_variation"
    t.index ["tenant_id"], name: "index_SkuLink_on_tenant_id"
  end

  create_table "SquareItem", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.index ["tenant_id"], name: "index_SquareItem_on_tenant_id"
  end

  create_table "SquareVariation", id: :string, force: :cascade do |t|
    t.string "itemId", null: false
    t.string "name", null: false
    t.string "sku"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.index ["itemId"], name: "index_SquareVariation_on_itemId"
    t.index ["sku"], name: "index_SquareVariation_on_sku"
    t.index ["tenant_id"], name: "index_SquareVariation_on_tenant_id"
  end

  create_table "StockAlert", id: :string, force: :cascade do |t|
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "note"
    t.integer "quantity", default: 0
    t.datetime "resolvedAt"
    t.string "shopifyVariantId"
    t.string "sku"
    t.string "squareVariationId"
    t.string "status", default: "open"
    t.string "tenant_id"
    t.integer "threshold", default: 5
    t.index ["shopifyVariantId"], name: "index_StockAlert_on_shopifyVariantId"
    t.index ["squareVariationId"], name: "index_StockAlert_on_squareVariationId"
    t.index ["status"], name: "index_StockAlert_on_status"
    t.index ["tenant_id"], name: "index_StockAlert_on_tenant_id"
  end

  create_table "SyncRun", id: :string, force: :cascade do |t|
    t.string "actor", default: "scheduler"
    t.string "details"
    t.string "error"
    t.datetime "finishedAt"
    t.string "mode", null: false
    t.string "source"
    t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "status", null: false
    t.string "tenant_id"
    t.index ["startedAt"], name: "index_SyncRun_on_startedAt"
    t.index ["status", "finishedAt"], name: "idx_sync_runs_status_finished_at"
    t.index ["status"], name: "index_SyncRun_on_status"
    t.index ["tenant_id", "startedAt"], name: "idx_sync_runs_tenant_started_at"
    t.index ["tenant_id"], name: "index_SyncRun_on_running_per_tenant", unique: true, where: "status = 'running'"
    t.index ["tenant_id"], name: "index_SyncRun_on_tenant_id"
  end

  create_table "uploads", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "status", default: "received", null: false
    t.string "origin", default: "web", null: false
    t.string "filename", null: false
    t.string "client_content_type"
    t.string "file_format"
    t.integer "byte_size", default: 0, null: false
    t.string "sha256"
    t.boolean "retained", default: false, null: false
    t.text "content_base64"
    t.integer "duplicate_of_id"
    t.string "detected_type"
    t.string "detected_label"
    t.integer "confidence"
    t.text "detected_reason"
    t.string "source_guess"
    t.text "candidates_json"
    t.string "importer_key"
    t.boolean "operator_chosen", default: false, null: false
    t.text "params_json"
    t.integer "row_count"
    t.text "reason"
    t.text "summary_json"
    t.string "dry_run_digest"
    t.datetime "dry_run_at"
    t.string "dry_run_by_name"
    t.string "recognizer_version"
    t.datetime "recognized_at"
    t.integer "uploaded_by_id"
    t.string "uploaded_by_name"
    t.string "via_token_label"
    t.datetime "imported_at"
    t.integer "imported_by_id"
    t.string "imported_by_name"
    t.string "result_path"
    t.datetime "discarded_at"
    t.string "discarded_by_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["duplicate_of_id"], name: "index_uploads_on_duplicate_of_id"
    t.index ["tenant_id", "created_at"], name: "idx_uploads_recent"
    t.index ["tenant_id", "sha256"], name: "idx_uploads_retained_replay", unique: true, where: "retained = 1"
    t.index ["tenant_id", "status"], name: "idx_uploads_status"
    t.index ["tenant_id"], name: "index_uploads_on_tenant_id"
  end

  create_table "WarehouseShare", id: :string, force: :cascade do |t|
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "expires_at"
    t.string "name", null: false
    t.decimal "priceMultiplier", precision: 10, scale: 4, default: "1.0", null: false
    t.string "status", default: "active", null: false
    t.string "tenantId"
    t.string "token", null: false
    t.boolean "useCustomTiers", default: false, null: false
    t.index ["tenantId"], name: "index_WarehouseShare_on_tenantId"
    t.index ["token", "expires_at"], name: "idx_warehouse_share_token_expiry"
    t.index ["token"], name: "index_WarehouseShare_on_token", unique: true
  end

  create_table "WarehouseTier", id: :string, force: :cascade do |t|
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.decimal "discountPercent", precision: 10, scale: 4, null: false
    t.integer "minQty", null: false
    t.string "shareId"
    t.string "tenantId"
    t.index ["shareId", "minQty"], name: "index_WarehouseTier_on_shareId_and_minQty", unique: true
    t.index ["shareId"], name: "index_WarehouseTier_on_shareId"
    t.index ["tenantId"], name: "index_WarehouseTier_on_tenantId"
  end

  create_table "access_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "detail"
    t.string "domain"
    t.string "email"
    t.string "ip"
    t.string "source"
    t.string "status"
    t.string "tenant_id"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id"
    t.index ["tenant_id", "created_at"], name: "index_access_logs_on_tenant_id_and_created_at"
    t.index ["tenant_id", "status"], name: "index_access_logs_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_access_logs_on_tenant_id"
  end

  create_table "accounts", force: :cascade do |t|
    t.string "account_type", null: false
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "normal_balance", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "account_type"], name: "index_accounts_on_tenant_id_and_account_type"
    t.index ["tenant_id", "code"], name: "index_accounts_on_tenant_id_and_code", unique: true
  end

  create_table "activity_logs", force: :cascade do |t|
    t.string "action", null: false
    t.string "actor_name"
    t.datetime "created_at", null: false
    t.text "details"
    t.string "subject_id"
    t.string "subject_label"
    t.string "subject_type"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["tenant_id", "created_at"], name: "index_activity_logs_on_tenant_id_and_created_at"
    t.index ["tenant_id", "subject_type", "subject_id"], name: "idx_on_tenant_id_subject_type_subject_id_034734a708"
  end

  create_table "agent_feedbacks", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "api_access_token_id"
    t.bigint "user_id"
    t.string "kind", null: false
    t.string "severity", default: "normal", null: false
    t.string "status", default: "new", null: false
    t.string "summary", null: false
    t.text "details"
    t.string "related_tool"
    t.string "related_reference"
    t.string "agent_name"
    t.string "agent_model"
    t.text "context"
    t.text "owner_notes"
    t.bigint "triaged_by_id"
    t.datetime "triaged_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source", default: "agent", null: false
    t.string "source_ref"
    t.string "source_sender"
    t.bigint "task_id"
    t.boolean "ready_for_development", default: false, null: false
    t.datetime "ready_marked_at"
    t.string "ready_marked_by"
    t.index ["api_access_token_id"], name: "index_agent_feedbacks_on_api_access_token_id"
    t.index ["task_id"], name: "index_agent_feedbacks_on_task_id"
    t.index ["tenant_id", "created_at"], name: "index_agent_feedbacks_on_tenant_id_and_created_at"
    t.index ["tenant_id", "source_ref"], name: "idx_agent_feedbacks_source_ref"
    t.index ["tenant_id", "status"], name: "index_agent_feedbacks_on_tenant_id_and_status"
    t.index ["tenant_id", "user_id", "created_at"], name: "idx_agent_feedbacks_reporter"
  end

  create_table "agent_tool_issues", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "tool_name", null: false
    t.string "error_kind", null: false
    t.integer "occurrences", default: 0, null: false
    t.string "last_message"
    t.string "last_api_access_token_id"
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "last_seen_at"], name: "index_agent_tool_issues_on_tenant_id_and_last_seen_at"
    t.index ["tenant_id", "tool_name", "error_kind"], name: "idx_agent_tool_issues_unique", unique: true
  end

  create_table "ai_agent_runs", force: :cascade do |t|
    t.string "agent", default: "buzz", null: false
    t.string "model"
    t.string "outcome", null: false
    t.string "error_type"
    t.integer "tokens_in", default: 0, null: false
    t.integer "tokens_out", default: 0, null: false
    t.integer "tokens_reasoning", default: 0, null: false
    t.integer "cache_read_tokens", default: 0, null: false
    t.integer "cache_write_tokens", default: 0, null: false
    t.decimal "cost_usd", precision: 12, scale: 6
    t.integer "steps", default: 0, null: false
    t.integer "duration_ms"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["occurred_at"], name: "index_ai_agent_runs_on_occurred_at"
  end

  create_table "ai_health_checks", force: :cascade do |t|
    t.string "provider", default: "opencode", null: false
    t.string "triggered_by", default: "scheduled", null: false
    t.string "status", null: false
    t.string "key_state", default: "unchecked", null: false
    t.string "error_type"
    t.string "error_code"
    t.integer "http_status"
    t.integer "latency_ms"
    t.integer "catalog_latency_ms"
    t.boolean "rate_limited", default: false, null: false
    t.integer "retry_after_seconds"
    t.string "configured_model"
    t.string "model_state", default: "unknown", null: false
    t.text "free_models"
    t.integer "free_model_count", default: 0, null: false
    t.integer "catalog_size"
    t.datetime "checked_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["checked_at"], name: "index_ai_health_checks_on_checked_at"
  end

  create_table "api_access_tokens", id: :string, force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "user_id", null: false
    t.string "name", null: false
    t.string "token_digest", null: false
    t.string "token_hint", null: false
    t.text "scopes", null: false
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["tenant_id", "created_at"], name: "idx_api_tokens_tenant_created"
    t.index ["token_digest"], name: "index_api_access_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_access_tokens_on_user_id"
  end

  create_table "ask_rupert_conversations", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "user_id", null: false
    t.string "title"
    t.datetime "last_message_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "user_id", "last_message_at"], name: "idx_ask_rupert_conversations_owner"
  end

  create_table "ask_rupert_messages", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "user_id", null: false
    t.integer "conversation_id", null: false
    t.string "role", null: false
    t.string "status", default: "done", null: false
    t.text "content", default: "", null: false
    t.text "links"
    t.text "report_draft"
    t.string "provider"
    t.string "model"
    t.string "page_path"
    t.integer "tokens_in", default: 0, null: false
    t.integer "tokens_out", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "id"], name: "idx_ask_rupert_messages_thread"
    t.index ["conversation_id"], name: "index_ask_rupert_messages_on_conversation_id"
  end

  create_table "ask_rupert_usages", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "user_id", null: false
    t.string "outcome", default: "pending", null: false
    t.string "provider"
    t.string "model"
    t.integer "tokens_in", default: 0, null: false
    t.integer "tokens_out", default: 0, null: false
    t.integer "tool_calls", default: 0, null: false
    t.integer "duration_ms"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "created_at"], name: "idx_ask_rupert_usages_tenant"
    t.index ["tenant_id", "user_id", "created_at"], name: "idx_ask_rupert_usages_user"
  end

  create_table "authorize_net_batches", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "environment", null: false
    t.string "gateway_id", null: false
    t.string "source_batch_id", null: false
    t.datetime "settled_at"
    t.string "settlement_state", null: false
    t.string "payment_method"
    t.json "statistics", default: [], null: false
    t.datetime "observed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "environment", "gateway_id", "source_batch_id"], name: "idx_anet_batch_source", unique: true
    t.index ["tenant_id"], name: "index_authorize_net_batches_on_tenant_id"
  end

  create_table "authorize_net_portal_exports", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "gateway_id", null: false
    t.string "kind", null: false
    t.string "fingerprint", null: false
    t.string "sha256", null: false
    t.datetime "exported_at", null: false
    t.text "original_csv", null: false
    t.text "records_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "fingerprint"], name: "idx_anet_portal_fingerprint", unique: true
    t.index ["tenant_id"], name: "index_authorize_net_portal_exports_on_tenant_id"
  end

  create_table "authorize_net_portal_observations", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "authorize_net_portal_export_id", null: false
    t.integer "position", null: false
    t.string "gateway_id", null: false
    t.string "transaction_id", null: false
    t.datetime "exported_at", null: false
    t.datetime "submitted_at"
    t.datetime "settled_at"
    t.string "status"
    t.string "transaction_type"
    t.string "currency"
    t.bigint "settlement_cents"
    t.text "record_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["authorize_net_portal_export_id", "position"], name: "idx_anet_portal_obs_row", unique: true
    t.index ["tenant_id", "settled_at"], name: "idx_anet_portal_obs_settled"
    t.index ["tenant_id", "submitted_at"], name: "idx_anet_portal_obs_submitted"
    t.index ["tenant_id", "transaction_id", "gateway_id"], name: "idx_anet_portal_obs_key"
  end

  create_table "authorize_net_sale_links", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "authorize_net_transaction_id", null: false
    t.integer "order_id", null: false
    t.integer "reviewed_by_id", null: false
    t.text "evidence_note", null: false
    t.datetime "revoked_at"
    t.integer "revoked_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["authorize_net_transaction_id"], name: "idx_anet_link_transaction"
    t.index ["order_id"], name: "index_authorize_net_sale_links_on_order_id"
    t.index ["reviewed_by_id"], name: "index_authorize_net_sale_links_on_reviewed_by_id"
    t.index ["revoked_by_id"], name: "index_authorize_net_sale_links_on_revoked_by_id"
    t.index ["tenant_id", "authorize_net_transaction_id"], name: "idx_anet_link_active_payment", unique: true, where: "revoked_at IS NULL"
    t.index ["tenant_id", "order_id"], name: "idx_anet_link_active_order", unique: true, where: "revoked_at IS NULL"
    t.index ["tenant_id"], name: "index_authorize_net_sale_links_on_tenant_id"
  end

  create_table "authorize_net_transactions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "environment", null: false
    t.string "gateway_id", null: false
    t.string "source_transaction_id", null: false
    t.string "reference_transaction_id"
    t.string "source_batch_id"
    t.string "transaction_type", null: false
    t.string "payment_status", null: false
    t.datetime "submitted_at", null: false
    t.datetime "settled_at"
    t.string "settlement_state"
    t.string "currency"
    t.decimal "authorized_amount", precision: 19, scale: 4, null: false
    t.decimal "settled_amount", precision: 19, scale: 4, null: false
    t.decimal "tip_amount", precision: 19, scale: 4
    t.decimal "surcharge_amount", precision: 19, scale: 4
    t.string "market_type"
    t.string "product"
    t.datetime "observed_at", null: false
    t.json "status_history", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "invoice_number"
    t.index ["tenant_id", "environment", "gateway_id", "source_transaction_id"], name: "idx_anet_transaction_source", unique: true
    t.index ["tenant_id"], name: "index_authorize_net_transactions_on_tenant_id"
  end

  create_table "bank_statement_accounts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "account_label", null: false
    t.integer "ledger_account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ledger_account_id"], name: "index_bank_statement_accounts_on_ledger_account_id"
    t.index ["tenant_id", "account_label"], name: "idx_bank_account_labels", unique: true
    t.index ["tenant_id", "ledger_account_id"], name: "idx_bank_account_ledgers", unique: true
    t.index ["tenant_id"], name: "index_bank_statement_accounts_on_tenant_id"
  end

  create_table "bank_statement_lines", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "document_id", null: false
    t.string "account_label", null: false
    t.integer "line_no", null: false
    t.date "posted_on", null: false
    t.text "description", null: false
    t.integer "amount_cents", null: false
    t.string "fingerprint", null: false
    t.string "status", default: "pending", null: false
    t.integer "expense_id"
    t.integer "vendor_payment_id"
    t.integer "decided_by_id"
    t.string "decided_by_name"
    t.datetime "decided_at"
    t.datetime "created_at", null: false
    t.string "review_category"
    t.text "review_note"
    t.boolean "review_flag", default: false, null: false
    t.datetime "reviewed_at"
    t.bigint "journal_entry_id"
    t.text "counterparty"
    t.index ["tenant_id", "account_label", "journal_entry_id"], name: "idx_bank_lines_account_journal_unique", unique: true, where: "journal_entry_id IS NOT NULL"
    t.index ["tenant_id", "document_id", "status"], name: "idx_bank_lines_document"
    t.index ["tenant_id", "fingerprint"], name: "idx_bank_lines_fingerprint", unique: true
    t.index ["tenant_id"], name: "index_bank_statement_lines_on_tenant_id"
  end

  create_table "book_approvals", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "period_kind", null: false
    t.date "period_from", null: false
    t.date "period_to", null: false
    t.string "status", null: false
    t.string "report_digest", null: false
    t.text "summary_json", null: false
    t.text "notes"
    t.integer "approved_by_id"
    t.string "approved_by_name", null: false
    t.datetime "approved_at", null: false
    t.string "ip"
    t.string "user_agent"
    t.string "prev_hash", null: false
    t.string "entry_hash", null: false
    t.datetime "created_at", null: false
    t.index ["approved_by_id"], name: "index_book_approvals_on_approved_by_id"
    t.index ["entry_hash"], name: "idx_book_approvals_entry_hash", unique: true
    t.index ["tenant_id", "period_kind", "period_from"], name: "idx_book_approvals_period"
    t.index ["tenant_id"], name: "index_book_approvals_on_tenant_id"
  end

  create_table "bulk_consumptions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "source", null: false
    t.string "source_order_id", null: false
    t.string "source_line_id", null: false
    t.string "source_variant_id", null: false
    t.string "order_number"
    t.bigint "quantity", null: false
    t.integer "bulk_recipe_id", null: false
    t.integer "bulk_lot_id", null: false
    t.integer "bulk_movement_id", null: false
    t.bigint "mg_per_unit", null: false
    t.bigint "consumed_mg", null: false
    t.string "source_fingerprint", null: false
    t.string "request_fingerprint", null: false
    t.string "request_token", null: false
    t.string "created_by", null: false
    t.datetime "created_at", null: false
    t.index ["bulk_movement_id"], name: "index_bulk_consumptions_on_bulk_movement_id", unique: true
    t.index ["tenant_id", "bulk_lot_id", "created_at"], name: "idx_bulk_consumption_lot"
    t.index ["tenant_id", "bulk_recipe_id"], name: "idx_bulk_consumption_recipe"
    t.index ["tenant_id", "request_token"], name: "idx_bulk_consumption_request", unique: true
    t.index ["tenant_id", "source", "source_order_id", "source_line_id"], name: "idx_bulk_consumption_source_line", unique: true
    t.check_constraint "source = 'shopify' AND quantity > 0 AND mg_per_unit > 0 AND consumed_mg > 0", name: "bulk_consumption_positive"
  end

  create_table "bulk_lots", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "bulk_material_id", null: false
    t.string "code", null: false
    t.string "note"
    t.string "receipt_token", null: false
    t.bigint "balance_mg", default: 0, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "bulk_material_id", "code"], name: "idx_bulk_lots_material_code", unique: true
    t.index ["tenant_id", "receipt_token"], name: "index_bulk_lots_on_tenant_id_and_receipt_token", unique: true
    t.check_constraint "balance_mg >= 0", name: "bulk_lots_nonnegative_balance"
  end

  create_table "bulk_materials", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "name", null: false
    t.string "unit", default: "g", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_bulk_materials_on_tenant_id_and_name", unique: true
  end

  create_table "bulk_movements", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "bulk_lot_id", null: false
    t.string "kind", null: false
    t.bigint "delta_mg", null: false
    t.string "input_quantity", null: false
    t.string "input_unit", null: false
    t.string "reference", null: false
    t.string "request_token", null: false
    t.string "created_by", null: false
    t.datetime "created_at", null: false
    t.index ["tenant_id", "bulk_lot_id", "created_at", "id"], name: "idx_bulk_movements_lot_timeline"
    t.index ["tenant_id", "request_token"], name: "index_bulk_movements_on_tenant_id_and_request_token", unique: true
    t.check_constraint "(kind = 'receipt' AND delta_mg > 0) OR (kind = 'consume' AND delta_mg < 0) OR kind = 'adjustment'", name: "bulk_movements_kind_sign"
    t.check_constraint "delta_mg <> 0", name: "bulk_movements_nonzero"
  end

  create_table "bulk_recipes", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "source", default: "shopify", null: false
    t.string "source_variant_id", null: false
    t.integer "bulk_material_id", null: false
    t.integer "version", null: false
    t.bigint "mg_per_unit", null: false
    t.datetime "effective_from", null: false
    t.string "catalog_title", null: false
    t.string "catalog_sku"
    t.string "created_by", null: false
    t.datetime "created_at", null: false
    t.index ["tenant_id", "bulk_material_id"], name: "idx_bulk_recipe_material"
    t.index ["tenant_id", "source", "source_variant_id", "effective_from"], name: "idx_bulk_recipe_effective"
    t.index ["tenant_id", "source", "source_variant_id", "version"], name: "idx_bulk_recipe_version", unique: true
    t.check_constraint "source = 'shopify' AND version > 0 AND mg_per_unit > 0", name: "bulk_recipe_positive"
  end

  create_table "clock_corrections", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "clock_shift_id", null: false
    t.integer "requested_by_id"
    t.integer "reviewed_by_id"
    t.datetime "original_started_at", null: false
    t.datetime "original_ended_at"
    t.datetime "proposed_started_at", null: false
    t.datetime "proposed_ended_at", null: false
    t.text "reason", null: false
    t.string "status", default: "pending", null: false
    t.datetime "reviewed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["clock_shift_id"], name: "index_clock_corrections_on_clock_shift_id"
    t.index ["requested_by_id"], name: "index_clock_corrections_on_requested_by_id"
    t.index ["reviewed_by_id"], name: "index_clock_corrections_on_reviewed_by_id"
    t.index ["tenant_id", "status", "created_at"], name: "idx_clock_correction_review"
    t.check_constraint "proposed_ended_at > proposed_started_at", name: "clock_correction_positive_interval"
    t.check_constraint "status IN ('pending', 'approved', 'rejected')", name: "clock_correction_status"
  end

  create_table "clock_shifts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "user_id"
    t.integer "employee_id"
    t.string "employee_key", null: false
    t.string "employee_name", null: false
    t.string "employment_type", null: false
    t.string "request_token", null: false
    t.datetime "started_at", null: false
    t.datetime "ended_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_id"], name: "index_clock_shifts_on_employee_id"
    t.index ["tenant_id", "request_token"], name: "idx_clock_shift_request", unique: true
    t.index ["tenant_id", "started_at", "ended_at"], name: "idx_clock_shift_window"
    t.index ["tenant_id", "user_id"], name: "idx_clock_one_open_shift", unique: true, where: "ended_at IS NULL AND user_id IS NOT NULL"
    t.index ["user_id"], name: "index_clock_shifts_on_user_id"
    t.check_constraint "ended_at IS NULL OR ended_at > started_at", name: "clock_positive_interval"
  end

  create_table "ctrax_days", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "location_id", null: false
    t.string "api_origin", null: false
    t.string "store_id", null: false
    t.date "business_date", null: false
    t.string "timezone", null: false
    t.string "currency", default: "USD", null: false
    t.text "orders_json", null: false
    t.text "sessions_json", null: false
    t.text "controls_json", null: false
    t.string "source_digest", null: false
    t.datetime "captured_at", null: false
    t.integer "reviewed_by_id"
    t.string "reviewed_digest"
    t.datetime "reviewed_at"
    t.string "review_note", limit: 1000
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reviewed_by_id"], name: "index_ctrax_days_on_reviewed_by_id"
    t.index ["tenant_id", "location_id", "business_date"], name: "idx_on_tenant_id_location_id_business_date_9a513d6082", unique: true
    t.index ["tenant_id"], name: "index_ctrax_days_on_tenant_id"
  end

  create_table "ctrax_image_links", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "location_id", null: false
    t.string "variant_id", null: false
    t.string "shopify_product_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "location_id", "variant_id"], name: "idx_on_tenant_id_location_id_variant_id_a6f332d264", unique: true
    t.index ["tenant_id"], name: "index_ctrax_image_links_on_tenant_id"
  end

  create_table "ctrax_labor_observations", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "ctrax_labor_shift_id", null: false
    t.integer "sequence", null: false
    t.datetime "observed_at", null: false
    t.string "digest", null: false
    t.text "payload", null: false
    t.index ["ctrax_labor_shift_id", "sequence"], name: "idx_ctrax_labor_observation_sequence", unique: true
    t.index ["ctrax_labor_shift_id"], name: "index_ctrax_labor_observations_on_ctrax_labor_shift_id"
    t.index ["tenant_id"], name: "index_ctrax_labor_observations_on_tenant_id"
  end

  create_table "ctrax_labor_shifts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "employee_id"
    t.string "source_origin", null: false
    t.string "external_id", null: false
    t.string "store_id"
    t.string "user_external_id", null: false
    t.datetime "started_at"
    t.datetime "ended_at"
    t.decimal "reported_hours", precision: 20, scale: 8
    t.decimal "elapsed_hours", precision: 20, scale: 8
    t.boolean "in_progress", null: false
    t.boolean "verified", null: false
    t.string "status", null: false
    t.string "issue"
    t.datetime "last_seen_at", null: false
    t.datetime "source_updated_at"
    t.string "original_digest", null: false
    t.string "latest_digest", null: false
    t.text "source_payload", null: false
    t.text "latest_payload", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_id"], name: "index_ctrax_labor_shifts_on_employee_id"
    t.index ["tenant_id", "employee_id", "started_at"], name: "idx_ctrax_labor_worker"
    t.index ["tenant_id", "source_origin", "external_id"], name: "idx_ctrax_labor_native", unique: true
    t.index ["tenant_id"], name: "index_ctrax_labor_shifts_on_tenant_id"
  end

  create_table "ctrax_stock_snapshots", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "location_id", null: false
    t.string "api_origin", null: false
    t.string "store_id", null: false
    t.text "records_json", null: false
    t.datetime "captured_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "location_id"], name: "index_ctrax_stock_snapshots_on_tenant_id_and_location_id", unique: true
    t.index ["tenant_id"], name: "index_ctrax_stock_snapshots_on_tenant_id"
  end

  create_table "customer_follow_ups", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "customer_id", null: false
    t.bigint "author_id", null: false
    t.bigint "owner_id"
    t.string "title", null: false
    t.date "due_on", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_customer_follow_ups_on_customer_id"
    t.index ["tenant_id", "completed_at", "due_on"], name: "idx_customer_follow_ups_due"
  end

  create_table "customer_interactions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "customer_id", null: false
    t.bigint "author_id", null: false
    t.string "kind", default: "note", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_customer_interactions_on_customer_id"
    t.index ["tenant_id", "customer_id", "created_at"], name: "idx_customer_interactions_timeline"
  end

  create_table "customer_referrals", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "code", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_customer_referrals_on_code", unique: true
    t.index ["tenant_id"], name: "index_customer_referrals_on_tenant_id", unique: true
  end

  create_table "customer_subscriptions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "stripe_customer_id"
    t.string "stripe_subscription_id"
    t.string "checkout_token"
    t.string "checkout_session_id"
    t.text "checkout_url"
    t.datetime "checkout_expires_at"
    t.string "status", default: "free", null: false
    t.string "plan", default: "free", null: false
    t.string "referral_code"
    t.datetime "commitment_accepted_at"
    t.string "terms_version"
    t.datetime "commitment_ends_at"
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["stripe_subscription_id"], name: "index_customer_subscriptions_on_stripe_subscription_id", unique: true
    t.index ["tenant_id"], name: "index_customer_subscriptions_on_tenant_id", unique: true
  end

  create_table "support_access_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "actor_id", null: false
    t.integer "support_access_grant_id"
    t.string "action", null: false
    t.string "resource"
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "index_support_access_events_on_actor_id"
    t.index ["support_access_grant_id"], name: "index_support_access_events_on_support_access_grant_id"
  end

  create_table "support_access_grants", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "granted_by_id", null: false
    t.integer "support_user_id", null: false
    t.text "reason", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["granted_by_id"], name: "index_support_access_grants_on_granted_by_id"
    t.index ["support_user_id"], name: "index_support_access_grants_on_support_user_id"
    t.index ["tenant_id", "support_user_id"], name: "index_support_access_grants_on_tenant_id_and_support_user_id"
  end

  create_table "customers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "external_id", null: false
    t.string "first_name"
    t.string "last_name"
    t.text "notes"
    t.string "phone"
    t.string "source", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.datetime "source_synced_at"
    t.string "crm_status", default: "customer", null: false
    t.string "tags"
    t.string "preferred_name"
    t.bigint "owner_id"
    t.index ["tenant_id", "created_at", "id"], name: "idx_customers_tenant_created_id"
    t.index ["tenant_id", "crm_status"], name: "index_customers_on_tenant_id_and_crm_status"
    t.index ["tenant_id", "email"], name: "index_customers_on_tenant_id_and_email"
    t.index ["tenant_id", "external_id", "source"], name: "index_customers_on_tenant_id_and_external_id_and_source", unique: true
    t.index ["tenant_id", "owner_id"], name: "index_customers_on_tenant_id_and_owner_id"
    t.index ["tenant_id", "phone"], name: "index_customers_on_tenant_id_and_phone"
  end

  create_table "daily_reconciliation_reviews", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.date "day", null: false
    t.string "report_digest", null: false
    t.string "status", null: false
    t.text "notes", null: false
    t.integer "reviewed_by_id"
    t.datetime "created_at", null: false
    t.index ["reviewed_by_id"], name: "index_daily_reconciliation_reviews_on_reviewed_by_id"
    t.index ["tenant_id", "day"], name: "idx_daily_reconciliation_review_day"
    t.index ["tenant_id"], name: "index_daily_reconciliation_reviews_on_tenant_id"
  end

  create_table "departments", force: :cascade do |t|
    t.string "code"
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "manager_id"
    t.string "name", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_departments_on_tenant_id_and_name", unique: true
  end

  create_table "directory_sync_states", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "provider", null: false
    t.string "kind", null: false
    t.string "status", default: "pending", null: false
    t.string "attempt_token"
    t.integer "record_count"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "last_success_at"
    t.string "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "provider", "kind"], name: "idx_directory_sync_identity", unique: true
  end

  create_table "employee_access_grants", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "user_id", null: false
    t.bigint "employee_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_employee_access_grants_on_token_digest", unique: true
  end

  create_table "employee_app_sessions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "user_id", null: false
    t.bigint "employee_id", null: false
    t.string "token_digest", null: false
    t.string "password_fingerprint", null: false
    t.string "device_name", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "user_id"], name: "index_employee_app_sessions_on_tenant_id_and_user_id"
    t.index ["token_digest"], name: "index_employee_app_sessions_on_token_digest", unique: true
  end

  create_table "employee_source_identities", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "employee_id", null: false
    t.string "source", null: false
    t.string "external_id", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "email"
    t.string "phone"
    t.boolean "source_active"
    t.datetime "source_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_id"], name: "index_employee_source_identities_on_employee_id"
    t.index ["tenant_id", "source", "external_id"], name: "idx_employee_native_identity", unique: true
  end

  create_table "employee_work_reports", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "employee_id", null: false
    t.integer "requester_id"
    t.string "kind", null: false
    t.text "details", null: false
    t.string "status", default: "open", null: false
    t.text "response"
    t.integer "reviewer_id"
    t.datetime "reviewed_at"
    t.string "request_key", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_id"], name: "index_employee_work_reports_on_employee_id"
    t.index ["requester_id"], name: "index_employee_work_reports_on_requester_id"
    t.index ["reviewer_id"], name: "index_employee_work_reports_on_reviewer_id"
    t.index ["tenant_id", "employee_id", "request_key"], name: "idx_employee_work_report_request", unique: true
    t.index ["tenant_id", "status", "created_at"], name: "idx_employee_work_report_queue"
    t.index ["tenant_id"], name: "index_employee_work_reports_on_tenant_id"
  end

  create_table "employees", force: :cascade do |t|
    t.text "address"
    t.datetime "created_at", null: false
    t.date "date_of_birth"
    t.bigint "department_id"
    t.string "email"
    t.string "emergency_contact_name"
    t.string "emergency_contact_phone"
    t.string "employee_number"
    t.string "employment_type", default: "full_time"
    t.string "first_name", null: false
    t.date "hire_date"
    t.string "last_name", null: false
    t.string "legal_name"
    t.text "notes"
    t.string "phone"
    t.bigint "position_id"
    t.string "status", default: "active", null: false
    t.string "tenant_id", null: false
    t.date "termination_date"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "source"
    t.string "external_id"
    t.datetime "source_synced_at"
    t.boolean "source_active"
    t.integer "merged_into_id"
    t.datetime "merged_at"
    t.text "merge_snapshot"
    t.index ["merged_into_id"], name: "index_employees_on_merged_into_id"
    t.index ["tenant_id", "department_id"], name: "index_employees_on_tenant_id_and_department_id"
    t.index ["tenant_id", "employee_number"], name: "index_employees_on_tenant_id_and_employee_number", unique: true
    t.index ["tenant_id", "position_id"], name: "index_employees_on_tenant_id_and_position_id"
    t.index ["tenant_id", "source", "external_id"], name: "idx_employees_source_identity", unique: true
    t.index ["tenant_id", "status"], name: "index_employees_on_tenant_id_and_status"
    t.index ["tenant_id", "user_id"], name: "index_employees_on_tenant_id_and_user_id"
  end

  create_table "expense_categories", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.bigint "ledger_account_id"
    t.text "keywords"
    t.boolean "active", default: true, null: false
    t.boolean "built_in", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "key"], name: "idx_expense_categories_key", unique: true
  end

  create_table "expenses", force: :cascade do |t|
    t.integer "amount_cents", default: 0, null: false
    t.string "category", default: "other", null: false
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.date "incurred_on", null: false
    t.string "method", default: "card"
    t.text "notes"
    t.string "payee"
    t.string "reference"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "vendor_id"
    t.bigint "account_id"
    t.index ["account_id"], name: "idx_expenses_account"
    t.index ["discarded_at"], name: "index_expenses_on_discarded_at"
    t.index ["tenant_id", "category"], name: "index_expenses_on_tenant_id_and_category"
    t.index ["tenant_id", "incurred_on"], name: "index_expenses_on_tenant_id_and_incurred_on"
  end

  create_table "feedback_attachments", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "agent_feedback_id", null: false
    t.string "kind", null: false
    t.string "content_type", default: "text/plain", null: false
    t.text "text_body"
    t.binary "binary_body"
    t.integer "byte_size", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_feedback_id", "kind"], name: "idx_feedback_attachments_kind", unique: true
    t.index ["agent_feedback_id"], name: "index_feedback_attachments_on_agent_feedback_id"
    t.index ["tenant_id"], name: "index_feedback_attachments_on_tenant_id"
  end

  create_table "fulfillments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "fulfilled_at"
    t.bigint "order_id", null: false
    t.string "source", default: "manual", null: false
    t.string "source_fulfillment_id"
    t.string "status", default: "pending", null: false
    t.string "tenant_id", null: false
    t.string "tracking_company"
    t.string "tracking_number"
    t.string "tracking_url"
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_fulfillments_on_order_id"
    t.index ["source", "source_fulfillment_id"], name: "index_fulfillments_on_source_and_source_fulfillment_id", unique: true
    t.index ["tenant_id", "order_id"], name: "index_fulfillments_on_tenant_id_and_order_id"
  end

  create_table "goals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "current_value", precision: 12, scale: 2, default: "0.0"
    t.text "description"
    t.date "due_on"
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.decimal "target_value", precision: 12, scale: 2
    t.string "tenant_id", null: false
    t.string "unit"
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "status"], name: "index_goals_on_tenant_id_and_status"
  end

  create_table "google_login_identities", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "email", null: false
    t.string "google_subject"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_google_login_identities_on_email", unique: true
    t.index ["google_subject"], name: "index_google_login_identities_on_google_subject", unique: true
    t.index ["user_id"], name: "index_google_login_identities_on_user_id"
  end

  create_table "inventory_count_scan_receipts", id: :string, force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "count_id", null: false
    t.string "request_token", null: false
    t.string "fingerprint", null: false
    t.string "created_by", null: false
    t.text "result", null: false
    t.datetime "created_at", null: false
    t.index ["tenant_id", "count_id", "request_token"], name: "idx_count_scan_receipts_request", unique: true
  end

  create_table "iris_reports", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "api_origin", null: false
    t.string "merchant_number", null: false
    t.string "report_kind", null: false
    t.date "window_from", null: false
    t.date "window_to", null: false
    t.string "status", null: false
    t.text "payload_json", null: false
    t.string "source_digest"
    t.datetime "observed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "api_origin", "merchant_number", "report_kind", "window_from", "window_to"], name: "idx_iris_report_window", unique: true
    t.index ["tenant_id"], name: "index_iris_reports_on_tenant_id"
  end

  create_table "journal_entries", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.date "posted_on", null: false
    t.string "kind", null: false
    t.string "status", default: "posted", null: false
    t.string "source_type"
    t.string "source_id"
    t.text "memo"
    t.integer "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "posted_on"], name: "idx_journal_entries_posted_on"
    t.index ["tenant_id", "source_type", "source_id"], name: "idx_journal_entries_source", unique: true, where: "status = 'posted'"
    t.index ["tenant_id"], name: "index_journal_entries_on_tenant_id"
  end

  create_table "journal_lines", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "journal_entry_id", null: false
    t.bigint "account_id", null: false
    t.bigint "debit_cents", default: 0, null: false
    t.bigint "credit_cents", default: 0, null: false
    t.text "memo"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["journal_entry_id"], name: "idx_journal_lines_entry"
    t.index ["tenant_id", "account_id"], name: "idx_journal_lines_account"
    t.index ["tenant_id"], name: "index_journal_lines_on_tenant_id"
    t.check_constraint "(debit_cents >= 0 AND credit_cents >= 0) AND ((debit_cents = 0) <> (credit_cents = 0))", name: "chk_journal_lines_one_sided"
  end

  create_table "kpi_readings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kpi_id", null: false
    t.datetime "measured_at", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 12, scale: 2, null: false
    t.index ["tenant_id", "kpi_id", "measured_at"], name: "index_kpi_readings_on_tenant_id_and_kpi_id_and_measured_at"
  end

  create_table "kpis", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "direction", default: "up", null: false
    t.string "name", null: false
    t.decimal "target_value", precision: 12, scale: 2
    t.string "tenant_id", null: false
    t.string "unit"
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_kpis_on_tenant_id_and_name"
  end

  create_table "leave_balances", force: :cascade do |t|
    t.decimal "accrued_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.string "leave_type", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "used_hours", precision: 6, scale: 2, default: "0.0", null: false
    t.integer "year", null: false
    t.index ["tenant_id", "employee_id", "leave_type", "year"], name: "idx_on_tenant_id_employee_id_leave_type_year_960082e46c", unique: true
  end

  create_table "leave_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.date "ends_on", null: false
    t.decimal "hours", precision: 6, scale: 2
    t.string "leave_type", null: false
    t.text "reason"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by"
    t.date "starts_on", null: false
    t.string "status", default: "requested", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "employee_id", "status"], name: "index_leave_requests_on_tenant_id_and_employee_id_and_status"
    t.index ["tenant_id", "status"], name: "index_leave_requests_on_tenant_id_and_status"
  end

  create_table "marketing_campaigns", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "name", null: false
    t.string "storefront_url", null: false
    t.text "topics", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_marketing_campaigns_on_tenant_id"
  end

  create_table "marketing_cms_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "actor_id", null: false
    t.string "subject_type", null: false
    t.bigint "subject_id", null: false
    t.string "action", null: false
    t.text "payload_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "subject_type", "subject_id"], name: "marketing_cms_history"
    t.index ["tenant_id"], name: "index_marketing_cms_events_on_tenant_id"
  end

  create_table "marketing_communities", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "campaign_id", null: false
    t.string "name", null: false
    t.string "url", null: false
    t.text "include_terms", null: false
    t.text "exclude_terms"
    t.text "promotion_rules", null: false
    t.string "rules_url", null: false
    t.datetime "rules_checked_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["campaign_id"], name: "index_marketing_communities_on_campaign_id"
    t.index ["tenant_id"], name: "index_marketing_communities_on_tenant_id"
  end

  create_table "marketing_document_revisions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "document_id", null: false
    t.bigint "actor_id", null: false
    t.integer "number", null: false
    t.string "title", null: false
    t.string "kind", null: false
    t.text "body", null: false
    t.text "source_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["document_id", "number"], name: "index_marketing_document_revisions_on_document_id_and_number", unique: true
    t.index ["document_id"], name: "index_marketing_document_revisions_on_document_id"
    t.index ["tenant_id"], name: "index_marketing_document_revisions_on_tenant_id"
  end

  create_table "marketing_documents", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "engagement_id", null: false
    t.string "title", null: false
    t.string "kind", null: false
    t.string "visibility", default: "internal", null: false
    t.string "status", default: "draft", null: false
    t.bigint "reviewed_by_id"
    t.datetime "reviewed_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["engagement_id"], name: "index_marketing_documents_on_engagement_id"
    t.index ["tenant_id"], name: "index_marketing_documents_on_tenant_id"
  end

  create_table "marketing_engagements", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "influencer_id", null: false
    t.integer "campaign_id", null: false
    t.string "title", null: false
    t.string "status", default: "draft", null: false
    t.text "deliverables"
    t.datetime "due_at"
    t.string "destination_url", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["campaign_id"], name: "index_marketing_engagements_on_campaign_id"
    t.index ["influencer_id"], name: "index_marketing_engagements_on_influencer_id"
    t.index ["tenant_id"], name: "index_marketing_engagements_on_tenant_id"
  end

  create_table "marketing_influencers", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "name", null: false
    t.string "platform"
    t.string "handle"
    t.string "profile_url"
    t.text "topics"
    t.string "stage", default: "prospect", null: false
    t.bigint "owner_id"
    t.datetime "next_follow_up_at"
    t.text "notes"
    t.text "contact_email"
    t.text "shipping_details"
    t.text "private_notes"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "profile_url"], name: "index_marketing_influencers_on_tenant_id_and_profile_url", unique: true
    t.index ["tenant_id", "stage", "next_follow_up_at"], name: "marketing_influencer_queue"
    t.index ["tenant_id"], name: "index_marketing_influencers_on_tenant_id"
  end

  create_table "marketing_interactions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "influencer_id", null: false
    t.bigint "actor_id", null: false
    t.string "kind", null: false
    t.text "body", null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["influencer_id"], name: "index_marketing_interactions_on_influencer_id"
    t.index ["tenant_id"], name: "index_marketing_interactions_on_tenant_id"
  end

  create_table "marketing_offers", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "community_id"
    t.string "merchant_host", null: false
    t.string "code", null: false
    t.text "terms", null: false
    t.string "destination_url", null: false
    t.datetime "starts_at", null: false
    t.datetime "ends_at", null: false
    t.string "evidence_url"
    t.datetime "verified_at"
    t.bigint "verified_by_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "engagement_id"
    t.index ["community_id"], name: "index_marketing_offers_on_community_id"
    t.index ["engagement_id"], name: "index_marketing_offers_on_engagement_id"
    t.index ["tenant_id", "merchant_host", "code"], name: "marketing_offer_codes", unique: true
    t.index ["tenant_id"], name: "index_marketing_offers_on_tenant_id"
    t.check_constraint "(community_id IS NOT NULL AND engagement_id IS NULL) OR (community_id IS NULL AND engagement_id IS NOT NULL)", name: "marketing_offer_recipient"
  end

  create_table "marketing_product_gift_items", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "product_gift_id", null: false
    t.string "source_variant_id", null: false
    t.string "product_name", null: false
    t.string "sku"
    t.integer "quantity", null: false
    t.integer "unit_cost_cents"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_gift_id", "source_variant_id"], name: "marketing_gift_variant", unique: true
    t.index ["product_gift_id"], name: "index_marketing_product_gift_items_on_product_gift_id"
    t.index ["tenant_id"], name: "index_marketing_product_gift_items_on_tenant_id"
  end

  create_table "marketing_product_gifts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "engagement_id", null: false
    t.string "status", default: "proposed", null: false
    t.string "currency", default: "USD", null: false
    t.integer "shipping_cost_cents"
    t.text "note"
    t.text "shipping_details"
    t.datetime "recipient_confirmed_at"
    t.string "carrier"
    t.text "tracking_number"
    t.text "tracking_url"
    t.datetime "shipped_at"
    t.datetime "delivered_at"
    t.datetime "returned_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["engagement_id"], name: "index_marketing_product_gifts_on_engagement_id"
    t.index ["tenant_id"], name: "index_marketing_product_gifts_on_tenant_id"
  end

  create_table "marketing_replies", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "thread_id", null: false
    t.integer "offer_id", null: false
    t.text "body", null: false
    t.string "affiliation", null: false
    t.string "status", default: "draft", null: false
    t.text "snapshot_json"
    t.string "snapshot_digest"
    t.string "published_url"
    t.datetime "published_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["offer_id"], name: "index_marketing_replies_on_offer_id"
    t.index ["tenant_id", "status", "updated_at"], name: "index_marketing_replies_on_tenant_id_and_status_and_updated_at"
    t.index ["tenant_id"], name: "index_marketing_replies_on_tenant_id"
    t.index ["thread_id"], name: "index_marketing_replies_on_thread_id", unique: true
  end

  create_table "marketing_review_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "reply_id", null: false
    t.bigint "actor_id", null: false
    t.string "action", null: false
    t.text "payload_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reply_id"], name: "index_marketing_review_events_on_reply_id"
    t.index ["tenant_id"], name: "index_marketing_review_events_on_tenant_id"
  end

  create_table "marketing_shopify_discounts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "offer_id", null: false
    t.string "shop_domain", null: false
    t.string "shop_id", null: false
    t.string "currency", null: false
    t.string "request_key", null: false
    t.text "request_json", null: false
    t.string "status", default: "draft", null: false
    t.string "remote_id"
    t.string "remote_status"
    t.text "remote_json"
    t.text "last_error"
    t.bigint "approved_by_id"
    t.datetime "attempted_at"
    t.datetime "checked_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["offer_id"], name: "index_marketing_shopify_discounts_on_offer_id", unique: true
    t.index ["request_key"], name: "index_marketing_shopify_discounts_on_request_key", unique: true
    t.index ["tenant_id", "shop_domain", "remote_id"], name: "marketing_shopify_remote_discount", unique: true
    t.index ["tenant_id"], name: "index_marketing_shopify_discounts_on_tenant_id"
    t.check_constraint "status IN ('draft', 'creating', 'created', 'uncertain', 'failed', 'blocked')", name: "marketing_shopify_discount_status"
  end

  create_table "marketing_threads", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "community_id", null: false
    t.string "url", null: false
    t.string "title", null: false
    t.text "excerpt", null: false
    t.string "status", default: "new", null: false
    t.string "availability", default: "open", null: false
    t.text "triage_note"
    t.datetime "checked_at"
    t.datetime "snoozed_until"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["community_id"], name: "index_marketing_threads_on_community_id"
    t.index ["tenant_id", "status", "created_at"], name: "index_marketing_threads_on_tenant_id_and_status_and_created_at"
    t.index ["tenant_id", "url"], name: "index_marketing_threads_on_tenant_id_and_url", unique: true
    t.index ["tenant_id"], name: "index_marketing_threads_on_tenant_id"
  end

  create_table "money_reconciliations", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "period_kind", null: false
    t.date "period_from", null: false
    t.date "period_to", null: false
    t.datetime "generated_at", null: false
    t.text "payload_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "period_kind", "period_from"], name: "idx_money_reconciliation_period", unique: true
  end

  create_table "oauth_allowed_domains", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.string "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "domain"], name: "index_oauth_allowed_domains_on_tenant_id_and_domain", unique: true
  end

  create_table "order_lines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "line_cents", default: 0
    t.string "name"
    t.bigint "order_id"
    t.integer "quantity", default: 0
    t.string "sku"
    t.string "tenant_id", null: false
    t.integer "unit_cents", default: 0
    t.datetime "updated_at", null: false
    t.string "source_line_id"
    t.string "source_variant_id"
    t.index ["tenant_id", "order_id", "source_line_id"], name: "idx_order_lines_source_identity", unique: true
    t.index ["tenant_id", "order_id"], name: "index_order_lines_on_tenant_id_and_order_id"
    t.index ["tenant_id", "sku"], name: "idx_order_lines_tenant_sku_sqlite"
    t.index ["tenant_id", "sku"], name: "index_order_lines_on_tenant_id_and_sku"
    t.index ["tenant_id", "source_variant_id"], name: "idx_order_lines_source_variant"
  end

  create_table "orders", force: :cascade do |t|
    t.string "channel"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.bigint "customer_id"
    t.string "fulfillment_status", default: "pending", null: false
    t.integer "gross_cents", default: 0
    t.integer "line_items", default: 0
    t.string "location_id"
    t.datetime "occurred_at", null: false
    t.string "order_number"
    t.string "shipping_address1"
    t.string "shipping_address2"
    t.string "shipping_city"
    t.string "shipping_country"
    t.string "shipping_name"
    t.string "shipping_phone"
    t.string "shipping_province"
    t.string "shipping_zip"
    t.string "source", null: false
    t.string "source_order_id", null: false
    t.string "status", null: false
    t.integer "tax_cents", default: 0
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.boolean "source_lines_complete", default: false, null: false
    t.string "source_financial_status"
    t.integer "tip_cents", default: 0, null: false
    t.index ["location_id"], name: "index_orders_on_location_id"
    t.index ["tenant_id", "customer_id"], name: "index_orders_on_tenant_id_and_customer_id"
    t.index ["tenant_id", "occurred_at"], name: "index_orders_on_tenant_id_and_occurred_at"
    t.index ["tenant_id", "order_number"], name: "index_orders_on_tenant_id_and_order_number"
    t.index ["tenant_id", "source", "source_order_id"], name: "index_orders_on_tenant_id_and_source_and_source_order_id", unique: true
    t.index ["tenant_id", "status"], name: "index_orders_on_tenant_id_and_status"
  end

  create_table "owner_checklist_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "owner_checklist_id", null: false
    t.integer "actor_id"
    t.text "payload_json", null: false
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.index ["tenant_id", "owner_checklist_id", "created_at", "id"], name: "idx_owner_checklist_events_timeline"
  end

  create_table "owner_checklists", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.text "payload_json", null: false
    t.integer "lock_version", default: 0, null: false
    t.integer "created_by_id"
    t.integer "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "created_at", "id"], name: "idx_owner_checklists_timeline"
  end

  create_table "pay_rates", force: :cascade do |t|
    t.integer "annual_salary_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.date "effective_on", null: false
    t.bigint "employee_id", null: false
    t.date "ended_on"
    t.integer "hourly_rate_cents", default: 0, null: false
    t.string "pay_frequency", default: "biweekly", null: false
    t.string "pay_type", default: "hourly", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "effective_on"], name: "index_pay_rates_on_tenant_id_and_effective_on"
    t.index ["tenant_id", "employee_id"], name: "index_pay_rates_on_tenant_id_and_employee_id"
  end

  create_table "pay_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "notes"
    t.date "paid_on"
    t.date "period_end", null: false
    t.date "period_start", null: false
    t.string "status", default: "draft", null: false
    t.string "tenant_id", null: false
    t.integer "total_gross_cents", default: 0, null: false
    t.integer "total_net_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "period_start"], name: "index_pay_runs_on_tenant_id_and_period_start"
    t.index ["tenant_id", "status"], name: "index_pay_runs_on_tenant_id_and_status"
  end

  create_table "payments", force: :cascade do |t|
    t.integer "amount_cents", default: 0
    t.datetime "created_at", null: false
    t.string "method", null: false
    t.bigint "order_id"
    t.datetime "paid_at", null: false
    t.string "reference"
    t.string "status", default: "completed"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "order_id"], name: "index_payments_on_tenant_id_and_order_id"
    t.index ["tenant_id", "paid_at"], name: "index_payments_on_tenant_id_and_paid_at"
  end

  create_table "payslips", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "deductions_cents", default: 0, null: false
    t.bigint "employee_id", null: false
    t.integer "gross_cents", default: 0, null: false
    t.decimal "hours", precision: 6, scale: 2, default: "0.0", null: false
    t.integer "net_cents", default: 0, null: false
    t.text "notes"
    t.bigint "pay_rate_id"
    t.bigint "pay_run_id", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "employee_id"], name: "index_payslips_on_tenant_id_and_employee_id"
    t.index ["tenant_id", "pay_run_id"], name: "index_payslips_on_tenant_id_and_pay_run_id"
  end

  create_table "period_locks", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "action", null: false
    t.string "period_kind", null: false
    t.date "period_from", null: false
    t.date "period_to", null: false
    t.string "fingerprint", null: false
    t.text "summary_json", null: false
    t.text "reason"
    t.integer "archive_document_id"
    t.integer "actor_id"
    t.string "actor_name", null: false
    t.datetime "acted_at", null: false
    t.string "ip"
    t.string "user_agent"
    t.string "prev_hash", null: false
    t.string "entry_hash", null: false
    t.datetime "created_at", null: false
    t.index ["entry_hash"], name: "idx_period_locks_entry_hash", unique: true
    t.index ["tenant_id", "period_from", "period_to"], name: "idx_period_locks_range"
    t.index ["tenant_id", "period_kind", "period_from"], name: "idx_period_locks_period"
    t.index ["tenant_id"], name: "index_period_locks_on_tenant_id"
  end

  create_table "pos_checkouts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "location_id", null: false
    t.integer "user_id", null: false
    t.integer "pos_display_session_id", null: false
    t.integer "pos_session_id"
    t.integer "cart_revision", null: false
    t.string "reference", null: false
    t.string "status", default: "ready", null: false
    t.string "tender", null: false
    t.boolean "demo", default: false, null: false
    t.text "lines_json", null: false
    t.integer "subtotal_cents", null: false
    t.integer "tax_cents", null: false
    t.integer "tip_cents", null: false
    t.integer "total_cents", null: false
    t.integer "cash_received_cents"
    t.integer "change_cents"
    t.integer "order_id"
    t.datetime "paid_at"
    t.string "gateway_id"
    t.string "environment"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "gateway_provider", default: "authorize_net", null: false
    t.string "gateway_fingerprint"
    t.index ["order_id"], name: "index_pos_checkouts_on_order_id"
    t.index ["pos_display_session_id"], name: "index_pos_checkouts_on_pos_display_session_id"
    t.index ["pos_session_id"], name: "index_pos_checkouts_on_pos_session_id"
    t.index ["reference"], name: "index_pos_checkouts_on_reference", unique: true
    t.index ["tenant_id", "pos_display_session_id", "cart_revision"], name: "idx_pos_checkout_revision", unique: true
    t.index ["user_id"], name: "index_pos_checkouts_on_user_id"
  end

  create_table "pos_connections", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "provider", null: false
    t.string "environment", default: "sandbox", null: false
    t.string "account_reference"
    t.string "gateway", default: "unconfirmed", null: false
    t.boolean "access_requested", default: false, null: false
    t.boolean "vendor_approved", default: false, null: false
    t.text "credentials_json"
    t.string "last_check_status"
    t.string "last_check_message"
    t.datetime "last_checked_at"
    t.integer "updated_by_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "hourly_sync_enabled", default: false, null: false
    t.string "reporting_auth_mode", default: "api_key", null: false
    t.boolean "reporting_enabled", default: false, null: false
    t.datetime "last_reported_at"
    t.string "last_report_status"
    t.string "last_report_message"
    t.index ["tenant_id", "provider"], name: "index_pos_connections_on_tenant_id_and_provider", unique: true
    t.index ["updated_by_id"], name: "index_pos_connections_on_updated_by_id"
    t.check_constraint "environment IN ('sandbox', 'production')", name: "pos_connection_environment"
    t.check_constraint "last_check_status IS NULL OR last_check_status IN ('verified', 'failed')", name: "pos_connection_check_status"
  end

  create_table "pos_display_sessions", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "user_id", null: false
    t.string "location_id", null: false
    t.text "display_token", null: false
    t.string "token_digest", null: false
    t.text "draft_json", default: "{}", null: false
    t.string "draft_digest"
    t.integer "cart_revision", default: 0, null: false
    t.integer "confirmed_revision"
    t.integer "chosen_tip_cents"
    t.boolean "demo", default: false, null: false
    t.datetime "expires_at", null: false
    t.datetime "closed_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_pos_display_sessions_on_tenant_id"
    t.index ["token_digest"], name: "index_pos_display_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_pos_display_sessions_on_user_id"
  end

  create_table "pos_payment_attempts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "pos_checkout_id", null: false
    t.string "invoice", null: false
    t.string "nonce_digest", null: false
    t.string "status", default: "submitting", null: false
    t.string "transaction_id"
    t.datetime "submitted_at", null: false
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice"], name: "index_pos_payment_attempts_on_invoice", unique: true
    t.index ["pos_checkout_id"], name: "index_pos_payment_attempts_on_pos_checkout_id"
    t.index ["tenant_id", "nonce_digest"], name: "index_pos_payment_attempts_on_tenant_id_and_nonce_digest", unique: true
  end

  create_table "pos_sessions", force: :cascade do |t|
    t.integer "card_sales_cents", default: 0
    t.integer "cash_sales_cents", default: 0
    t.datetime "closed_at"
    t.integer "counted_cash_cents"
    t.datetime "created_at", null: false
    t.integer "expected_cash_cents"
    t.integer "gift_sales_cents", default: 0
    t.string "location_id"
    t.string "name", null: false
    t.text "notes"
    t.datetime "opened_at", null: false
    t.integer "opening_cash_cents", default: 0
    t.string "status", default: "open", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.integer "variance_cents"
    t.index ["tenant_id", "opened_at"], name: "index_pos_sessions_on_tenant_id_and_opened_at"
    t.index ["tenant_id", "status"], name: "index_pos_sessions_on_tenant_id_and_status"
  end

  create_table "pos_settings", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "location_id", null: false
    t.boolean "cash_enabled", default: false, null: false
    t.boolean "stock_writes_enabled", default: false, null: false
    t.boolean "card_enabled", default: false, null: false
    t.string "environment", default: "sandbox", null: false
    t.string "gateway_id"
    t.text "credentials_json", default: "{}", null: false
    t.string "public_client_key"
    t.datetime "verified_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "gateway_provider", default: "authorize_net", null: false
    t.index ["tenant_id", "location_id"], name: "index_pos_settings_on_tenant_id_and_location_id", unique: true
  end

  create_table "pos_stock_allocations", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "location_id", null: false
    t.integer "pos_checkout_id", null: false
    t.string "variant_id", null: false
    t.integer "quantity", null: false
    t.string "status", default: "held", null: false
    t.string "source_adjustment_id"
    t.datetime "submitted_at"
    t.datetime "applied_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "source_quantity_before"
    t.index ["pos_checkout_id", "variant_id"], name: "index_pos_stock_allocations_on_pos_checkout_id_and_variant_id", unique: true
    t.index ["pos_checkout_id"], name: "index_pos_stock_allocations_on_pos_checkout_id"
    t.index ["tenant_id", "location_id", "variant_id"], name: "idx_pos_stock_pool"
  end

  create_table "positions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "department_id"
    t.text "description"
    t.string "name", null: false
    t.string "pay_grade"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "department_id"], name: "index_positions_on_tenant_id_and_department_id"
    t.index ["tenant_id", "name"], name: "index_positions_on_tenant_id_and_name"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.date "due_on"
    t.string "name", null: false
    t.string "owner_id"
    t.string "status", default: "planned", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "owner_id"], name: "index_projects_on_tenant_id_and_owner_id"
    t.index ["tenant_id", "status"], name: "index_projects_on_tenant_id_and_status"
  end

  create_table "purchase_order_lines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "purchase_order_id", null: false
    t.integer "quantity", default: 1, null: false
    t.integer "received_quantity", default: 0, null: false
    t.string "sku"
    t.string "tenant_id", null: false
    t.integer "unit_cost_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "purchase_order_id"], name: "index_purchase_order_lines_on_tenant_id_and_purchase_order_id"
    t.index ["tenant_id", "sku"], name: "index_purchase_order_lines_on_tenant_id_and_sku"
  end

  create_table "purchase_deliveries", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "purchase_order_id", null: false
    t.string "request_token", null: false
    t.string "payload_digest", null: false
    t.string "actor", null: false
    t.text "quantities_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["purchase_order_id"], name: "index_purchase_deliveries_on_purchase_order_id"
    t.index ["tenant_id", "request_token"], name: "index_purchase_deliveries_on_tenant_id_and_request_token", unique: true
  end

  create_table "purchase_orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "expected_date"
    t.text "notes"
    t.string "order_number", null: false
    t.date "received_date"
    t.string "status", default: "draft", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "vendor_id", null: false
    t.index ["tenant_id", "order_number"], name: "index_purchase_orders_on_tenant_id_and_order_number", unique: true
    t.index ["tenant_id", "status"], name: "index_purchase_orders_on_tenant_id_and_status"
    t.index ["tenant_id", "vendor_id"], name: "index_purchase_orders_on_tenant_id_and_vendor_id"
  end

  create_table "purchase_receipt_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "purchase_receipt_id", null: false
    t.integer "actor_id", null: false
    t.string "action", null: false
    t.text "snapshot_json", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_purchase_receipt_events_on_actor_id"
    t.index ["purchase_receipt_id"], name: "index_purchase_receipt_events_on_purchase_receipt_id"
  end

  create_table "purchase_receipts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "submitted_by_id", null: false
    t.string "status", default: "draft", null: false
    t.string "payee", null: false
    t.date "incurred_on", null: false
    t.integer "amount_cents", null: false
    t.string "currency", default: "USD", null: false
    t.string "category", null: false
    t.text "notes"
    t.string "filename", null: false
    t.string "content_type", null: false
    t.integer "byte_size", null: false
    t.string "sha256", null: false
    t.text "content_base64", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["submitted_by_id"], name: "index_purchase_receipts_on_submitted_by_id"
    t.index ["tenant_id", "status", "created_at"], name: "index_purchase_receipts_on_tenant_id_and_status_and_created_at"
    t.index ["tenant_id", "submitted_by_id", "sha256"], name: "idx_purchase_receipts_duplicate_file", unique: true
  end

  create_table "reconciliation_documents", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "source", null: false
    t.string "kind", null: false
    t.date "period_from", null: false
    t.date "period_to", null: false
    t.text "metadata_json", null: false
    t.text "content_base64", null: false
    t.string "filename", null: false
    t.string "content_type", null: false
    t.string "sha256", null: false
    t.string "fingerprint", null: false
    t.integer "byte_size", null: false
    t.integer "uploaded_by_id"
    t.bigint "supersedes_id"
    t.datetime "created_at", null: false
    t.index ["tenant_id", "fingerprint"], name: "idx_reconciliation_evidence_replay", unique: true
    t.index ["tenant_id", "period_from", "period_to"], name: "idx_reconciliation_evidence_period"
    t.index ["tenant_id", "supersedes_id"], name: "idx_reconciliation_evidence_correction", unique: true
    t.index ["tenant_id"], name: "index_reconciliation_documents_on_tenant_id"
    t.index ["uploaded_by_id"], name: "index_reconciliation_documents_on_uploaded_by_id"
  end

  create_table "reconciliation_follow_up_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "reconciliation_follow_up_id", null: false
    t.text "details_json", null: false
    t.datetime "created_at", null: false
    t.index ["reconciliation_follow_up_id"], name: "idx_reconciliation_follow_up_history"
    t.index ["tenant_id"], name: "index_reconciliation_follow_up_events_on_tenant_id"
  end

  create_table "reconciliation_follow_ups", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "category", null: false
    t.string "source", null: false
    t.string "document_kind", null: false
    t.date "period_from", null: false
    t.date "period_to", null: false
    t.string "currency"
    t.string "location_id"
    t.string "metric"
    t.string "report_digest"
    t.text "title", null: false
    t.text "notes", null: false
    t.string "status", default: "open", null: false
    t.date "due_on", null: false
    t.integer "owner_id"
    t.integer "created_by_id"
    t.integer "document_id"
    t.string "submission_key", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_reconciliation_follow_ups_on_created_by_id"
    t.index ["document_id"], name: "index_reconciliation_follow_ups_on_document_id"
    t.index ["owner_id"], name: "index_reconciliation_follow_ups_on_owner_id"
    t.index ["tenant_id", "period_from", "period_to"], name: "idx_reconciliation_follow_up_period"
    t.index ["tenant_id", "status", "due_on"], name: "idx_reconciliation_follow_up_queue"
    t.index ["tenant_id", "submission_key"], name: "idx_reconciliation_follow_up_submission", unique: true
    t.index ["tenant_id"], name: "index_reconciliation_follow_ups_on_tenant_id"
  end

  create_table "refunds", force: :cascade do |t|
    t.integer "amount_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.string "method", default: "card", null: false
    t.bigint "order_id", null: false
    t.string "reason"
    t.string "reference"
    t.datetime "refunded_at", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["discarded_at"], name: "index_refunds_on_discarded_at"
    t.index ["tenant_id", "order_id"], name: "index_refunds_on_tenant_id_and_order_id"
    t.index ["tenant_id", "refunded_at"], name: "index_refunds_on_tenant_id_and_refunded_at"
  end

  create_table "retention_drive_connections", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.text "refresh_token"
    t.text "account_email"
    t.string "generation"
    t.boolean "enabled", default: false, null: false
    t.string "sync_lease_token"
    t.datetime "sync_lease_at"
    t.datetime "last_synced_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_retention_drive_connections_on_tenant_id", unique: true
  end

  create_table "retention_drive_items", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "generation", null: false
    t.string "item_key", null: false
    t.string "remote_id"
    t.string "status", default: "pending", null: false
    t.string "sha256"
    t.bigint "byte_size"
    t.text "display_name"
    t.text "folder_path"
    t.text "last_error"
    t.datetime "last_attempt_at"
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "generation", "item_key"], name: "index_retention_drive_items_identity", unique: true
    t.index ["tenant_id", "generation", "status"], name: "index_retention_drive_items_status"
  end

  create_table "role_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "permission", null: false
    t.string "role", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "role", "permission"], name: "index_role_permissions_on_tenant_id_and_role_and_permission", unique: true
    t.index ["tenant_id", "role"], name: "index_role_permissions_on_tenant_id_and_role"
  end

  create_table "scheduled_shifts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "employee_id", null: false
    t.datetime "starts_at", null: false
    t.datetime "ends_at", null: false
    t.string "role_label"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_id", "starts_at"], name: "idx_scheduled_shift_employee"
    t.index ["employee_id"], name: "index_scheduled_shifts_on_employee_id"
    t.index ["tenant_id", "starts_at"], name: "idx_scheduled_shift_window"
    t.check_constraint "ends_at > starts_at", name: "scheduled_shift_positive_interval"
  end

  create_table "settings", force: :cascade do |t|
    t.string "key", null: false
    t.string "tenant_id"
    t.datetime "updated_at"
    t.string "value"
    t.index ["key", "tenant_id"], name: "index_settings_on_key_and_tenant_id", unique: true
  end

  create_table "shopify_stock_snapshots", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "location_id", null: false
    t.string "shop_domain", null: false
    t.datetime "captured_at", null: false
    t.text "records_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "location_id"], name: "index_shopify_stock_snapshots_on_tenant_id_and_location_id", unique: true
    t.index ["tenant_id"], name: "index_shopify_stock_snapshots_on_tenant_id"
  end

  create_table "shops", force: :cascade do |t|
    t.string "access_scopes"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "refresh_token"
    t.datetime "refresh_token_expires_at"
    t.string "shopify_domain", null: false
    t.string "shopify_token", null: false
    t.datetime "updated_at", null: false
    t.index ["shopify_domain"], name: "index_shops_on_shopify_domain", unique: true
  end

  create_table "size_changes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error"
    t.bigint "family_id", null: false
    t.decimal "grams", precision: 12, scale: 3
    t.string "mode"
    t.decimal "root_grams", precision: 12, scale: 3
    t.string "sku", null: false
    t.string "square_variation_id"
    t.string "status", default: "pending", null: false
    t.integer "target_quantity"
    t.string "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["family_id", "sku"], name: "index_size_changes_on_family_id_and_sku", unique: true
    t.index ["family_id"], name: "index_size_changes_on_family_id"
    t.index ["tenant_id", "status"], name: "index_size_changes_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_size_changes_on_tenant_id"
  end

  create_table "size_families", force: :cascade do |t|
    t.decimal "base_grams", precision: 12, scale: 3
    t.datetime "created_at", null: false
    t.string "mode", default: "approval", null: false
    t.string "name", null: false
    t.string "root_sku"
    t.datetime "sales_watermark"
    t.string "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_size_families_on_tenant_id"
  end

  create_table "size_family_members", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "family_id", null: false
    t.decimal "grams", precision: 12, scale: 3, null: false
    t.string "shopify_variant_id"
    t.string "sku", null: false
    t.string "square_variation_id"
    t.string "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["family_id", "sku"], name: "index_size_family_members_on_family_id_and_sku", unique: true
    t.index ["family_id"], name: "index_size_family_members_on_family_id"
    t.index ["tenant_id"], name: "index_size_family_members_on_tenant_id"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "square_timecard_days", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "square_timecard_id", null: false
    t.date "worked_on", null: false
    t.integer "payable_seconds", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["square_timecard_id"], name: "index_square_timecard_days_on_square_timecard_id"
    t.index ["tenant_id", "square_timecard_id", "worked_on"], name: "idx_square_timecard_day", unique: true
    t.index ["tenant_id", "worked_on"], name: "index_square_timecard_days_on_tenant_id_and_worked_on"
    t.index ["tenant_id"], name: "index_square_timecard_days_on_tenant_id"
  end

  create_table "square_timecards", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "employee_id"
    t.string "external_id", null: false
    t.string "team_member_id"
    t.string "location_id"
    t.string "timezone"
    t.datetime "started_at"
    t.datetime "ended_at"
    t.bigint "payable_seconds", default: 0, null: false
    t.bigint "unpaid_break_seconds", default: 0, null: false
    t.integer "hourly_rate_cents"
    t.string "currency"
    t.string "import_status", null: false
    t.string "issue"
    t.integer "source_version"
    t.datetime "source_updated_at"
    t.string "original_digest"
    t.text "source_payload"
    t.text "latest_payload"
    t.datetime "imported_at"
    t.datetime "last_seen_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["employee_id"], name: "index_square_timecards_on_employee_id"
    t.index ["tenant_id", "employee_id", "started_at"], name: "idx_square_timecard_worker"
    t.index ["tenant_id", "external_id"], name: "idx_square_timecard_native", unique: true
    t.index ["tenant_id"], name: "index_square_timecards_on_tenant_id"
  end

  create_table "stock_request_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "stock_request_id", null: false
    t.string "action", null: false
    t.string "request_token", null: false
    t.string "payload_digest", null: false
    t.string "actor", null: false
    t.integer "quantity", default: 0, null: false
    t.text "reference"
    t.datetime "source_adjusted_at"
    t.datetime "source_refreshed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["stock_request_id"], name: "index_stock_request_events_on_stock_request_id"
    t.index ["tenant_id", "request_token"], name: "index_stock_request_events_on_tenant_id_and_request_token", unique: true
  end

  create_table "stock_requests", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "request_kind", null: false
    t.integer "source_pool_id", null: false
    t.integer "destination_pool_id"
    t.integer "stock_reservation_id"
    t.integer "quantity", null: false
    t.integer "received_quantity", default: 0, null: false
    t.string "reference", null: false
    t.date "due_on"
    t.string "status", default: "pending", null: false
    t.string "created_by", null: false
    t.string "source_location_external_id", null: false
    t.string "destination_location_external_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["destination_pool_id"], name: "index_stock_requests_on_destination_pool_id"
    t.index ["source_pool_id"], name: "index_stock_requests_on_source_pool_id"
    t.index ["stock_reservation_id"], name: "index_stock_requests_on_stock_reservation_id", unique: true
    t.index ["tenant_id", "request_kind", "status", "id"], name: "idx_stock_requests_queue"
    t.check_constraint "(request_kind = 'transfer' AND destination_pool_id IS NOT NULL AND source_pool_id <> destination_pool_id) OR (request_kind = 'backorder' AND destination_pool_id IS NULL)", name: "stock_requests_destination"
    t.check_constraint "quantity > 0 AND received_quantity >= 0 AND received_quantity <= quantity", name: "stock_requests_quantities"
    t.check_constraint "request_kind IN ('transfer', 'backorder')", name: "stock_requests_kind"
    t.check_constraint "status IN ('pending', 'allocated', 'dispatched', 'completed', 'cancelled')", name: "stock_requests_status"
  end

  create_table "stock_reservation_pools", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "source", null: false
    t.string "location_id", null: false
    t.string "source_item_id", null: false
    t.string "location_name", null: false
    t.string "item_label", null: false
    t.integer "lock_version", default: 0, null: false
    t.index ["tenant_id", "source", "location_id", "source_item_id"], name: "idx_reservation_pool_identity", unique: true
    t.check_constraint "source IN ('shopify', 'square')", name: "stock_reservation_pools_source"
  end

  create_table "stock_reservations", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "stock_reservation_pool_id", null: false
    t.integer "quantity", null: false
    t.string "reference", null: false
    t.string "request_token", null: false
    t.string "status", default: "active", null: false
    t.datetime "expires_at"
    t.string "created_by", null: false
    t.string "released_by"
    t.datetime "released_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["stock_reservation_pool_id", "status", "expires_at"], name: "idx_reservations_pool_active"
    t.index ["tenant_id", "created_at", "id"], name: "idx_reservations_tenant_created"
    t.index ["tenant_id", "request_token"], name: "idx_reservations_request_token", unique: true
    t.check_constraint "quantity > 0", name: "stock_reservations_positive_quantity"
    t.check_constraint "status IN ('active', 'released')", name: "stock_reservations_status"
  end

  create_table "swipesimple_day_reviews", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.date "business_date", null: false
    t.integer "reviewed_by_id", null: false
    t.datetime "reviewed_at", null: false
    t.string "reviewed_digest", null: false
    t.string "review_note", limit: 1000
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reviewed_by_id"], name: "index_swipesimple_day_reviews_on_reviewed_by_id"
    t.index ["tenant_id", "business_date"], name: "index_swipesimple_day_reviews_on_tenant_id_and_business_date", unique: true
    t.index ["tenant_id"], name: "index_swipesimple_day_reviews_on_tenant_id"
  end

  create_table "swipesimple_exports", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "merchant_account", null: false
    t.string "kind", null: false
    t.string "currency", null: false
    t.string "source_timezone", null: false
    t.string "fingerprint", null: false
    t.string "sha256", null: false
    t.datetime "exported_at", null: false
    t.text "original_csv", null: false
    t.integer "imported_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["imported_by_id"], name: "index_swipesimple_exports_on_imported_by_id"
    t.index ["tenant_id", "fingerprint"], name: "index_swipesimple_exports_on_tenant_id_and_fingerprint", unique: true
    t.index ["tenant_id", "merchant_account", "kind", "exported_at", "id"], name: "idx_swipesimple_snapshot_scope"
  end

  create_table "swipesimple_item_snapshots", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "merchant_account", null: false
    t.text "records_json", null: false
    t.string "source_filename"
    t.string "sha256", null: false
    t.integer "row_count", null: false
    t.datetime "captured_at", null: false
    t.bigint "imported_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "merchant_account"], name: "idx_swipesimple_items_account", unique: true
  end

  create_table "swipesimple_report_pulls", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "merchant_account", null: false
    t.string "topic", null: false
    t.date "period_from", null: false
    t.date "period_to", null: false
    t.integer "row_count", null: false
    t.string "source_digest", null: false
    t.text "original_csv", null: false
    t.bigint "reconciliation_document_id"
    t.datetime "pulled_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "merchant_account", "topic", "period_from"], name: "idx_swipesimple_report_pulls_scope"
  end

  create_table "swipesimple_report_rows", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "swipesimple_export_id", null: false
    t.string "identity", null: false
    t.text "source_number", null: false
    t.string "transaction_type"
    t.string "status", null: false
    t.string "tender"
    t.integer "amount_cents", null: false
    t.integer "tip_cents"
    t.datetime "occurred_at", null: false
    t.text "reference_number"
    t.date "due_on"
    t.datetime "last_sent_at"
    t.integer "source_row", null: false
    t.index ["swipesimple_export_id", "identity"], name: "idx_swipesimple_export_identity", unique: true
    t.index ["swipesimple_export_id"], name: "index_swipesimple_report_rows_on_swipesimple_export_id"
    t.index ["tenant_id", "identity"], name: "idx_swipesimple_tenant_identity"
  end

  create_table "swipesimple_sales_days", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "merchant_account", null: false
    t.date "business_date", null: false
    t.bigint "subtotal_cents"
    t.bigint "discounts_cents"
    t.bigint "tax_cents"
    t.bigint "tips_cents"
    t.bigint "refunds_cents"
    t.bigint "net_sales_cents"
    t.bigint "net_card_cents"
    t.bigint "net_cash_cents"
    t.string "source_digest", null: false
    t.datetime "pulled_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "merchant_account", "business_date"], name: "idx_swipesimple_sales_days_unique", unique: true
  end

  create_table "swipesimple_tax_days", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.string "merchant_account", null: false
    t.date "business_date", null: false
    t.string "tax_rate_label", null: false
    t.decimal "rate_percent", precision: 7, scale: 4
    t.bigint "pre_tax_cents"
    t.bigint "tax_cents"
    t.bigint "total_cents"
    t.string "source_digest", null: false
    t.datetime "pulled_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "merchant_account", "business_date", "tax_rate_label"], name: "idx_swipesimple_tax_days_unique", unique: true
  end

  create_table "sync_attempts", force: :cascade do |t|
    t.string "tenant_id"
    t.string "source", null: false
    t.string "operation", null: false
    t.string "status", null: false
    t.string "error_category"
    t.string "active_job_id"
    t.datetime "queued_at", null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_sync_attempts_on_active_job_id"
    t.index ["tenant_id", "source", "operation", "queued_at"], name: "idx_sync_attempts_source_history"
  end

  create_table "tasks", force: :cascade do |t|
    t.string "assignee_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.date "due_on"
    t.string "priority", default: "medium"
    t.string "project_id"
    t.string "status", default: "todo", null: false
    t.string "tenant_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "assignee_id"], name: "index_tasks_on_tenant_id_and_assignee_id"
    t.index ["tenant_id", "project_id"], name: "index_tasks_on_tenant_id_and_project_id"
    t.index ["tenant_id", "status"], name: "index_tasks_on_tenant_id_and_status"
  end

  create_table "tenants", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "plan", default: "free"
    t.string "shopify_shop_domain"
    t.string "status", default: "active"
    t.string "subdomain", null: false
    t.datetime "updated_at", null: false
    t.string "referral_domain"
    t.index ["referral_domain"], name: "index_tenants_on_referral_domain"
    t.index ["subdomain"], name: "index_tenants_on_subdomain", unique: true
  end

  create_table "timesheet_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "hours", precision: 6, scale: 2, default: "0.0", null: false
    t.string "tenant_id", null: false
    t.bigint "timesheet_id", null: false
    t.datetime "updated_at", null: false
    t.string "work_type", default: "regular", null: false
    t.date "worked_on", null: false
    t.text "notes"
    t.bigint "clock_shift_id"
    t.index ["tenant_id", "clock_shift_id", "worked_on"], name: "idx_timesheet_shift_day", unique: true
    t.index ["tenant_id", "timesheet_id"], name: "index_timesheet_entries_on_tenant_id_and_timesheet_id"
  end

  create_table "timesheet_events", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.bigint "timesheet_id", null: false
    t.bigint "user_id"
    t.string "action", null: false
    t.text "details"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "timesheet_id"], name: "index_timesheet_events_on_tenant_id_and_timesheet_id"
  end

  create_table "timesheets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.text "notes"
    t.date "period_end", null: false
    t.date "period_start", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by"
    t.string "status", default: "draft", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.datetime "submitted_at"
    t.text "review_note"
    t.boolean "demo", default: false, null: false
    t.integer "assigned_reviewer_id"
    t.integer "sales_cents", default: 0, null: false
    t.integer "card_redemptions", default: 0, null: false
    t.index ["assigned_reviewer_id"], name: "index_timesheets_on_assigned_reviewer_id"
    t.index ["tenant_id", "employee_id", "period_start"], name: "index_timesheets_on_tenant_id_and_employee_id_and_period_start", unique: true
    t.index ["tenant_id", "status"], name: "index_timesheets_on_tenant_id_and_status"
  end

  create_table "user_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "permission", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["tenant_id", "user_id", "permission"], name: "index_user_permissions_on_tenant_id_and_user_id_and_permission", unique: true
    t.index ["tenant_id", "user_id"], name: "index_user_permissions_on_tenant_id_and_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "access_scopes", default: "", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "dashboard_config"
    t.string "email"
    t.datetime "expires_at"
    t.string "name"
    t.string "password_digest"
    t.string "role", default: "employee"
    t.string "shopify_domain"
    t.string "shopify_token"
    t.bigint "shopify_user_id"
    t.string "tenant_id"
    t.datetime "updated_at", null: false
    t.string "referral_domain"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["referral_domain"], name: "index_users_on_referral_domain"
    t.index ["shopify_user_id"], name: "index_users_on_shopify_user_id", unique: true
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  create_table "vendor_payments", force: :cascade do |t|
    t.integer "amount_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.string "method", default: "check"
    t.text "notes"
    t.date "paid_on", null: false
    t.string "reference"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "vendor_id", null: false
    t.index ["discarded_at"], name: "index_vendor_payments_on_discarded_at"
    t.index ["tenant_id", "paid_on"], name: "index_vendor_payments_on_tenant_id_and_paid_on"
    t.index ["tenant_id", "vendor_id"], name: "index_vendor_payments_on_tenant_id_and_vendor_id"
  end

  create_table "vendors", force: :cascade do |t|
    t.text "address"
    t.string "contact_name"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name", null: false
    t.text "notes"
    t.string "payment_terms", default: "net30"
    t.string "phone"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_vendors_on_tenant_id_and_name", unique: true
  end

  create_table "warehouse_cart_items", force: :cascade do |t|
    t.bigint "cart_id", null: false
    t.datetime "created_at", null: false
    t.integer "line_cents", default: 0, null: false
    t.integer "quantity", default: 0, null: false
    t.string "share_id", null: false
    t.string "sku"
    t.string "tenant_id", null: false
    t.string "title"
    t.integer "unit_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "variant_id", null: false
    t.index ["cart_id", "variant_id"], name: "index_warehouse_cart_items_on_cart_id_and_variant_id", unique: true
    t.index ["tenant_id", "share_id"], name: "index_warehouse_cart_items_on_tenant_id_and_share_id"
  end

  create_table "warehouse_carts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "share_id", null: false
    t.string "status", default: "open", null: false
    t.string "tenant_id", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "share_id"], name: "index_warehouse_carts_on_tenant_id_and_share_id"
    t.index ["token"], name: "index_warehouse_carts_on_token", unique: true
  end

  create_table "warehouse_payment_attempts", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "warehouse_cart_id", null: false
    t.string "status", default: "submitting", null: false
    t.string "invoice_number", null: false
    t.string "nonce_digest", null: false
    t.string "gateway_fingerprint", null: false
    t.integer "amount_cents", null: false
    t.text "shipping_json", null: false
    t.string "transaction_id"
    t.datetime "submitted_at", null: false
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_number"], name: "index_warehouse_payment_attempts_on_invoice_number", unique: true
    t.index ["nonce_digest"], name: "index_warehouse_payment_attempts_on_nonce_digest", unique: true
    t.index ["tenant_id", "warehouse_cart_id"], name: "idx_warehouse_attempts_tenant_cart"
    t.index ["warehouse_cart_id"], name: "idx_warehouse_attempts_one_unresolved", unique: true, where: "status IN ('submitting', 'unknown', 'approved')"
    t.index ["warehouse_cart_id"], name: "index_warehouse_payment_attempts_on_warehouse_cart_id"
  end

  create_table "warehouse_stock_holds", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "warehouse_cart_id", null: false
    t.integer "warehouse_payment_attempt_id"
    t.integer "order_id"
    t.string "variant_id", null: false
    t.integer "quantity", null: false
    t.string "status", default: "held", null: false
    t.string "release_reason"
    t.datetime "released_at"
    t.integer "released_by_id"
    t.datetime "fulfillment_confirmed_at"
    t.datetime "source_adjusted_at"
    t.datetime "source_refreshed_at"
    t.text "source_adjustment_reference"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_warehouse_stock_holds_on_order_id"
    t.index ["released_by_id"], name: "index_warehouse_stock_holds_on_released_by_id"
    t.index ["tenant_id", "status", "variant_id"], name: "idx_warehouse_holds_available"
    t.index ["warehouse_cart_id", "variant_id"], name: "idx_warehouse_holds_one_active_line", unique: true, where: "status = 'held'"
    t.index ["warehouse_cart_id"], name: "index_warehouse_stock_holds_on_warehouse_cart_id"
    t.index ["warehouse_payment_attempt_id"], name: "index_warehouse_stock_holds_on_warehouse_payment_attempt_id"
    t.check_constraint "quantity > 0", name: "warehouse_holds_positive_quantity"
    t.check_constraint "status IN ('held', 'released')", name: "warehouse_holds_valid_status"
  end

  create_table "webhook_deliveries", force: :cascade do |t|
    t.string "provider", null: false
    t.string "delivery_id", null: false
    t.string "topic", null: false
    t.string "shop_domain"
    t.string "status", default: "queued", null: false
    t.string "job_id"
    t.datetime "received_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "delivery_id"], name: "index_webhook_deliveries_on_provider_and_delivery_id", unique: true
    t.index ["received_at"], name: "index_webhook_deliveries_on_received_at"
  end

  create_table "workspace_signup_events", force: :cascade do |t|
    t.integer "workspace_signup_id", null: false
    t.integer "actor_id"
    t.string "action", null: false
    t.text "payload_json", null: false
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "index_workspace_signup_events_on_actor_id"
    t.index ["created_at", "id"], name: "index_workspace_signup_events_on_created_at_and_id"
    t.index ["workspace_signup_id"], name: "index_workspace_signup_events_on_workspace_signup_id"
  end

  create_table "workspace_deployments", force: :cascade do |t|
    t.string "tenant_id", null: false
    t.integer "owner_id", null: false
    t.string "instance_id", null: false
    t.string "hostname", null: false
    t.text "instance_secret", null: false
    t.string "status", default: "requested", null: false
    t.string "phase", default: "queued", null: false
    t.integer "attempts", default: 0, null: false
    t.string "lease_digest"
    t.datetime "lease_expires_at"
    t.string "failure_code"
    t.datetime "ready_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hostname"], name: "index_workspace_deployments_on_hostname", unique: true
    t.index ["instance_id"], name: "index_workspace_deployments_on_instance_id", unique: true
    t.index ["owner_id"], name: "index_workspace_deployments_on_owner_id"
    t.index ["status", "id"], name: "index_workspace_deployments_on_status_and_id"
    t.index ["tenant_id"], name: "index_workspace_deployments_on_tenant_id", unique: true
  end

  create_table "workspace_handoffs", force: :cascade do |t|
    t.integer "workspace_deployment_id", null: false
    t.integer "user_id", null: false
    t.integer "support_access_grant_id"
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["support_access_grant_id"], name: "index_workspace_handoffs_on_support_access_grant_id"
    t.index ["token_digest"], name: "index_workspace_handoffs_on_token_digest", unique: true
    t.index ["user_id"], name: "index_workspace_handoffs_on_user_id"
    t.index ["workspace_deployment_id"], name: "index_workspace_handoffs_on_workspace_deployment_id"
  end

  create_table "workspace_signups", force: :cascade do |t|
    t.string "google_subject", null: false
    t.string "applicant_name", null: false
    t.string "email", null: false
    t.string "domain", null: false
    t.string "workspace_name", null: false
    t.string "requested_subdomain", null: false
    t.string "referral_domain", default: "herbalhealershcb.com", null: false
    t.string "status", default: "pending", null: false
    t.integer "reviewer_id"
    t.datetime "reviewed_at"
    t.string "tenant_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "idx_workspace_signups_approved_domain", unique: true, where: "status = 'approved'"
    t.index ["domain"], name: "index_workspace_signups_on_domain"
    t.index ["email"], name: "index_workspace_signups_on_email", unique: true
    t.index ["google_subject"], name: "index_workspace_signups_on_google_subject", unique: true
    t.index ["reviewer_id"], name: "index_workspace_signups_on_reviewer_id"
    t.index ["status", "created_at", "id"], name: "idx_workspace_signups_queue"
  end

  add_foreign_key "feedback_attachments", "agent_feedbacks"
  add_foreign_key "workspace_deployments", "tenants"
  add_foreign_key "workspace_deployments", "users", column: "owner_id"
  add_foreign_key "workspace_handoffs", "support_access_grants"
  add_foreign_key "workspace_handoffs", "users"
  add_foreign_key "workspace_handoffs", "workspace_deployments"
  add_foreign_key "InventoryLevel", "ShopifyVariant", column: "shopifyVariantId", on_delete: :nullify
  add_foreign_key "InventoryLevel", "SquareVariation", column: "squareVariationId", on_delete: :nullify
  add_foreign_key "ReconcileItem", "ReconcileRun", column: "runId", on_delete: :cascade
  add_foreign_key "SkuLink", "ShopifyVariant", column: "shopifyVariantId", on_delete: :nullify
  add_foreign_key "SkuLink", "SquareVariation", column: "squareVariationId", on_delete: :nullify
  add_foreign_key "WarehouseTier", "tenants", column: "tenantId"
  add_foreign_key "api_access_tokens", "tenants", on_delete: :cascade
  add_foreign_key "api_access_tokens", "users", on_delete: :cascade
  add_foreign_key "authorize_net_batches", "tenants"
  add_foreign_key "authorize_net_portal_exports", "tenants"
  add_foreign_key "authorize_net_portal_observations", "authorize_net_portal_exports", on_delete: :cascade
  add_foreign_key "authorize_net_portal_observations", "tenants"
  add_foreign_key "authorize_net_sale_links", "authorize_net_transactions"
  add_foreign_key "authorize_net_sale_links", "orders"
  add_foreign_key "authorize_net_sale_links", "tenants"
  add_foreign_key "authorize_net_sale_links", "users", column: "reviewed_by_id"
  add_foreign_key "authorize_net_sale_links", "users", column: "revoked_by_id"
  add_foreign_key "authorize_net_transactions", "tenants"
  add_foreign_key "bank_statement_accounts", "accounts", column: "ledger_account_id"
  add_foreign_key "bank_statement_accounts", "tenants"
  add_foreign_key "bulk_consumptions", "bulk_lots"
  add_foreign_key "bulk_consumptions", "bulk_movements"
  add_foreign_key "bulk_consumptions", "bulk_recipes"
  add_foreign_key "bulk_lots", "bulk_materials"
  add_foreign_key "bulk_movements", "bulk_lots"
  add_foreign_key "bulk_recipes", "bulk_materials"
  add_foreign_key "clock_corrections", "clock_shifts"
  add_foreign_key "clock_corrections", "tenants"
  add_foreign_key "clock_corrections", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "clock_corrections", "users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "clock_shifts", "employees", on_delete: :nullify
  add_foreign_key "clock_shifts", "tenants"
  add_foreign_key "clock_shifts", "users", on_delete: :nullify
  add_foreign_key "ctrax_days", "Location", column: "location_id", on_delete: :cascade
  add_foreign_key "ctrax_days", "tenants"
  add_foreign_key "ctrax_days", "users", column: "reviewed_by_id"
  add_foreign_key "ctrax_image_links", "Location", column: "location_id", on_delete: :cascade
  add_foreign_key "ctrax_image_links", "ShopifyProduct", column: "shopify_product_id", on_delete: :cascade
  add_foreign_key "ctrax_image_links", "tenants"
  add_foreign_key "ctrax_labor_observations", "ctrax_labor_shifts"
  add_foreign_key "ctrax_labor_observations", "tenants"
  add_foreign_key "ctrax_labor_shifts", "employees"
  add_foreign_key "ctrax_labor_shifts", "tenants"
  add_foreign_key "ctrax_stock_snapshots", "Location", column: "location_id", on_delete: :cascade
  add_foreign_key "ctrax_stock_snapshots", "tenants"
  add_foreign_key "customer_follow_ups", "customers"
  add_foreign_key "customer_follow_ups", "tenants"
  add_foreign_key "customer_interactions", "customers"
  add_foreign_key "customer_interactions", "tenants"
  add_foreign_key "daily_reconciliation_reviews", "tenants"
  add_foreign_key "daily_reconciliation_reviews", "users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "departments", "employees", column: "manager_id"
  add_foreign_key "directory_sync_states", "tenants"
  add_foreign_key "employee_source_identities", "employees"
  add_foreign_key "employee_work_reports", "employees"
  add_foreign_key "employee_work_reports", "tenants"
  add_foreign_key "employee_work_reports", "users", column: "requester_id", on_delete: :nullify
  add_foreign_key "employee_work_reports", "users", column: "reviewer_id", on_delete: :nullify
  add_foreign_key "employees", "employees", column: "merged_into_id"
  add_foreign_key "fulfillments", "orders", on_delete: :cascade
  add_foreign_key "google_login_identities", "users", on_delete: :cascade
  add_foreign_key "inventory_count_scan_receipts", "InventoryCount", column: "count_id", on_delete: :cascade
  add_foreign_key "iris_reports", "tenants"
  add_foreign_key "journal_lines", "accounts", on_delete: :restrict
  add_foreign_key "journal_lines", "journal_entries", on_delete: :restrict
  add_foreign_key "marketing_campaigns", "tenants"
  add_foreign_key "marketing_cms_events", "tenants"
  add_foreign_key "marketing_cms_events", "users", column: "actor_id"
  add_foreign_key "marketing_communities", "marketing_campaigns", column: "campaign_id"
  add_foreign_key "marketing_communities", "tenants"
  add_foreign_key "marketing_document_revisions", "marketing_documents", column: "document_id"
  add_foreign_key "marketing_document_revisions", "tenants"
  add_foreign_key "marketing_document_revisions", "users", column: "actor_id"
  add_foreign_key "marketing_documents", "marketing_engagements", column: "engagement_id"
  add_foreign_key "marketing_documents", "tenants"
  add_foreign_key "marketing_documents", "users", column: "reviewed_by_id"
  add_foreign_key "marketing_engagements", "marketing_campaigns", column: "campaign_id"
  add_foreign_key "marketing_engagements", "marketing_influencers", column: "influencer_id"
  add_foreign_key "marketing_engagements", "tenants"
  add_foreign_key "marketing_influencers", "tenants"
  add_foreign_key "marketing_influencers", "users", column: "owner_id"
  add_foreign_key "marketing_interactions", "marketing_influencers", column: "influencer_id"
  add_foreign_key "marketing_interactions", "tenants"
  add_foreign_key "marketing_interactions", "users", column: "actor_id"
  add_foreign_key "marketing_offers", "marketing_communities", column: "community_id"
  add_foreign_key "marketing_offers", "marketing_engagements", column: "engagement_id"
  add_foreign_key "marketing_offers", "tenants"
  add_foreign_key "marketing_offers", "users", column: "verified_by_id"
  add_foreign_key "marketing_product_gift_items", "marketing_product_gifts", column: "product_gift_id"
  add_foreign_key "marketing_product_gift_items", "tenants"
  add_foreign_key "marketing_product_gifts", "marketing_engagements", column: "engagement_id"
  add_foreign_key "marketing_product_gifts", "tenants"
  add_foreign_key "marketing_replies", "marketing_offers", column: "offer_id"
  add_foreign_key "marketing_replies", "marketing_threads", column: "thread_id"
  add_foreign_key "marketing_replies", "tenants"
  add_foreign_key "marketing_review_events", "marketing_replies", column: "reply_id"
  add_foreign_key "marketing_review_events", "tenants"
  add_foreign_key "marketing_review_events", "users", column: "actor_id"
  add_foreign_key "marketing_shopify_discounts", "marketing_offers", column: "offer_id"
  add_foreign_key "marketing_shopify_discounts", "tenants"
  add_foreign_key "marketing_shopify_discounts", "users", column: "approved_by_id"
  add_foreign_key "marketing_threads", "marketing_communities", column: "community_id"
  add_foreign_key "marketing_threads", "tenants"
  add_foreign_key "order_lines", "orders", on_delete: :cascade
  add_foreign_key "owner_checklist_events", "owner_checklists"
  add_foreign_key "owner_checklist_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "owner_checklists", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "owner_checklists", "users", column: "updated_by_id", on_delete: :nullify
  add_foreign_key "payments", "orders", on_delete: :cascade
  add_foreign_key "pos_checkouts", "Location", column: "location_id"
  add_foreign_key "pos_checkouts", "orders"
  add_foreign_key "pos_checkouts", "pos_display_sessions"
  add_foreign_key "pos_checkouts", "pos_sessions"
  add_foreign_key "pos_checkouts", "tenants"
  add_foreign_key "pos_checkouts", "users"
  add_foreign_key "pos_connections", "tenants"
  add_foreign_key "pos_connections", "users", column: "updated_by_id", on_delete: :nullify
  add_foreign_key "pos_display_sessions", "Location", column: "location_id", on_delete: :cascade
  add_foreign_key "pos_display_sessions", "tenants"
  add_foreign_key "pos_display_sessions", "users"
  add_foreign_key "pos_payment_attempts", "pos_checkouts"
  add_foreign_key "pos_payment_attempts", "tenants"
  add_foreign_key "pos_settings", "Location", column: "location_id"
  add_foreign_key "pos_settings", "tenants"
  add_foreign_key "pos_stock_allocations", "Location", column: "location_id"
  add_foreign_key "pos_stock_allocations", "pos_checkouts"
  add_foreign_key "pos_stock_allocations", "tenants"
  add_foreign_key "purchase_receipt_events", "purchase_receipts"
  add_foreign_key "purchase_receipt_events", "tenants"
  add_foreign_key "purchase_receipt_events", "users", column: "actor_id"
  add_foreign_key "purchase_receipts", "tenants"
  add_foreign_key "purchase_receipts", "users", column: "submitted_by_id"
  add_foreign_key "reconciliation_documents", "reconciliation_documents", column: "supersedes_id"
  add_foreign_key "reconciliation_documents", "tenants"
  add_foreign_key "reconciliation_documents", "users", column: "uploaded_by_id", on_delete: :nullify
  add_foreign_key "reconciliation_follow_up_events", "reconciliation_follow_ups"
  add_foreign_key "reconciliation_follow_up_events", "tenants"
  add_foreign_key "reconciliation_follow_ups", "reconciliation_documents", column: "document_id"
  add_foreign_key "reconciliation_follow_ups", "tenants"
  add_foreign_key "reconciliation_follow_ups", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "reconciliation_follow_ups", "users", column: "owner_id", on_delete: :nullify
  add_foreign_key "refunds", "orders", on_delete: :cascade
  add_foreign_key "retention_drive_connections", "tenants"
  add_foreign_key "retention_drive_items", "tenants"
  add_foreign_key "scheduled_shifts", "employees", on_delete: :cascade
  add_foreign_key "size_changes", "size_families", column: "family_id", on_delete: :cascade
  add_foreign_key "size_family_members", "size_families", column: "family_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "square_timecard_days", "square_timecards"
  add_foreign_key "square_timecard_days", "tenants"
  add_foreign_key "square_timecards", "employees"
  add_foreign_key "square_timecards", "tenants"
  add_foreign_key "stock_reservations", "stock_reservation_pools"
  add_foreign_key "swipesimple_day_reviews", "tenants"
  add_foreign_key "swipesimple_day_reviews", "users", column: "reviewed_by_id"
  add_foreign_key "swipesimple_exports", "users", column: "imported_by_id", on_delete: :nullify
  add_foreign_key "swipesimple_report_rows", "swipesimple_exports"
  add_foreign_key "sync_attempts", "tenants", on_delete: :cascade
  add_foreign_key "warehouse_stock_holds", "orders"
  add_foreign_key "warehouse_stock_holds", "users", column: "released_by_id"
  add_foreign_key "warehouse_stock_holds", "warehouse_carts"
  add_foreign_key "warehouse_stock_holds", "warehouse_payment_attempts"
  add_foreign_key "workspace_signup_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "workspace_signup_events", "workspace_signups"
  add_foreign_key "workspace_signups", "tenants"
  add_foreign_key "workspace_signups", "users", column: "reviewer_id", on_delete: :nullify

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  add_foreign_key "customer_referrals", "tenants"
  add_foreign_key "customer_subscriptions", "tenants"
  add_foreign_key "support_access_events", "support_access_grants"
  add_foreign_key "support_access_events", "tenants"
  add_foreign_key "support_access_events", "users", column: "actor_id"
  add_foreign_key "support_access_grants", "tenants"
  add_foreign_key "support_access_grants", "users", column: "granted_by_id"
  add_foreign_key "support_access_grants", "users", column: "support_user_id"

  create_virtual_table "rupert_customers_fts", "fts5", ["\"email\"", "\"phone\"", "\"first_name\"", "\"last_name\"", "tokenize='trigram'", "content='customers'", "content_rowid='id'"]
  create_virtual_table "rupert_orders_fts", "fts5", ["\"order_number\"", "\"source_order_id\"", "tokenize='trigram'", "content='orders'", "content_rowid='id'"]
  create_virtual_table "rupert_shopifyvariant_fts", "fts5", ["\"sku\"", "\"title\"", "tokenize='trigram'", "content='ShopifyVariant'", "content_rowid='rowid'"]
  add_foreign_key "warehouse_payment_attempts", "warehouse_carts"
  add_foreign_key "purchase_deliveries", "purchase_orders"
  add_foreign_key "stock_request_events", "stock_requests"
  add_foreign_key "stock_requests", "stock_reservation_pools", column: "destination_pool_id"
  add_foreign_key "stock_requests", "stock_reservation_pools", column: "source_pool_id"
  add_foreign_key "stock_requests", "stock_reservations"
end
