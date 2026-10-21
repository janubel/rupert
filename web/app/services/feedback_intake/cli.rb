# frozen_string_literal: true

class FeedbackIntake
  # Command line behind scripts/feedback_intake.rb, used by the Buzz agent. The
  # message text arrives as one JSON object on standard input so it never passes
  # through a shell command line. Output is plain text safe to paste into a chat
  # reply. Returns the process exit status.
  class Cli
    MAX_INPUT_BYTES = 20_000
    CATEGORIES = %w[question bug request direction].freeze
    HELP = <<~TEXT
      Usage (from web/): bin/rails runner scripts/feedback_intake.rb <command>
        file       one JSON object on stdin: kind (question|bug|request|direction), summary, details, severity,
                   message_id, sender (64-hex pubkey from the event), ready (true only if explicitly asked)
        answered   one JSON object on stdin: category, message_id, sender, note
        status ID  where a report stands
        list [open|ready|all]
      Only senders on the owner's allow-list can mark work ready for development; everyone else's report is for review.
    TEXT

    class Failure < StandardError; end

    def initialize(argv, stdin, out, err)
      @command, *@args = argv
      @stdin = stdin
      @out = out
      @err = err
    end

    def run
      tenant = Tenant.where(status: 'active').first || Tenant.first
      raise Failure, 'no tenant configured' unless tenant

      Current.set(tenant: tenant) { dispatch }
      0
    rescue Failure, FeedbackIntake::Error => e
      @err.puts(e.message)
      1
    end

    private

    def dispatch
      case @command
      when 'file' then file
      when 'answered' then answered
      when 'status' then status
      when 'list' then list
      else @out.puts(HELP)
      end
    end

    def payload
      raw = @stdin.read.to_s
      raise Failure, 'Send one JSON object on standard input (see help).' if raw.strip.empty?
      raise Failure, 'Input is too large.' if raw.bytesize > MAX_INPUT_BYTES

      parsed = JSON.parse(raw)
      raise Failure, 'Input must be a JSON object.' unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise Failure, 'Input is not valid JSON.'
    end

    def file
      data = payload
      kind = data['kind'].to_s
      raise Failure, "kind must be one of #{CATEGORIES.join(', ')}." unless CATEGORIES.include?(kind)

      outcome = FeedbackIntake.file!(source: 'buzz', source_ref: data['message_id'], source_sender: data['sender'], kind: kind, summary: data['summary'],
        details: data['details'], severity: data['severity'], ready: data['ready'], agent_name: 'rupert (Buzz)')
      feedback = outcome.feedback
      url = FeedbackIntake.report_url(feedback)
      if outcome.duplicate
        @out.puts "Already filed as report ##{feedback.id} (#{feedback.kind_label}, #{feedback.status_label}). #{url}"
        return
      end

      @out.puts "Filed report ##{feedback.id} (#{feedback.kind_label}) for review. #{url}"
      @out.puts task_line(outcome.task)
      @out.puts readiness_line(outcome)
    end

    def task_line(task)
      return 'Task: not created.' unless task

      "Task: created in #{FeedbackTask::PROJECT_NAME}, assigned to #{FeedbackTask.owner&.display_name || 'nobody (no active administrator)'}."
    end

    def readiness_line(outcome)
      return 'Marked ready for development (the sender is on the allow-list).' if outcome.ready
      return 'NOT marked ready for development: this sender is not on the allow-list, so it stays for review.' if outcome.ready_denied_reason

      'Not marked ready for development; it stays for review.'
    end

    def answered
      data = payload
      FeedbackIntake.answered!(source: 'buzz', source_ref: data['message_id'], source_sender: data['sender'], kind: data['category'], note: data['note'])
      @out.puts 'Recorded.'
    end

    def status
      id = @args.first.to_s
      raise Failure, 'Usage: status <report-id>' unless id.match?(/\A\d{1,12}\z/)

      feedback = AgentFeedback.find_by(id: id) or raise Failure, "No report ##{id}."
      @out.puts "Report ##{feedback.id} (#{feedback.kind_label}, #{feedback.source}): #{feedback.status_label}#{', ready for development' if feedback.ready_for_development}. " \
                "#{feedback.summary} #{FeedbackIntake.report_url(feedback)}"
    end

    def list
      scope = AgentFeedback.newest_first.limit(15)
      scope = scope.where(status: %w[new triaged planned]) if @args.first == 'open'
      scope = scope.where(ready_for_development: true) if @args.first == 'ready'
      rows = scope.to_a
      @out.puts 'No reports.' if rows.empty?
      rows.each { |row| @out.puts "##{row.id} #{row.status_label} #{row.kind_label}: #{row.summary.first(100)}#{' [ready]' if row.ready_for_development}" }
    end
  end
end
