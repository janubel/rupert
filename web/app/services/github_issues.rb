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

    def token
      EnvStore.platform_fetch('GITHUB_ISSUES_TOKEN', '').to_s.strip
    end

    def request(method, path, payload = nil)
      raise NotConfiguredError, 'GitHub issues are not set up: add GITHUB_ISSUES_TOKEN.' unless configured?

      http = Net::HTTP.new('api.github.com', 443)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(path)
      req['Authorization'] = "Bearer #{token}"
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
