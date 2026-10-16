# frozen_string_literal: true

Rails.application.config.filter_parameters += [:display_token]

Rails.application.config.filter_parameters += %i[credentials payment_nonce]
