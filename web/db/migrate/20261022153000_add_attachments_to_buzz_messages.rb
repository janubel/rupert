# frozen_string_literal: true

# Media references (NIP-92 `imeta` tags) from a Buzz message, kept beside the
# text so the mirror can show an image or file link without re-reading the relay.
class AddAttachmentsToBuzzMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :buzz_messages, :attachments, :text
  end
end
