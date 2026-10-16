# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += %i[
  passw secret token nonce _key crypt salt certificate otp ssn credential authorization client_id login_id
]

# Settings import/preview accepts whole .env payloads under a generic text key.
# OAuth authorization codes also need filtering before request instrumentation.
Rails.application.config.filter_parameters += [/\Atext\z/i, /\Acode\z/i]

# Owner records contain private contacts, renewal details and test evidence.
# Filter each complete form container before request instrumentation.
Rails.application.config.filter_parameters += [/\Aowner_checklist\z/i, /\Aowner_service\z/i, /\Aowner_feature\z/i]

# Workspace applications contain private organization and applicant references.
Rails.application.config.filter_parameters += [/\Aworkspace_signup\z/i]

# Native source documents and their full context must never reach request logs.
Rails.application.config.filter_parameters += [/\Aswipesimple_export\z/i, /\Afile\z/i, :original_csv, :reference_number, :source_number]
# Uploaded financial reports and merchant references stay out of request logs.
Rails.application.config.filter_parameters += %i[report_file merchant_number account_reference]

Rails.application.config.filter_parameters += %i[gateway_id exported_at records_json payload invoice_number order_reference evidence_note]

# Unexpected card fields are never accepted by hosted checkout and must not log.
Rails.application.config.filter_parameters += %i[ccnumber ccexp cvv card_number card_exp card_cvv card_code merchant_company gateway_fingerprint]

Rails.application.config.filter_parameters += %i[timesheet timesheet_entry clock_correction]
# Influencer contacts, recipient addresses and campaign documents remain private.
Rails.application.config.filter_parameters += [/\Acms_record\z/i, /\Ainteraction\z/i, :contact_email, :shipping_details, :private_notes, :tracking_number, :tracking_url]
