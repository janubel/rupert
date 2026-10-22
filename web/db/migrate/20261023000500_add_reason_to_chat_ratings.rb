# frozen_string_literal: true

# An optional "why" on a 👍/👎, so Model scores can show why people liked a model or not.
class AddReasonToChatRatings < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_ratings, :reason, :text
  end
end
