# frozen_string_literal: true

module Uploads
  # Aggregates about how the inbox is working, to guide what to build next: which
  # files wait and why, which importers are doing their job, how long a file takes
  # to reach an import. Counts, times and codes only; never file contents, cell
  # values, parameters or file names. Everything is scoped to the current workspace.
  class Insights
    RANGES = [30, 90, 365].freeze
    SERIES = %w[imported needs_review recognized rejected duplicate].freeze
    MAX_ROWS = 100_000
    REASONS = {
      'unrecognized' => ['Not recognized', 'Rupert could not tell what the file is. Candidates for a new importer or a better sniffer.'],
      'no_importer' => ['Recognized, no importer', 'Named but nothing reads it yet. The clearest list of importers to build.'],
      'not_installed' => ['Importer not installed', 'Matched an importer that is not on this server yet.'],
      'low_confidence' => ['Not sure enough', 'Matched below 75%. Tighten that importer’s signature.'],
      'ambiguous' => ['Two close matches', 'Two importers scored within 15 points. Their signatures overlap.'],
      'dry_run_failed' => ['Dry run failed', 'The importer could not read the file. Better messages, or a wider parser.'],
      'import_failed' => ['Import failed', 'Approved after a dry run, then failed.'],
      'not_text' => ['Not readable as text', 'Binary data or an unreadable encoding behind a text extension.'],
      'bad_json' => ['Invalid JSON', nil], 'bad_pdf' => ['Not a PDF', nil], 'bad_xlsx' => ['Unreadable workbook', 'Includes encrypted, oversized and zip-bomb workbooks.'],
      'unsupported_type' => ['Unsupported file type', 'People send types the inbox does not take.'],
      'too_large' => ['Too large', 'Over the 10 MiB cap.'], 'empty' => ['Empty file', nil],
      'discarded' => ['Discarded by a person', nil], 'duplicate' => ['Sent again unchanged', nil],
      'recognition_failed' => ['Recognition error', 'A sniffer raised an error. Check the error tracker.'],
      'unknown' => ['Before reasons were recorded', nil]
    }.freeze

    attr_reader :days, :since

    def initialize(days: 30)
      @days = RANGES.include?(days.to_i) ? days.to_i : 30
      @since = (Time.zone.today - (@days - 1)).beginning_of_day
    end

    def uploads
      @uploads ||= Upload.where('created_at >= ?', since)
    end

    def total = rows.size

    # Per day, in the app's time zone, counts by status (the five statuses plus a total).
    def daily
      @daily ||= begin
        counts = Hash.new { |hash, day| hash[day] = Hash.new(0) }
        rows.each { |created_at, status, *| counts[created_at.in_time_zone.to_date][status] += 1 }
        (since.to_date..Time.zone.today).map do |day|
          by = counts[day]
          { date: day, counts: SERIES.to_h { |status| [status, by[status]] }, total: by.values.sum }
        end
      end
    end

    def status_totals
      @status_totals ||= SERIES.to_h { |status| [status, rows.count { |row| row[1] == status }] }
    end

    # Files kept (not refused, not duplicates), then how far they got.
    def funnel
      @funnel ||= begin
        kept = rows.select { |row| row[7] }
        matched = kept.count { |row| row[3].present? && !row[4] }
        imported = kept.count { |row| row[1] == 'imported' }
        dry_ok = event_uploads('upload_dry_run').size
        [
          { key: 'kept', label: 'Kept', count: kept.size, note: 'Sent, readable and not already here.' },
          { key: 'matched', label: 'Matched an importer without help', count: matched, note: 'Recognized by Rupert; nobody had to choose the type.' },
          { key: 'dry_run', label: 'Passed a dry run', count: dry_ok, note: 'A person ran a dry run that read the file cleanly.' },
          { key: 'imported', label: 'Imported', count: imported, note: 'Approved and imported.' }
        ]
      end
    end

    def reasons
      @reasons ||= begin
        held = rows.select { |row| %w[needs_review rejected duplicate].include?(row[1]) }
        held.group_by { |row| row[2].presence || 'unknown' }.map do |code, list|
          label, hint = REASONS.fetch(code) { [code.humanize, nil] }
          { code: code, label: label, hint: hint, count: list.size }
        end.sort_by { |entry| [-entry[:count], entry[:label]] }
      end
    end

    # What Rupert thought the file was, and how it fared.
    def types
      @types ||= begin
        kept = rows.select { |row| row[7] }
        kept.group_by { |row| row[5].presence || 'Not recognized' }.map do |label, list|
          confidences = list.filter_map { |row| row[6] }
          { label: label, count: list.size, average_confidence: confidences.empty? ? nil : (confidences.sum.to_f / confidences.size).round,
            held: list.count { |row| row[1] == 'needs_review' }, helped: list.count { |row| row[4] }, imported: list.count { |row| row[1] == 'imported' } }
        end.sort_by { |entry| [-entry[:count], entry[:label]] }.first(15)
      end
    end

    def origins
      @origins ||= rows.group_by { |row| row[8] }.transform_values(&:size)
    end

    # Dry runs by importer, from the audit trail (events recorded with the importer key).
    def importers
      @importers ||= begin
        table = Hash.new { |hash, key| hash[key] = { passed: 0, failed: 0, imported: 0, import_failed: 0 } }
        events.each do |action, details|
          key = details.to_s[/importer=(\w+)/, 1] or next
          case action
          when 'upload_dry_run' then table[key][:passed] += 1
          when 'upload_dry_run_failed' then table[key][:failed] += 1
          when 'upload_imported' then table[key][:imported] += 1
          when 'upload_import_failed' then table[key][:import_failed] += 1
          end
        end
        table.map { |key, counts| { key: key, label: Registry.find(key)&.label || key.humanize }.merge(counts) }.sort_by { |entry| [-(entry[:passed] + entry[:failed]), entry[:label]] }
      end
    end

    # Hours from receipt to import, for files imported in the range.
    def time_to_import_hours
      @time_to_import_hours ||= begin
        hours = Upload.where(status: 'imported').where('imported_at >= ?', since).pluck(:created_at, :imported_at).map { |a, b| (b - a) / 3600.0 }.sort
        hours.empty? ? nil : hours[hours.size / 2].round(1)
      end
    end

    def waiting_count = Upload.where(status: %w[received recognized needs_review], retained: true).count

    def oldest_waiting_days
      oldest = Upload.where(status: %w[received recognized needs_review], retained: true).minimum(:created_at)
      oldest && ((Time.current - oldest) / 1.day).floor
    end

    private

    # [created_at, status, reason_code, importer_key, operator_chosen, detected_label, confidence, retained, origin]
    def rows
      @rows ||= uploads.order(:created_at).limit(MAX_ROWS).pluck(:created_at, :status, :reason_code, :importer_key, :operator_chosen, :detected_label, :confidence, :retained, :origin)
    end

    def events
      @events ||= ActivityLog.where('action LIKE ?', 'upload_%').where('created_at >= ?', since).limit(MAX_ROWS).pluck(:action, :details)
    end

    def event_uploads(action)
      ActivityLog.where(action: action).where('created_at >= ?', since).distinct.pluck(:subject_id)
    end
  end
end
