# frozen_string_literal: true

Rails.application.routes.draw do
  root to: 'home#index'
  post '/source_syncs/:source', to: 'source_syncs#create', as: :source_sync
  resources :authorize_net_portal_exports, only: %i[index create] do
    get :document, on: :member
  end

  get '/login', to: 'sessions#new', as: :login
  post '/login', to: 'sessions#create'
  delete '/logout', to: 'sessions#destroy', as: :logout

  get '/auth/google', to: 'oauth#authorize', as: :google_auth
  get '/auth/google/callback', to: 'oauth#callback', as: :google_callback

  get '/signup', to: 'signups#new', as: :signup
  post '/signup', to: 'signups#create'
  get '/platform', to: 'platform#index', as: :platform
  post '/platform/signups/:id/approve', to: 'platform#approve', as: :approve_platform_signup
  post '/platform/signups/:id/reject', to: 'platform#reject', as: :reject_platform_signup

  get '/setup', to: 'setup#new', as: :setup
  post '/setup', to: 'setup#create'

  get '/onboarding', to: 'onboarding#index', as: :onboarding
  post '/onboarding/connect', to: 'onboarding#connect', as: :onboarding_connect

  resources :tenants, only: %i[index new create]

  resources :users, only: %i[index new create edit update destroy] do
    member do
      post :deactivate
      post :activate
      post :update_permissions
    end
  end
  resource :permissions, only: :show do
    post :save
    post :reset
  end

  scope path: :api, format: :json do
    namespace :webhooks do
      post '/app_uninstalled', to: 'app_uninstalled#receive'
      post '/app_scopes_update', to: 'app_scopes_update#receive'
      post '/customers_data_request', to: 'customers_data_request#receive'
      post '/customers_redact', to: 'customers_redact#receive'
      post '/shop_redact', to: 'shop_redact#receive'
    end
  end

  namespace :api do
    namespace :v1 do
      get :catalog, to: 'catalog#index'
      get :inventory, to: 'inventory#index'
      get :roadmap, to: 'roadmap#index'
    end
  end
  resources :api_access_tokens, only: %i[index create] do
    member { post :revoke }
  end

  mount ShopifyApp::Engine, at: '/api'

  get '/search', to: 'search#index', as: :search
  get '/dashboard', to: 'home#index'
  get '/roadmap', to: 'roadmap#index', as: :roadmap
  post '/dashboard/customize', to: 'home#customize', as: :customize_dashboard

  # ERP modules (registered in ModuleRegistry)
  get '/sales', to: 'sales#index', as: :sales
  get '/sales/print', to: 'sales#print', as: :sales_print
  resources :orders, only: [:show] do
    member do
      post :add_tracking
      post :update_fulfillment_status
      post :refund
    end
  end
  resources :customers, only: %i[index show new create edit update]
  namespace :projects do
    resources :projects, only: %i[index show new create edit update destroy] do
      member { post :transition }
    end
    resources :tasks, only: %i[index create update destroy] do
      member { post :transition }
    end
  end
  namespace :goals do
    resources :goals, only: %i[index show new create edit update destroy] do
      member { post :transition }
    end
    resources :kpis, only: %i[index show new create edit update destroy] do
      member { post :reading }
    end
  end
  namespace :sales do
    resources :pos_sessions, only: %i[index show new create] do
      member do
        post :refresh
        post :close
        post :reopen
      end
    end
  end

  resources :inventory, only: :index do
    collection do
      get :pdf
      get :movements
      get :recommended_skus
    end
  end
  resources :locations
  namespace :finance do
    get '/accounts', to: 'accounts#show', as: :accounts
    resources :chart_of_accounts, only: %i[index new create edit update] do
      member do
        post :archive
        post :restore
      end
    end
    resources :expenses, only: %i[index new create edit update destroy] do
      member { post :restore }
    end
    resources :vendor_payments, only: %i[index new create destroy] do
      member { post :restore }
    end
  end
  namespace :purchasing do
    resources :vendors
    resources :purchase_orders, only: %i[index show new create edit update destroy] do
      member do
        post :place_order
        post :receive
        post :cancel
        post :add_line
        post :remove_line
      end
    end
  end
  namespace :people do
    resources :employees, only: %i[index show new create edit update destroy] do
      member { post :transition }
    end
    resources :departments, only: %i[index new create edit update]
    resources :positions, only: %i[index new create edit update]
    resources :timesheets, only: %i[index show new create edit update destroy] do
      member do
        post :submit
        post :approve
        post :reject
        post :reopen
        post :add_entry
        post :remove_entry
      end
    end
    resources :leave_requests, only: %i[index show new create destroy] do
      member do
        post :approve
        post :deny
        post :cancel
      end
    end
    resources :pay_runs, only: %i[index show new create] do
      member do
        post :finalize
        post :pay
        post :generate_payslips
        post :add_payslip
        post :remove_payslip
      end
    end
  end
  resources :shopify_variants, only: [:show] do
    member do
      post :link
      post :unlink
    end
  end
  resources :inventory_counts do
    member do
      get :scan, to: 'inventory_count_scans#show'
      get :lookup, to: 'inventory_count_scans#lookup'
      post :record_scan, to: 'inventory_count_scans#create'
      post :submit
      post :approve
      post :reject
      post :reopen
    end
  end
  resources :stock_reservations, only: %i[index new create] do
    member { post :release }
  end
  resources :bulk_materials, only: %i[index new create show] do
    get :export, on: :collection
    resources :bulk_lots, only: %i[new create show] do
      resources :bulk_movements, only: :create
    end
  end
  get '/point_of_sale', to: 'point_of_sale#index', as: :point_of_sale
  post '/point_of_sale/quote', to: 'point_of_sale#quote', as: :quote_point_of_sale
  get '/time_clock', to: 'time_clock#index', as: :time_clock
  post '/time_clock/clock_in', to: 'time_clock#clock_in', as: :clock_in_time_clock
  post '/time_clock/clock_out', to: 'time_clock#clock_out', as: :clock_out_time_clock
  post '/time_clock/shifts/:id/correction', to: 'time_clock#request_correction', as: :request_correction_time_clock
  post '/time_clock/corrections/:id/approve', to: 'time_clock#approve_correction', as: :approve_correction_time_clock
  post '/time_clock/corrections/:id/reject', to: 'time_clock#reject_correction', as: :reject_correction_time_clock
  get '/time_clock/commissions', to: 'time_clock#commissions', as: :commission_preview_time_clock
  resources :reconcile, only: :index
  resources :money_reconciliations, only: %i[index create]
  resources :reports, only: [:index] do
    collection do
      get :register_summary
      get :sales
      get :financial
      get :inventory
      get :operations
      get :reconciliation
    end
  end
  resources :ledger, only: :index
  resources :alerts, only: :index do
    collection do
      post :update_status
      post :bulk_update
    end
  end
  resources :syncs, only: %i[index create] do
    collection do
      post :source
      post :preview_swipesimple
      post :import_swipesimple
      post :push_guard_approve
      post :push_guard_freeze
      post :push_guard_unfreeze
    end
  end
  resources :swipesimple_reports, only: %i[index create] do
    collection { post :preview }
    member { get :document }
  end
  get '/system', to: 'system#index', as: :system
  get '/connections', to: 'connections#index', as: :connections
  resources :owner_checklists, only: %i[index new create show edit update] do
    member do
      get :print
      get :service
      patch :save_service
      get :feature
      patch :review_feature
    end
  end
  resources :pos_connections, only: %i[index show update], param: :provider do
    member do
      post :check_access
      post :import_reporting
      post :import_iris_csv
      post :disconnect
      post :sync_stock
    end
  end
  resources :ctrax_stock, only: :index
  resources :inventory_exceptions, only: :index
  resources :bulk_recipes, only: %i[index new create]
  resources :bulk_consumptions, only: %i[index new create] do
    collection do
      post :preview
      get :export
    end
  end
  get '/activity', to: 'activity#index', as: :activity
  resources :access_logs, only: :index
  get '/live/sync_status', to: 'live#sync_status'

  resource :settings, only: :show do
    post :tenant
    post :fulfillment_workflow
    post :oauth_credentials
    post :oauth_domains
    delete :oauth_domains, to: 'settings#oauth_remove_domain'
    get :env, defaults: { format: :json }
    post :env_preview, defaults: { format: :json }
    post :env_import, defaults: { format: :json }
    get :env_export, to: 'settings#new_env_export', as: :env_export_confirm
    post :env_export, as: :env_export
    get :backup
    post :restore, defaults: { format: :json }
    get :drive_status, defaults: { format: :json }
    get :drive_logs, defaults: { format: :json }
    get :drive_auth
    get :drive_oauth_callback
    post :drive_backup, defaults: { format: :json }
    post :drive_disconnect
    post :buzz_generate
    post :buzz_register
    post :buzz_test
  end

  resources :size_families, only: %i[index new create edit update destroy] do
    collection do
      post :derive_all
      post :approve_all
    end
    member do
      post :derive
      post :set_root
      post :approve_all
      post :add_member
      post :remove_member
      post :approve
    end
  end

  get '/warehouse', to: 'warehouse#index', as: :warehouse
  post '/warehouse/tiers', to: 'warehouse#update_tiers', as: :update_warehouse_tiers
  resources :warehouse_shares, only: %i[create show update destroy] do
    member do
      post :update_tiers
    end
  end

  get '/w/:token', to: 'warehouse_sales#show', as: :warehouse_sale

  get '/w/:token/cart', to: 'warehouse_carts#show', as: :warehouse_cart
  post '/w/:token/cart/items', to: 'warehouse_carts#add_item', as: :warehouse_cart_add_item
  patch '/w/:token/cart/items/:item_id', to: 'warehouse_carts#update_item', as: :warehouse_cart_item
  delete '/w/:token/cart/items/:item_id', to: 'warehouse_carts#remove_item', as: :warehouse_cart_remove_item

  get '/w/:token/checkout', to: 'warehouse_checkouts#show', as: :warehouse_checkout
  post '/w/:token/checkout', to: 'warehouse_checkouts#create', as: :warehouse_checkout_submit

  get '/w/:token/orders/:order_number', to: 'warehouse_orders#show', as: :warehouse_order

  get '/up', to: proc { [200, { 'content-type' => 'text/plain' }, ['OK']] }

  # Unknown paths get a real 404 (rendering the dashboard for any URL made
  # broken links invisible). The dashboard stays reachable at / and /dashboard.
  get '*path', to: ->(_env) { [404, { 'Content-Type' => 'text/html' }, [<<~HTML]] }
    <!doctype html><html><head><meta charset="utf-8"><title>Page not found — Rupert</title></head>
    <body style="font-family: system-ui; padding: 3rem;">
      <h1>Page not found</h1>
      <p>The page you were looking for doesn't exist. <a href="/">Back to the dashboard</a>.</p>
    </body></html>
  HTML
end
