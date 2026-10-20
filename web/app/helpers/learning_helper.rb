# frozen_string_literal: true

module LearningHelper
  def learning_journey
    @learning_journey ||= LearningJourney.new(Current.user)
  end
end
