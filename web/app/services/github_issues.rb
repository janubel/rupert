# frozen_string_literal: true

require 'net/http'

# Every in-app report (bug button, Ask Rupert, Team chat, MCP assistants) is
# posted as a GitHub issue on the release milestone, where the team triages it,
# and a closed issue closes the report. The repository may be public, so the
# issue carries only the report's own words, scrubbed of emails, phones, card
# numbers and secrets — never the reporter's name, attachments, context JSON or
# query strings. The token lives in the platform settings (or the host ENV).
class GithubIssues
  class Error < StandardError; end
  class NotConfiguredError < Error; end

  DEFAULT_REPO = 'techmore/rupert'
  LABEL = 'from-rupert'
  KIND_LABELS = { 'bug' => 'bug', 'request' => 'enhancement', 'suggestion' => 'enhancement', 'question' => 'question' }.freeze
  TITLE_MAX = 120
  BODY_MAX = 6000

  Tracker = Struct.new(:title, :url, :open_count, :closed_count, :issues, :fetched_at, keyword_init: true) do
    def total = open_count + closed_count
    def percent_done = total.positive? ? (closed_count * 100 / total) : 0

    # Open issues by their area:* label ("Payroll", "Setup"…), largest group first; no area label is "Other".
    def by_area
      issues.group_by { |issue| issue[:area] || 'Other' }.sort_by { |area, rows| [area == 'Other' ? 1 : 0, -rows.size, area] }
    end
  end
  TRACKER_KEY = 'github_issues:release_tracker'

  class << self
    def repo
      value = EnvStore.platform_fetch('GITHUB_ISSUES_REPO', DEFAULT_REPO).to_s.strip
      value.match?(%r{\A[\w.-]+/[\w.-]+\z}) ? value : DEFAULT_REPO
    end

    def configured?
      token.present?
    end

    # Milestone title new reports join (e.g. "v0.2.1"); blank means none.
    def milestone_title
      EnvStore.platform_fetch('GITHUB_ISSUES_MILESTONE', '').to_s.strip
    end

    def milestone_number
      title = milestone_title
      milestones.find { |name, _number| name == title }&.last if title.present?
    end

    # Posts a new report with its scrubbed draft. Safe to call twice.
    def post_report!(feedback)
      feedback.with_lock do
        next feedback if feedback.github_issue_number

        draft = draft_for(feedback)
        post!(feedback, title: draft[:title], body: draft[:body], milestone: milestone_number, actor: nil)
      end
    end

    # Open milestones as [title, number], newest first; cached briefly.
    def milestones
      return [] unless configured?

      Rails.cache.fetch("github_issues:milestones:#{repo}", expires_in: 10.minutes) do
        Array(request(:get, "/repos/#{repo}/milestones?state=open&sort=due_on&direction=desc&per_page=30"))
          .map { |milestone| [milestone['title'].to_s, milestone['number'].to_i] }
      end
    rescue Error
      []
    end

    # What is left before the release: the open issues on the release milestone (GITHUB_ISSUES_MILESTONE, or the
    # newest open "v…" milestone). Reads work without a token when the repository is public. Cached 10 minutes;
    # nil when GitHub cannot be read.
    def release_tracker(refresh: false)
      Rails.cache.delete("#{TRACKER_KEY}:#{repo}") if refresh
      tracker_from(Rails.cache.fetch("#{TRACKER_KEY}:#{repo}", expires_in: 10.minutes, skip_nil: true) { read_tracker&.to_h })
    end

    # For the header: never calls GitHub while a page renders.
    def cached_release_tracker
      tracker_from(Rails.cache.read("#{TRACKER_KEY}:#{repo}"))
    end

    # The cache holds a plain hash, so a deploy that changes Tracker never meets an old object.
    def tracker_from(hash)
      Tracker.new(**hash.slice(*Tracker.members)) if hash.is_a?(Hash)
    end

    # The text an operator starts from: the report's own words, scrubbed.
    def draft_for(feedback)
      page = feedback.related_reference.to_s.split('?').first.to_s.sub(%r{\Ahttps?://[^/]+}, '')
      lines = [
        "**#{feedback.kind_label}** · severity #{feedback.severity} · filed in Rupert (report ##{feedback.id})",
        '',
        AskRupert::Redactor.personal(feedback.details.presence || feedback.summary).first(BODY_MAX - 400)
      ]
      lines += ['', "Page: `#{page}`"] if page.present?
      lines += ["Build: `#{BuildInfo.current.short_revision}`"]
      { title: AskRupert::Redactor.personal(feedback.summary).first(TITLE_MAX), body: lines.join("\n") }
    end

    def post!(feedback, title:, body:, milestone: nil, actor: Current.user)
      raise NotConfiguredError, 'GitHub issues are not set up: add GITHUB_ISSUES_TOKEN.' unless configured?
      raise Error, "Report ##{feedback.id} is already GitHub issue ##{feedback.github_issue_number}." if feedback.github_issue_number

      title = AskRupert::Redactor.clean(title).squish.first(TITLE_MAX)
      body = AskRupert::Redactor.clean(body).first(BODY_MAX)
      raise Error, 'Add a title.' if title.blank?

      payload = { title: title, body: "#{body}\n\n---\nFiled from Rupert by an administrator.",
                  labels: [LABEL, KIND_LABELS[feedback.kind]].compact }
      payload[:milestone] = milestone.to_i if milestone.present? && milestone.to_i.positive?
      issue = request(:post, "/repos/#{repo}/issues", payload)
      feedback.update!(github_issue_number: issue['number'], github_issue_url: issue['html_url'],
        github_state: issue['state'], github_synced_at: Time.current)
      ActivityLogger.log('feedback_posted_to_github', subject: feedback, actor: actor, details: "#{repo}##{issue['number']}")
      feedback
    end

    # Reads back open issues; a closed issue closes the report.
    def sync!(scope = AgentFeedback.where.not(github_issue_number: nil).where(github_state: [nil, 'open']))
      return 0 unless configured?

      scope.find_each.count do |feedback|
        issue = request(:get, "/repos/#{repo}/issues/#{feedback.github_issue_number}")
        attributes = { github_state: issue['state'], github_synced_at: Time.current }
        if issue['state'] == 'closed' && %w[new triaged planned].include?(feedback.status)
          attributes[:status] = issue['state_reason'] == 'not_planned' ? 'wont_fix' : 'done'
        end
        feedback.update!(attributes)
        attributes.key?(:status)
      rescue Error => e
        Rails.logger.warn("GithubIssues.sync! report #{feedback.id}: #{e.message}")
        false
      end
    end

    private

    def read_tracker
      list = Array(request(:get, "/repos/#{repo}/milestones?state=open&sort=due_on&direction=desc&per_page=30", anonymous: true))
      wanted = milestone_title
      milestone = wanted.present? ? list.find { |row| row['title'] == wanted } : list.find { |row| row['title'].to_s.match?(/\Av\d/) }
      return unless milestone

      issues = []
      (1..5).each do |page|
        batch = Array(request(:get, "/repos/#{repo}/issues?milestone=#{milestone['number'].to_i}&state=open&per_page=100&page=#{page}", anonymous: true))
        issues += batch.reject { |issue| issue.key?('pull_request') }
        break if batch.size < 100
      end
      Tracker.new(title: milestone['title'].to_s, url: milestone['html_url'].to_s, open_count: milestone['open_issues'].to_i,
        closed_count: milestone['closed_issues'].to_i, fetched_at: Time.current,
        issues: issues.sort_by { |issue| issue['number'].to_i }.map { |issue| tracker_issue(issue) })
    rescue Error => e
      Rails.logger.warn("GithubIssues.release_tracker: #{e.message}")
      nil
    end

    def tracker_issue(issue)
      labels = Array(issue['labels']).map { |label| label['name'].to_s }
      area = labels.find { |name| name.start_with?('area:') }&.delete_prefix('area:')
      { number: issue['number'].to_i, title: issue['title'].to_s, url: issue['html_url'].to_s,
        area: area&.split('-')&.map { |word| %w[ui lms crm api].include?(word) ? word.upcase : word.capitalize }&.join(' / '),
        labels: labels.grep_v(/\Aarea:|\Av\d|\Arelease\z/) }
    end

    def token
      EnvStore.platform_fetch('GITHUB_ISSUES_TOKEN', '').to_s.strip
    end

    # anonymous: a read that also works without a token, for a public repository.
    def request(method, path, payload = nil, anonymous: false)
      raise NotConfiguredError, 'GitHub issues are not set up: add GITHUB_ISSUES_TOKEN.' unless configured? || (anonymous && method == :get)

      http = Net::HTTP.new('api.github.com', 443)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(path)
      req['Authorization'] = "Bearer #{token}" if configured?
      req['Accept'] = 'application/vnd.github+json'
      req['X-GitHub-Api-Version'] = '2022-11-28'
      req['User-Agent'] = 'Rupert'
      if payload
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(payload)
      end
      response = http.request(req)
      raise Error, "GitHub answered #{response.code}." unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, JSON::ParserError => e
      raise Error, "GitHub could not be reached (#{e.class.name.demodulize})."
    end
  end
end
