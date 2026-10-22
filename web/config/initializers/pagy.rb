# frozen_string_literal: true

# Pagy config — lightweight pagination for index pages.
require 'pagy'

Pagy::OPTIONS[:limit] = 25
Pagy::OPTIONS[:raise_range_error] = true
Pagy::OPTIONS.freeze
