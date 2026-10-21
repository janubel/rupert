# frozen_string_literal: true

module UploadsHelper
  STATUS_PILLS = { 'received' => 'pill-taupe', 'recognized' => 'pill-olive', 'needs_review' => 'pill-clay', 'imported' => 'pill-fern',
                   'rejected' => 'pill-rose', 'duplicate' => 'pill-taupe' }.freeze
  STATUS_HELP = {
    'received' => 'Kept, not yet looked at.',
    'recognized' => 'Kept and matched to an importer. Nothing has changed in your records.',
    'needs_review' => 'Kept. Rupert is not sure what it is, or cannot read it yet. A person decides.',
    'imported' => 'Approved by a person and imported.',
    'rejected' => 'Refused or discarded. See the reason.',
    'duplicate' => 'Identical to a file already kept, so it was not stored again.'
  }.freeze

  def upload_status_pill(upload)
    tag.span(upload.status_label, class: STATUS_PILLS.fetch(upload.status, 'pill-taupe'), title: STATUS_HELP[upload.status])
  end

  def upload_origin_label(upload)
    case upload.origin
    when 'api' then upload.via_token_label.present? ? "API (#{upload.via_token_label})" : 'API'
    when 'drop' then 'Drop folder'
    when 'drive' then 'Google Drive'
    else 'Browser'
    end
  end

  def upload_who(upload)
    upload.uploaded_by_name.presence || (upload.origin == 'drop' ? 'Drop folder' : 'Unknown')
  end

  def upload_size(upload) = number_to_human_size(upload.byte_size)

  def upload_confidence(upload)
    upload.confidence ? "#{upload.confidence}%" : nil
  end

  def upload_format_label(upload)
    Uploads::Limits::FORMAT_LABELS[upload.file_format] || upload.file_format.to_s.upcase
  end

  # A cell as the page shows it: escaped by ERB, with spreadsheet-formula starts marked.
  def upload_cell(value)
    text = Uploads::Cell.display(value)
    return text unless Uploads::Cell.formula_like?(value)

    safe_join([tag.span('text', class: 'upload-formula-mark', title: 'Starts with a character a spreadsheet would treat as a formula. Rupert shows it as plain text and never evaluates it.'), ' ', text])
  end
end
