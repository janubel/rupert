# frozen_string_literal: true

# The living catalogue of Rupert's UI (docs/ui-standards.md): every page template and
# component rendered from the real stylesheet and helpers, with sample data only.
class StyleGuideController < AuthenticatedController
  before_action { head(:forbidden) unless Current.user&.can?('settings.read') }

  def show; end
end
