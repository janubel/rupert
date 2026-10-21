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

  CHART_LABELS = { 'imported' => 'Imported', 'recognized' => 'Recognized', 'needs_review' => 'Needs review', 'rejected' => 'Rejected', 'duplicate' => 'Duplicate' }.freeze
  # Bottom to top. Imported sits on the baseline so the good outcome is easiest to compare.
  CHART_STACK = %w[imported recognized needs_review rejected duplicate].freeze
  CHART = { width: 720, height: 240, left: 36, right: 8, top: 8, bottom: 28 }.freeze

  # Days for up to 90 days; weeks beyond that, so a bar never gets thinner than a few pixels.
  def upload_chart_buckets(daily, days)
    return daily.map { |day| { label: day[:date].strftime('%b %-d'), counts: day[:counts], total: day[:total] } } if days <= 90

    daily.each_slice(7).map do |week|
      counts = Uploads::Insights::SERIES.to_h { |status| [status, week.sum { |day| day[:counts][status] }] }
      { label: "Week of #{week.first[:date].strftime('%b %-d')}", counts: counts, total: counts.values.sum }
    end
  end

  def upload_chart_ceiling(max)
    return 4 if max <= 4

    magnitude = 10**Math.log10(max).floor
    [1, 2, 2.5, 5, 10].map { |step| (step * magnitude).ceil }.find { |value| value >= max }
  end

  # Stacked columns of uploads by outcome. Inline SVG: no script, colour from
  # tokens, 2px surface gaps between segments, a focusable column with a text
  # alternative per bar (the table beside it carries every number).
  def upload_volume_chart(buckets)
    plot = { w: CHART[:width] - CHART[:left] - CHART[:right], h: CHART[:height] - CHART[:top] - CHART[:bottom] }
    ceiling = upload_chart_ceiling(buckets.map { |bucket| bucket[:total] }.max.to_i)
    step = plot[:w].to_f / buckets.size
    width = [[step * 0.72, 22].min, 2].max
    scale = plot[:h].to_f / ceiling
    base = CHART[:top] + plot[:h]
    grid = [0, ceiling / 2.0, ceiling].uniq.map do |value|
      y = (base - (value * scale)).round(1)
      safe_join([tag.line(x1: CHART[:left], x2: CHART[:width] - CHART[:right], y1: y, y2: y, class: 'upload-grid'),
                 tag.text(value.to_i.to_s, x: CHART[:left] - 6, y: y + 3.5, 'text-anchor': 'end', class: 'upload-axis')])
    end
    every = [(buckets.size / 6.0).ceil, 1].max
    columns = buckets.each_with_index.map do |bucket, index|
      x = (CHART[:left] + (index * step) + ((step - width) / 2)).round(1)
      y = base
      segments = CHART_STACK.filter_map do |status|
        count = bucket[:counts][status].to_i
        next if count.zero?

        height = [count * scale, 2].max
        y -= height
        tag.rect(x: x, y: y.round(1), width: width.round(1), height: height.round(1), rx: 2, class: "upload-seg upload-seg-#{status}")
      end
      parts = CHART_STACK.filter_map { |status| "#{bucket[:counts][status]} #{CHART_LABELS[status].downcase}" if bucket[:counts][status].to_i.positive? }
      text = "#{bucket[:label]}: #{pluralize(bucket[:total], 'upload')}#{": #{parts.to_sentence}" if parts.any?}"
      label = (index % every).zero? ? tag.text(bucket[:label].delete_prefix('Week of '), x: (x + (width / 2)).round(1), y: CHART[:height] - 8, 'text-anchor': 'middle', class: 'upload-axis') : ''.html_safe
      tag.g(safe_join([tag.title(text), tag.rect(x: (x - 2).round(1), y: CHART[:top], width: (width + 4).round(1), height: plot[:h], class: 'upload-hit'), *segments, label]),
        class: 'upload-col', tabindex: 0, role: 'img', 'aria-label': text)
    end
    tag.svg(safe_join([*grid, *columns]), viewBox: "0 0 #{CHART[:width]} #{CHART[:height]}", class: 'upload-chart', role: 'group',
      'aria-label': 'Uploads per period, stacked by outcome. Each column has its own description; the table below lists every number.')
  end

  def upload_percent(part, whole)
    whole.to_i.zero? ? '–' : "#{(part * 100.0 / whole).round}%"
  end
end
