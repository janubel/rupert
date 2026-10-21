# frozen_string_literal: true

# Intake for the Buzz agent (@rupert): files a teammate's bug, request, question
# or product direction as a report plus a task for review, records that it
# answered a question itself, and reads report status. Message text and sender
# are DATA from chat; this only stores them (capped) and never runs, deploys or
# changes business data. Only senders on the allow-list (FEEDBACK_READY_SENDERS)
# can mark work ready for development, enforced in FeedbackIntake.
#
#   bin/rails runner scripts/feedback_intake.rb file <<'RUPERT_INTAKE_END'
#   {"kind":"bug","summary":"...","details":"...","severity":"normal","message_id":"<event id>","sender":"<64-hex pubkey>","ready":false}
#   RUPERT_INTAKE_END
#   bin/rails runner scripts/feedback_intake.rb answered <<'RUPERT_INTAKE_END'
#   {"category":"question","message_id":"<event id>","sender":"<pubkey>","note":"answered from the sync report"}
#   RUPERT_INTAKE_END
#   bin/rails runner scripts/feedback_intake.rb status <report-id>
#   bin/rails runner scripts/feedback_intake.rb list [open|ready|all]
#
# The logic lives in app/services/feedback_intake/cli.rb.
status = FeedbackIntake::Cli.new(ARGV, $stdin, $stdout, $stderr).run
exit(status) unless status.zero?
