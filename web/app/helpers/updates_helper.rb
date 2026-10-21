# frozen_string_literal: true

# Plain-language labels for what the host deployer reported (see AutoUpdate).
module UpdatesHelper
  UPDATE_STATES = {
    'up_to_date' => ['Up to date', 'pill-fern', 'This server runs the newest code on GitHub main.'],
    'ready' => ['Ready to install', 'pill-olive', 'An update passed CI and is waiting for you to install it.'],
    'waiting_ci' => ['Waiting for CI', 'pill-taupe', 'An update is waiting for its checks to pass on GitHub.'],
    'ci_failed' => ['CI failed', 'pill-rose', "The newest code failed its checks, so it won't be installed. A fix on main is picked up automatically."],
    'deploying' => ['Installing', 'pill-olive', 'Installing now. Rupert restarts when it finishes.'],
    'deployed' => ['Installed', 'pill-fern', 'The update installed and Rupert came back healthy.'],
    'failed' => ['Update failed', 'pill-rose', 'The last update failed and the code was rolled back. Retry it, or wait for a newer commit.'],
    'blocked' => ['Blocked', 'pill-rose', "The updater can't install updates until this is fixed on the server."]
  }.freeze

  def update_state_pill(report)
    label, pill, = UPDATE_STATES.fetch(report.state, [report.state.humanize, 'pill-taupe'])
    tag.span(label, class: pill, data: { update_state: report.state })
  end

  def update_state_summary(report) = UPDATE_STATES.dig(report.state, 2) || report.message

  def short_sha(sha) = sha.to_s.first(8).presence || 'unknown'

  def commit_link(sha)
    return tag.code('unknown') unless sha.to_s.match?(BuildInfo::REVISION)

    link_to(tag.code(short_sha(sha)), "https://github.com/#{UpdateChecker::REPO}/commit/#{sha}", target: '_blank', rel: 'noopener', class: 'underline')
  end
end
